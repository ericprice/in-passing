import AppKit
import Combine
import InPassingCore

private final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class DesktopController: NSObject, ObservableObject {
    @Published private(set) var wallpaperFallback = false
    private let drawing: DrawingStore
    private let preferences: DrawingPreferences
    private var windows: [DesktopWindow] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Timer?
    private var automaticColors: [CGDirectDisplayID: NSColor] = [:]

    init(drawing: DrawingStore, preferences: DrawingPreferences) {
        self.drawing = drawing; self.preferences = preferences
        super.init()
    }
    func start() {
        drawing.objectWillChange.merge(with: preferences.objectWillChange)
            .receive(on: RunLoop.main).sink { [weak self] in self?.refreshArtwork() }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(refreshWallpapers), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(rebuild), name: NSWorkspace.didWakeNotification, object: nil)
        // Public wallpaper APIs have no change notification; refresh a tiny sample periodically.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWallpapers() }
        }
        rebuild()
    }
    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    private var desktopBounds: CGRect {
        NSScreen.screens.reduce(CGRect.null) { $0.union(CGDisplayBounds(displayID($1))) }
    }
    @objc private func rebuild() {
        for window in windows { window.orderOut(nil); window.close() }
        windows = NSScreen.screens.map { screen in
            let window = DesktopWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.title = "In Passing desktop"
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.ignoresMouseEvents = true; window.isMovable = false
            window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
            window.setAccessibilityElement(false)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            window.contentView = DesktopDrawingView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            return window
        }
        refreshWallpapers()
    }
    @objc private func refreshWallpapers() {
        var fallback = false
        for screen in NSScreen.screens {
            let result = WallpaperContrast.outline(for: screen)
            automaticColors[displayID(screen)] = result.color
            fallback = fallback || !result.sampled
        }
        if wallpaperFallback != fallback { wallpaperFallback = fallback }
        refreshArtwork()
    }
    private func stroke(for screen: NSScreen) -> NSColor {
        preferences.colorMode == .custom ? preferences.customColor : automaticColors[displayID(screen)] ?? .white
    }
    private func refreshArtwork() {
        let desktop = desktopBounds
        guard desktop.hasArea else { return }
        let traces = activeTraces(drawing.traces, maximum: preferences.maximumShapes)
        for (window, screen) in zip(windows, NSScreen.screens) {
            guard let view = window.contentView as? DesktopDrawingView else { continue }
            view.traces = traces
            view.desktop = desktop; view.display = CGDisplayBounds(displayID(screen))
            view.stroke = stroke(for: screen)
            view.needsDisplay = true
        }
    }
    func chooseCustomColor() {
        preferences.colorMode = .custom
        let panel = NSColorPanel.shared
        panel.title = "Color"; panel.showsAlpha = false; panel.isContinuous = true
        panel.color = preferences.customColor
        panel.setTarget(self); panel.setAction(#selector(customColorChanged(_:)))
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
    }
    @objc private func customColorChanged(_ sender: NSColorPanel) {
        guard preferences.colorMode == .custom, let color = sender.color.usingColorSpace(.sRGB) else { return }
        preferences.customColor = color.withAlphaComponent(1)
    }
    func useAutomaticColor() {
        preferences.colorMode = .automatic
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
        refreshWallpapers()
    }
}

private final class DesktopDrawingView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    var traces: [WindowTrace] = []
    var desktop = CGRect.zero
    var display = CGRect.zero
    var stroke = NSColor.white

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        context.saveGState()
        context.translateBy(x: -display.minX, y: -display.minY)
        context.setStrokeColor(stroke.cgColor)
        // Clip a double-width centered stroke to retain exactly one outline width inside the window.
        context.setLineWidth(outlineWidth(screenWidth: bounds.width) * 2)
        for trace in traces {
            let frame = trace.frame(in: desktop)
            context.saveGState()
            context.clip(to: frame)
            context.stroke(frame)
            context.restoreGState()
        }
        context.restoreGState()
    }
}
