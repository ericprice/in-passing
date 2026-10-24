import CoreGraphics
import AppKit
import ApplicationServices
import InPassingCore
import SwiftUI

private func windowEvent(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    // AX observers are registered on the main run loop and owned for the app lifetime.
    MainActor.assumeIsolated {
        Unmanaged<WindowObserver>.fromOpaque(context).takeUnretainedValue().receive(element, notification: notification as String)
    }
}

@MainActor final class WindowObserver: ObservableObject {
    @Published private(set) var trusted = false
    @Published private(set) var paused = false
    @Published private(set) var windowCount = 0
    private struct WatchedWindow { let id: UUID; let element: AXUIElement; var minimized: Bool }
    private struct WatchedApp { let element: AXUIElement; let observer: AXObserver?; var windows: [WatchedWindow]; var hidden: Bool }
    private var apps: [pid_t: WatchedApp] = [:]
    private var ledger = WindowLedger()
    private var timer: Timer?
    private var tokens: [NSObjectProtocol] = []
    private var sleeping = false
    private let drawing: DrawingStore

    init(drawing: DrawingStore) {
        self.drawing = drawing
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.removeApp(app.processIdentifier, markClosures: true) }
        })
        for (notification, hidden) in [(NSWorkspace.didHideApplicationNotification, true), (NSWorkspace.didUnhideApplicationNotification, false)] {
            tokens.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.setAppHidden(app.processIdentifier, hidden: hidden) }
            })
        }
        tokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = true; self?.reset() }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = false; self?.refresh() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        refresh()
    }
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        refresh()
    }
    func togglePause() { paused.toggle(); reset(); if !paused { refresh() } }
    private var enabled: Bool { trusted && !paused && !sleeping }
    private func desktopBounds() -> CGRect {
        NSScreen.screens.reduce(CGRect.null) { result, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return result }
            return result.union(CGDisplayBounds(number.uint32Value))
        }
    }
    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions), dimensions.width >= 40, dimensions.height >= 40 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    private func register(_ element: AXUIElement, pid: pid_t) {
        guard var app = apps[pid], !app.windows.contains(where: { CFEqual($0.element, element) }),
              attribute(element, kAXRoleAttribute) as? String == kAXWindowRole,
              let bounds = frame(element) else { return }
        let subrole = attribute(element, kAXSubroleAttribute) as? String
        guard subrole == nil || subrole == kAXStandardWindowSubrole else { return }
        let minimized = attribute(element, kAXMinimizedAttribute) as? Bool ?? false
        let window = WatchedWindow(id: UUID(), element: element, minimized: minimized)
        app.windows.append(window); apps[pid] = app
        ledger.update(window.id, frame: bounds, visible: !app.hidden && !minimized)
        if let observer = app.observer {
            for notification in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                                 kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                AXObserverAddNotification(observer, element, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
        }
    }
    private func closeWindow(_ window: WatchedWindow) {
        if let bounds = ledger.close(window.id), enabled { drawing.record(bounds, desktop: desktopBounds()) }
    }
    private func updateVisibility(_ window: WatchedWindow, hidden: Bool) {
        if let bounds = frame(window.element) { ledger.update(window.id, frame: bounds) }
        if let bounds = ledger.setVisible(window.id, !hidden && !window.minimized), enabled {
            drawing.record(bounds, desktop: desktopBounds())
        }
    }
    private func setAppHidden(_ pid: pid_t, hidden: Bool) {
        guard enabled, var app = apps[pid], app.hidden != hidden else { return }
        app.hidden = hidden; apps[pid] = app
        for window in app.windows { updateVisibility(window, hidden: hidden) }
    }
    private func setWindowMinimized(_ window: WatchedWindow, pid: pid_t, minimized: Bool) {
        guard var app = apps[pid], let index = app.windows.firstIndex(where: { $0.id == window.id }),
              app.windows[index].minimized != minimized else { return }
        app.windows[index].minimized = minimized; apps[pid] = app
        updateVisibility(app.windows[index], hidden: app.hidden)
    }
    fileprivate func receive(_ element: AXUIElement, notification: String) {
        guard enabled else { return }
        var pid: pid_t = 0; AXUIElementGetPid(element, &pid)
        if notification == kAXWindowCreatedNotification { register(element, pid: pid) }
        else if let matched = apps.first(where: { $0.value.windows.contains(where: { CFEqual($0.element, element) }) }),
                let window = matched.value.windows.first(where: { CFEqual($0.element, element) }) {
            if notification == kAXUIElementDestroyedNotification {
                closeWindow(window)
                apps[matched.key]?.windows.removeAll(where: { $0.id == window.id })
            } else if notification == kAXWindowMiniaturizedNotification || notification == kAXWindowDeminiaturizedNotification {
                setWindowMinimized(window, pid: matched.key, minimized: notification == kAXWindowMiniaturizedNotification)
            } else if let bounds = frame(element) { ledger.update(window.id, frame: bounds) }
        }
        windowCount = ledger.count
    }
    private func refresh() {
        let allowed = AXIsProcessTrusted()
        if trusted != allowed { trusted = allowed; reset() }
        guard enabled else { return }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
        let pids = Set(running.map(\.processIdentifier))
        for pid in Array(apps.keys) where !pids.contains(pid) { removeApp(pid, markClosures: true) }
        for process in running {
            let pid = process.processIdentifier
            if apps[pid] == nil {
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.15)
                var observer: AXObserver?
                AXObserverCreate(pid, windowEvent, &observer)
                apps[pid] = WatchedApp(element: element, observer: observer, windows: [], hidden: process.isHidden)
                if let observer {
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                    AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
                }
            }
            setAppHidden(pid, hidden: process.isHidden)
            guard let app = apps[pid] else { continue }
            if let windows = attribute(app.element, kAXWindowsAttribute) as? [AXUIElement] {
                for element in windows { register(element, pid: pid) }
            }
            // List disappearance alone may be a Space change. Only explicit app hiding,
            // minimization, destruction, or termination makes a mark.
            for window in apps[pid]?.windows ?? [] {
                var unused: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(window.element, kAXRoleAttribute as CFString, &unused)
                if result == .invalidUIElement {
                    closeWindow(window); apps[pid]?.windows.removeAll(where: { $0.id == window.id })
                } else if result == .success {
                    if let bounds = frame(window.element) { ledger.update(window.id, frame: bounds) }
                    if let minimized = attribute(window.element, kAXMinimizedAttribute) as? Bool {
                        setWindowMinimized(window, pid: pid, minimized: minimized)
                    }
                }
            }
        }
        windowCount = ledger.count
    }
    private func removeApp(_ pid: pid_t, markClosures: Bool) {
        guard let app = apps.removeValue(forKey: pid) else { return }
        if let observer = app.observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        for window in app.windows { if markClosures { closeWindow(window) } else { _ = ledger.close(window.id) } }
        windowCount = ledger.count
    }
    private func reset() {
        for pid in Array(apps.keys) { removeApp(pid, markClosures: false) }
        ledger.reset(); windowCount = 0
    }
}
