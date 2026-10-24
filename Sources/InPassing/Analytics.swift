import AppKit
import ServiceManagement
import Sparkle

/// This boundary accepts app settings and bounded outcomes, never observed window data.
@MainActor final class AppAnalytics {
    enum Event: String {
        case launched = "app_launched", runningDaily = "app_running_daily", woke = "app_woke"
        case about = "about_opened", updates = "updates_checked", pause = "observation_toggled"
        case maximum = "maximum_shapes_changed", color = "color_changed", clear = "drawing_cleared"
        case accessibilityRequested = "accessibility_requested", accessibility = "accessibility_changed"
        case preferences = "preferences_changed", loginFailed = "open_at_login_failed"
        case updateCompleted = "update_check_completed", updateFailed = "update_check_failed"
        case storageFailed = "drawing_storage_failed"
    }
    enum LoginOperation: String { case automaticRegistration, enable, disable }
    enum UpdateOutcome: String {
        case upToDate = "up_to_date", updateAvailable = "update_available"
        case cancelled, failed, unknown
    }
    struct State: Equatable {
        var maximum = 5
        var colorMode = "automatic"
        // Used only for local change detection; never included in event properties.
        var customColor: [Double] = []
        var accessibility = false
        var paused = false
        var loginStatus = "disabled"
        var automaticUpdateChecks = false
        var automaticUpdates = false
        var properties: [String: String] {
            ["maximumShapes": String(maximum), "colorMode": colorMode,
             "accessibilityEnabled": String(accessibility), "paused": String(paused),
             "openAtLoginStatus": loginStatus, "automaticUpdateChecks": String(automaticUpdateChecks),
             "automaticUpdates": String(automaticUpdates)]
        }
    }
    private let defaults: UserDefaults
    private let capture: @MainActor (String, [String: String]) -> Void
    private var previous: State?
    init(defaults: UserDefaults = .standard,
         capture: @escaping @MainActor (String, [String: String]) -> Void = { PostHogConfiguration.capture($0, properties: $1) }) {
        self.defaults = defaults; self.capture = capture
    }
    var isEnabled: Bool {
        defaults.object(forKey: "shareUsageStatistics") == nil || defaults.bool(forKey: "shareUsageStatistics")
    }
    func launch(_ state: State) { previous = state; record(.launched, parameters: state.properties) }
    func observe(_ observed: State, includeColor: Bool = true) {
        var state = observed
        // Defaults can change continuously while dragging the native color picker.
        // Its debounced publisher owns color changes; other preference observations do not consume them.
        if !includeColor, let previous { state.customColor = previous.customColor }
        defer { previous = state }
        guard let old = previous else { return }
        if old.maximum != state.maximum {
            record(.maximum, parameters: ["previousValue": String(old.maximum), "value": String(state.maximum),
                                          "source": [5, 10, 15, 20].contains(state.maximum) ? "preset" : "custom"])
        }
        if old.colorMode != state.colorMode || (state.colorMode == "custom" && old.customColor != state.customColor) {
            record(.color, parameters: ["previousMode": old.colorMode, "mode": state.colorMode])
        }
        if old.accessibility != state.accessibility { record(.accessibility, parameters: ["value": String(state.accessibility)]) }
        if old.paused != state.paused { record(.pause, parameters: ["paused": String(state.paused)]) }
        for key in ["openAtLoginStatus", "automaticUpdateChecks", "automaticUpdates"] where old.properties[key] != state.properties[key] {
            record(.preferences, parameters: ["changedPreference": key, "previousValue": old.properties[key]!, "value": state.properties[key]!])
        }
    }
    func record(_ event: Event, parameters: [String: String] = [:]) {
        guard isEnabled else { return }
        capture(event.rawValue, parameters)
    }
    func recordUpdateCheckCompleted(source: SPUUpdateCheck, outcome: UpdateOutcome) {
        record(.updateCompleted, parameters: ["source": updateSource(source), "outcome": outcome.rawValue])
    }
    func recordLoginFailure(_ error: Error, operation: LoginOperation) {
        let error = error as NSError
        let category: String
        if #available(macOS 15.0, *), error.domain == SMAppServiceErrorDomain {
            if error.code == kSMErrorAlreadyRegistered && operation != .disable { return }
            if error.code == kSMErrorJobNotFound && operation == .disable { return }
            switch error.code {
            case kSMErrorInvalidSignature: category = "signature"
            case kSMErrorAuthorizationFailure, kSMErrorJobMustBeEnabled, kSMErrorLaunchDeniedByUser: category = "permission"
            case kSMErrorToolNotValid, kSMErrorJobNotFound, kSMErrorJobPlistNotFound: category = "notFound"
            case kSMErrorServiceUnavailable: category = "unavailable"
            case kSMErrorInvalidPlist: category = "configuration"
            case kSMErrorInternalFailure: category = "internal"
            default: category = "other"
            }
        } else {
            category = "other"
        }
        record(.loginFailed, parameters: ["operation": operation.rawValue, "category": category])
    }

    func recordUpdateFailure(_ error: Error, check: SPUUpdateCheck) {
        // Sparkle reports an up-to-date app and user cancellation through its error path.
        // Inspect bounded underlying errors for cancellation; never transmit error details.
        var underlying: NSError? = error as NSError
        for _ in 0..<5 {
            guard let current = underlying else { break }
            if current.domain == NSURLErrorDomain && current.code == NSURLErrorCancelled { return }
            if current.domain == SUSparkleErrorDomain && [
                Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue),
                Int(SUError.installationAuthorizeLaterError.rawValue)
            ].contains(current.code) { return }
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let error = error as NSError
        let category: String
        if error.domain == NSURLErrorDomain {
            category = "network"
        } else if error.domain == SUSparkleErrorDomain {
            switch error.code {
            case Int(SUError.appcastParseError.rawValue), Int(SUError.appcastError.rawValue), Int(SUError.resumeAppcastError.rawValue):
                category = "feed"
            case Int(SUError.downloadError.rawValue): category = "download"
            case Int(SUError.signatureError.rawValue), Int(SUError.validationError.rawValue): category = "signature"
            case 1...7, Int(SUError.incorrectAPIUsageError.rawValue): category = "configuration"
            case Int(SUError.unarchivingError.rawValue), 4000...4012: category = "installation"
            default: category = "other"
            }
        } else {
            category = "other"
        }
        record(.updateFailed, parameters: ["source": updateSource(check), "category": category])
    }

    private func updateSource(_ check: SPUUpdateCheck) -> String {
        switch check {
        case .updates: "manual"
        case .updatesInBackground: "automatic"
        case .updateInformation: "information"
        @unknown default: "unknown"
        }
    }

    static func updateOutcome(error: Error?, foundUpdate: Bool, cancelled: Bool) -> UpdateOutcome {
        if cancelled { return .cancelled }
        guard let error else { return foundUpdate ? .updateAvailable : .unknown }
        var current = error as NSError
        for _ in 0..<5 {
            if current.domain == NSURLErrorDomain && current.code == NSURLErrorCancelled { return .cancelled }
            if current.domain == SUSparkleErrorDomain {
                switch current.code {
                case Int(SUError.installationCanceledError.rawValue): return .cancelled
                case Int(SUError.installationAuthorizeLaterError.rawValue): return foundUpdate ? .updateAvailable : .unknown
                case Int(SUError.noUpdateError.rawValue):
                    let reason = (current.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
                    return reason == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue)
                        || reason == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue) ? .upToDate : .unknown
                default: break
                }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return .failed
    }

}
