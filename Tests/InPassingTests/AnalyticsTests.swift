import AppKit
import XCTest
import PostHog
import Sparkle
@testable import InPassing

private final class AnalyticsTestTransport: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var events: [[String: Any]] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
        }
        if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            Self.lock.lock(); Self.events.append(contentsOf: body["batch"] as? [[String: Any]] ?? []); Self.lock.unlock()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    static func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return events }
}

final class AnalyticsTests: XCTestCase {
    func testOnlyRealStateChangesProduceEventsAndOptOutStopsCapture() async {
        await MainActor.run {
            let suite = "InPassingAnalyticsTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var events: [(String, [String: String])] = []
            let analytics = AppAnalytics(defaults: defaults, capture: { events.append(($0, $1)) })
            var state = AppAnalytics.State()
            analytics.launch(state); analytics.observe(state)
            XCTAssertEqual(events.map(\.0), ["app_launched"])
            state.maximum = 7; state.colorMode = "custom"; state.customColor = [0.2, 0.3, 0.4]
            analytics.observe(state); analytics.observe(state)
            XCTAssertEqual(events.map(\.0), ["app_launched", "maximum_shapes_changed", "color_changed"])
            XCTAssertEqual(events[1].1, ["previousValue": "5", "value": "7", "source": "custom"])
            XCTAssertEqual(events[2].1, ["previousMode": "automatic", "mode": "custom"])
            state.customColor = [0.4, 0.5, 0.6]; analytics.observe(state)
            XCTAssertEqual(events.last?.0, "color_changed")
            state.accessibility = true; state.paused = true; state.loginStatus = "enabled"
            analytics.observe(state)
            XCTAssertEqual(events.suffix(3).map(\.0), ["accessibility_changed", "observation_toggled", "preferences_changed"])
            defaults.set(false, forKey: "shareUsageStatistics")
            let count = events.count
            analytics.record(.clear); state.maximum = 20; analytics.observe(state)
            XCTAssertEqual(events.count, count)
            XCTAssertTrue(events.allSatisfy { !$0.1.keys.contains("customColor") })
        }
    }
    func testUpdateResultsDoNotTreatCurrentVersionOrCancellationAsFailures() async {
        await MainActor.run {
            let noUpdate = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue), userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.onLatestVersion.rawValue)])
            XCTAssertEqual(AppAnalytics.updateOutcome(error: noUpdate, foundUpdate: false, cancelled: false), .upToDate)
            XCTAssertEqual(AppAnalytics.updateOutcome(error: URLError(.cancelled), foundUpdate: false, cancelled: false), .cancelled)
            XCTAssertEqual(AppAnalytics.updateOutcome(error: nil, foundUpdate: false, cancelled: false), .unknown)
            XCTAssertEqual(AppAnalytics.updateOutcome(error: nil, foundUpdate: true, cancelled: false), .updateAvailable)
            var events: [String] = []
            let analytics = AppAnalytics(capture: { events.append($0); XCTAssertFalse($1.values.contains("PRIVATE ERROR")) })
            analytics.recordUpdateFailure(noUpdate, check: .updates)
            analytics.recordUpdateFailure(URLError(.cancelled), check: .updates)
            XCTAssertTrue(events.isEmpty)
            analytics.recordUpdateFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "PRIVATE ERROR"]), check: .updates)
            XCTAssertEqual(events, ["update_check_failed"])
        }
    }
    func testDailyPresenceDeduplicatesAcrossRelaunchAndRespectsOptOut() async {
        await MainActor.run {
            let suite = "InPassingDailyTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var now = Date(timeIntervalSince1970: 1_792_800_000)
            var enabled = true
            var events = 0
            let reporter = AppRunningDailyReporter(defaults: defaults, now: { now }, enabled: { enabled }, record: { _ in events += 1 })
            reporter.start(); reporter.resume(); reporter.stop(); reporter.start()
            XCTAssertEqual(events, 1)
            now.addTimeInterval(86_400); enabled = false; reporter.resume()
            XCTAssertEqual(events, 1)
            enabled = true; reporter.resume()
            XCTAssertEqual(events, 2)
            reporter.stop()
        }
    }
    func testBuildProvenanceCannotPromoteDevelopmentTraffic() {
        let context = AnalyticsContext.resolve(bundled: [:], processEnvironment: ["IN_PASSING_ANALYTICS_ENVIRONMENT": "production", "IN_PASSING_ANALYTICS_INTERNAL": "false"], internalTesting: false, appVersion: "1.0", appBuild: "2")
        XCTAssertEqual(context.environment, "development"); XCTAssertTrue(context.isInternal)
        let production = ["IN_PASSING_ANALYTICS_ENVIRONMENT": "production", "IN_PASSING_ANALYTICS_INTERNAL": "false"]
        XCTAssertFalse(AnalyticsContext.resolve(bundled: production, processEnvironment: [:], internalTesting: false, appVersion: "1.0", appBuild: "2").isInternal)
        XCTAssertTrue(AnalyticsContext.resolve(bundled: production, processEnvironment: [:], internalTesting: true, appVersion: "1.0", appBuild: "2").isInternal)
    }
    @MainActor func testRealSDKStripsUnexpectedPayloadsAndBlocksOptedOutTransport() async throws {
        let suite = "InPassingSDKTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [AnalyticsTestTransport.self]
        let config = PostHogConfiguration.makeConfig(projectToken: "phc_tests" + UUID().uuidString, host: "https://analytics.invalid", defaults: defaults, sessionConfiguration: session)
        XCTAssertEqual(config.personProfiles, .never); XCTAssertTrue(config.disableGeoIp)
        XCTAssertFalse(config.captureApplicationLifecycleEvents); XCTAssertFalse(config.captureScreenViews)
        XCTAssertFalse(config.enableSwizzling); XCTAssertFalse(config.errorTrackingConfig.autoCapture)
        XCTAssertFalse(config.preloadFeatureFlags); XCTAssertEqual(config.flushIntervalSeconds, 300)
        config.compression = .none; config.flushAt = 100
        let sdk = PostHogSDK.with(config); defer { sdk.close() }
        sdk.capture("unexpected_private_event", properties: ["title": "PRIVATE SENTINEL"])
        sdk.capture("app_launched", properties: ["maximumShapes": "5", "windowGeometry": "PRIVATE SENTINEL", "title": "PRIVATE SENTINEL"])
        sdk.flush()
        for _ in 0..<100 where AnalyticsTestTransport.snapshot().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let received = AnalyticsTestTransport.snapshot()
        XCTAssertEqual(received.map { $0["event"] as? String }, ["app_launched"])
        let properties = try XCTUnwrap(received.first?["properties"] as? [String: Any])
        XCTAssertNil(properties["title"]); XCTAssertNil(properties["windowGeometry"])
        XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
        XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)
        XCTAssertEqual(properties["is_internal"] as? String, "true")
        defaults.set(false, forKey: "shareUsageStatistics")
        XCTAssertTrue(PostHogConsentURLProtocol.canInit(with: URLRequest(url: URL(string: "https://analytics.invalid/batch")!)))
        sdk.capture("app_launched"); sdk.flush()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(AnalyticsTestTransport.snapshot().count, received.count)
    }
}
