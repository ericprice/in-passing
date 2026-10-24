import AppKit
import ServiceManagement
import Sparkle
import OSLog
import Combine

@main enum InPassingApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    let drawing: DrawingStore
    let preferences = DrawingPreferences()
    let observer: WindowObserver
    let desktop: DesktopController
    private var menus: MenuController?
    private var subscriptions: Set<AnyCancellable> = []
    private let analytics = AppAnalytics()
    private var updateCycleActive = false
    private var updateFound = false
    private var updateDownloadCancelled = false
    private lazy var updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private lazy var dailyReporter = AppRunningDailyReporter(enabled: { PostHogConfiguration.isEnabled }, record: { [weak self] trigger in
        guard let self else { return }
        analytics.record(.runningDaily, parameters: analyticsState.properties.merging(["reason": trigger.rawValue]) { _, new in new })
    })

    override init() {
        let store = DrawingStore()
        drawing = store
        observer = WindowObserver(drawing: store)
        desktop = DesktopController(drawing: store, preferences: preferences)
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
        if duplicates.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        PostHogConfiguration.setup()
        registerAtLogin()
        desktop.start()
        let controller = MenuController(state: { [unowned self] in
            MenuController.State(trusted: observer.trusted, paused: observer.paused, maximum: preferences.maximumShapes,
                                 customColor: preferences.colorMode == .custom, openAtLogin: SMAppService.mainApp.status == .enabled,
                                 canCheckForUpdates: updater.updater.canCheckForUpdates, wallpaperFallback: desktop.wallpaperFallback, notice: drawing.notice)
        }, perform: { [unowned self] action in perform(action) })
        menus = controller; controller.install()
        updater.startUpdater()
        startAnalytics()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        analytics.observe(analyticsState)
        dailyReporter.stop()
        PostHogConfiguration.flushForTermination()
    }

    private var analyticsState: AppAnalytics.State {
        let login: String
        switch SMAppService.mainApp.status {
        case .enabled: login = "enabled"
        case .notRegistered: login = "disabled"
        case .requiresApproval: login = "requiresApproval"
        case .notFound: login = "notFound"
        @unknown default: login = "unknown"
        }
        let color = preferences.customColor.usingColorSpace(.sRGB) ?? .white
        return .init(maximum: preferences.maximumShapes, colorMode: preferences.colorMode.rawValue,
                     customColor: [color.redComponent, color.greenComponent, color.blueComponent],
                     accessibility: observer.trusted, paused: observer.paused, loginStatus: login,
                     automaticUpdateChecks: updater.updater.automaticallyChecksForUpdates,
                     automaticUpdates: updater.updater.automaticallyDownloadsUpdates)
    }
    private func startAnalytics() {
        analytics.launch(analyticsState)
        dailyReporter.start()
        preferences.objectWillChange.merge(with: observer.objectWillChange)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in guard let self else { return }; analytics.observe(analyticsState) }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }; analytics.observe(analyticsState, includeColor: false)
            }.store(in: &subscriptions)
        drawing.$notice.removeDuplicates().filter { !$0.isEmpty }.sink { [weak self] _ in
            self?.analytics.record(.storageFailed, parameters: ["category": "local_storage"])
        }.store(in: &subscriptions)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in self?.dailyReporter.suspend() }.store(in: &subscriptions)
        workspace.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            guard let self else { return }; dailyReporter.resume(); analytics.record(.woke, parameters: analyticsState.properties)
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .NSSystemClockDidChange).sink { [weak self] _ in self?.dailyReporter.clockChanged() }.store(in: &subscriptions)
    }

    private func perform(_ action: MenuController.Action) {
        switch action {
        case .about: showAbout()
        case .updates: analytics.record(.updates); updater.checkForUpdates(nil)
        case .openAtLogin: toggleOpenAtLogin()
        case .accessibility: analytics.record(.accessibilityRequested); observer.requestAccess()
        case .pauseResume: observer.togglePause()
        case .automaticColor: desktop.useAutomaticColor()
        case .customColor: desktop.chooseCustomColor()
        case .maximum(let count): preferences.maximumShapes = count
        case .customMaximum: preferences.chooseMaximum()
        case .clear: clearDesktop()
        case .quit: NSApp.terminate(nil)
        case .storageError:
            let alert = NSAlert(); alert.messageText = "Drawing Could Not Be Saved"; alert.informativeText = drawing.notice
            NSApp.activate(ignoringOtherApps: true); alert.runModal()
        }
        analytics.observe(analyticsState)
    }
    private func registerAtLogin() {
        let defaults = UserDefaults.standard
        // Apply the default once, preserving later changes in the menu or System Settings.
        guard !defaults.bool(forKey: "loginRegistrationAttempted") else { return }
        do {
            let service = SMAppService.mainApp
            if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            defaults.set(true, forKey: "loginRegistrationAttempted")
        } catch {
            analytics.recordLoginFailure(error, operation: .automaticRegistration)
            Logger(subsystem: "com.ericprice.InPassing", category: "Login").error("Login registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        let operation: AppAnalytics.LoginOperation = service.status == .enabled ? .disable : .enable
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems(); return
            default: try service.register()
            }
            UserDefaults.standard.set(true, forKey: "loginRegistrationAttempted")
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            analytics.recordLoginFailure(error, operation: operation)
            let alert = NSAlert(); alert.messageText = "Could Not Change Open at Login"; alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true); alert.runModal()
        }
    }
    private func showAbout() {
        analytics.record(.about)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let credits = NSAttributedString(string: "inpassing.ericprice.info", attributes: [
            .link: URL(string: "https://inpassing.ericprice.info")!, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .paragraphStyle: paragraph
        ])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "In Passing",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: "", .credits: credits
        ])
    }
    private func clearDesktop() {
        let alert = NSAlert()
        alert.messageText = "Clear the Desktop?"
        alert.informativeText = "This removes all currently visible window remnants."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Clear")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            let hadShapes = !drawing.traces.isEmpty
            drawing.clear()
            if hadShapes { analytics.record(.clear) }
        }
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        updateCycleActive = true; updateFound = false; updateDownloadCancelled = false
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { updateFound = true }
    func userDidCancelDownload(_ updater: SPUUpdater) { updateDownloadCancelled = true }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard updateCycleActive else { return }
        updateCycleActive = false
        analytics.recordUpdateCheckCompleted(source: updateCheck, outcome: AppAnalytics.updateOutcome(error: error, foundUpdate: updateFound, cancelled: updateDownloadCancelled))
        if let error { analytics.recordUpdateFailure(error, check: updateCheck) }
    }
}
