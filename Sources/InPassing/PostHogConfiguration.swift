import Foundation
import OSLog
import PostHog

/// Also blocks queued uploads: SDK optOut() stops capture, but not queue timers.
final class PostHogConsentURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var consentDefaults: UserDefaults = .standard

    static func use(_ defaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        consentDefaults = defaults
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return consentDefaults.object(forKey: "shareUsageStatistics") != nil
            && !consentDefaults.bool(forKey: "shareUsageStatistics")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
    override func stopLoading() {}
}

@MainActor
enum PostHogConfiguration {
    private static let logger = Logger(subsystem: "com.ericprice.InPassing", category: "analytics")
    private static var isConfigured = false
    private static var isStarting = false
    private static var preferenceObserver: NSObjectProtocol?
    private static var sessionConfiguration = URLSessionConfiguration.ephemeral
    private static var captureQueue = DispatchQueue(label: "com.ericprice.InPassing.analytics", qos: .utility)
    static var isEnabled: Bool { usageStatisticsEnabled(in: .standard) }

    /// Isolated checks can inject transport and a serial work queue to exercise this
    /// exact startup/consent/drain path. Retain them through deferred opt-in setup.
    static func setup(sessionConfiguration: URLSessionConfiguration? = nil, workQueue: DispatchQueue? = nil) {
        if let sessionConfiguration, !isConfigured, !isStarting {
            self.sessionConfiguration = sessionConfiguration.copy() as! URLSessionConfiguration
        }
        if let workQueue, !isConfigured, !isStarting { captureQueue = workQueue }
        if preferenceObserver == nil {
            preferenceObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { synchronizeUsageStatisticsPreference() }
            }
        }
        // Even setup requests remote configuration, so defer it entirely while opted out.
        guard isEnabled else {
            if isConfigured { synchronizeSDKConsent() }
            return
        }
        guard !isConfigured, !isStarting else { return }
        let bundled = Bundle.main.url(forResource: "PostHogConfiguration", withExtension: "plist")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: String] } ?? [:]
        let environment = ProcessInfo.processInfo.environment
        guard let projectToken = environment["POSTHOG_PROJECT_TOKEN"] ?? bundled["POSTHOG_PROJECT_TOKEN"],
              projectToken.hasPrefix("phc_"), projectToken.count > 4,
              let host = environment["POSTHOG_HOST"] ?? bundled["POSTHOG_HOST"],
              let url = URL(string: host), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            logger.error("PostHog configuration is missing or invalid; analytics disabled")
            return
        }
        // SDK persistence can synchronously notify UserDefaults observers during setup.
        isStarting = true
        defer { isStarting = false }
        PostHogSDK.shared.setup(makeConfig(projectToken: projectToken, host: host,
                                          sessionConfiguration: self.sessionConfiguration))
        isConfigured = true
        // The app preference owns consent, including after a previous SDK opt-out.
        synchronizeSDKConsent()
        logger.info("PostHog initialized from app configuration")
    }

    // SDK hooks execute on the capture caller's thread, including our utility queue.
    // Build them outside MainActor so nested filtering closures inherit no executor.
    nonisolated static func makeConfig(
        projectToken: String, host: String, defaults: UserDefaults = .standard,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) -> PostHogConfig {
        let config = PostHogConfig(projectToken: projectToken, host: host)
        config.optOut = !usageStatisticsEnabled(in: defaults)
        config.personProfiles = .never
        config.setDefaultPersonProperties = false
        config.disableGeoIp = true
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.capturePushNotificationSubscriptions = false
        config.capturePushNotificationOpened = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        // Native exceptions can include text, error descriptions, and local paths.
        // Categorized operational failures still pass through the typed event boundary.
        config.errorTrackingConfig.autoCapture = false
        config.errorTrackingConfig.exceptionSteps.enabled = false
        config.maxQueueSize = 100
        // This mostly idle utility does not need minute-by-minute uploads. The SDK
        // also uses this interval for its empty replay queue, reducing all idle ticks.
        config.flushIntervalSeconds = 300
        let session = sessionConfiguration.copy() as! URLSessionConfiguration
        session.httpShouldSetCookies = false
        session.httpCookieStorage = nil
        session.urlCredentialStorage = nil
        session.urlCache = nil
        PostHogConsentURLProtocol.use(defaults)
        session.protocolClasses = [PostHogConsentURLProtocol.self] + (session.protocolClasses ?? [])
        config.urlSessionConfiguration = session
        config.setBeforeSend { event in
            guard usageStatisticsEnabled(in: defaults), eventNames.contains(event.event) else { return nil }
            event.properties = event.properties.filter { eventProperties.contains($0.key) }
            for (key, value) in AnalyticsContext.current.properties { event.properties[key] = value }
            event.properties["$process_person_profile"] = false
            event.properties["$geoip_disable"] = true
            return event
        }
        // This app exports typed product events only; raw logs are never uploaded.
        config.logs.setBeforeSend { _ in nil }
        return config
    }

    static func capture(_ event: String, properties: [String: String]) {
        synchronizeUsageStatisticsPreference()
        guard isEnabled, isConfigured else { return }
        captureQueue.async {
            guard usageStatisticsEnabled(in: .standard) else { return }
            PostHogSDK.shared.capture(event, properties: properties)
        }
    }

    static func flush() {
        synchronizeUsageStatisticsPreference()
        guard isEnabled, isConfigured else { return }
        captureQueue.async {
            guard usageStatisticsEnabled(in: .standard) else { return }
            PostHogSDK.shared.flush()
        }
    }

    /// Wait only for queued capture writes, never for network delivery. The SDK's
    /// durable queue retains undelivered events for the next launch.
    @discardableResult
    static func flushForTermination(timeout: TimeInterval = 1) -> Bool {
        synchronizeUsageStatisticsPreference()
        guard isConfigured else { return true }
        let drained = DispatchSemaphore(value: 0)
        captureQueue.async {
            if usageStatisticsEnabled(in: .standard) { PostHogSDK.shared.flush() }
            drained.signal()
        }
        return drained.wait(timeout: .now() + max(0, timeout)) == .success
    }

    static func synchronizeUsageStatisticsPreference() {
        // The app delegate owns initialization; isolated checks can use their own SDK.
        guard preferenceObserver != nil, !isStarting else { return }
        if !isEnabled {
            if isConfigured { synchronizeSDKConsent() }
        } else if !isConfigured {
            setup()
        } else {
            synchronizeSDKConsent()
        }
    }

    private static func synchronizeSDKConsent() {
        captureQueue.async {
            if usageStatisticsEnabled(in: .standard) {
                PostHogSDK.shared.optIn()
            } else {
                PostHogSDK.shared.optOut()
            }
        }
    }

    nonisolated private static func usageStatisticsEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "shareUsageStatistics") == nil || defaults.bool(forKey: "shareUsageStatistics")
    }
    nonisolated private static let eventNames: Set<String> = [
        "app_launched", "app_running_daily", "app_woke", "about_opened", "updates_checked",
        "observation_toggled", "maximum_shapes_changed", "color_changed", "drawing_cleared",
        "accessibility_requested", "accessibility_changed", "preferences_changed",
        "open_at_login_failed", "update_check_completed", "update_check_failed", "drawing_storage_failed"
    ]
    nonisolated private static let eventProperties: Set<String> = [
        "maximumShapes", "colorMode", "accessibilityEnabled", "paused", "openAtLoginStatus",
        "automaticUpdateChecks", "automaticUpdates", "previousValue", "value", "previousMode", "mode",
        "reason", "source", "category", "operation", "changedPreference", "outcome",
        "analytics_environment", "is_internal", "app_version", "app_build", "analytics_schema_version",
        "$lib", "$lib_version", "$app_name", "$app_version", "$app_build", "$app_namespace",
        "$os_name", "$os_version", "$device_type", "$device_manufacturer", "$device_model",
        "$process_person_profile", "$geoip_disable", "$is_identified"
    ]
}
