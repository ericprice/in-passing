import AppKit
import XCTest
import InPassingCore
@testable import InPassing

final class DesktopDrawingTests: XCTestCase {
    func testRollingHistorySurvivesRelaunchAndClear() async throws {
        await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = DrawingStore(folder: folder)
            let desktop = CGRect(x: 0, y: 0, width: 1000, height: 800)
            for index in 0..<105 { store.record(CGRect(x: index, y: 100, width: 500, height: 400), desktop: desktop) }
            XCTAssertEqual(store.traces.count, 100)
            let ids = store.traces.map(\.id)
            let restored = DrawingStore(folder: folder)
            XCTAssertEqual(restored.traces.map(\.id), ids)
            restored.clear()
            XCTAssertTrue(restored.traces.isEmpty)
            XCTAssertTrue(DrawingStore(folder: folder).traces.isEmpty)
        }
    }
    func testPreviousDailyDrawingIsPreservedAndContinuesAsRollingHistory() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let trace = WindowTrace(frame: CGRect(x: 20, y: 40, width: 600, height: 400), desktop: CGRect(x: 0, y: 0, width: 1000, height: 800), at: Date().addingTimeInterval(-86400))!
            struct OldPage: Encodable { let aspect: Double; let traces: [WindowTrace] }
            let original = try JSONEncoder().encode(OldPage(aspect: 1.25, traces: [trace]))
            let archive = folder.appendingPathComponent("2026-10-22.json")
            try original.write(to: archive)
            let store = DrawingStore(folder: folder)
            XCTAssertEqual(store.traces, [trace])
            XCTAssertEqual(try Data(contentsOf: archive), original)
            XCTAssertEqual(DrawingStore(folder: folder).traces, [trace])
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("drawing.json").path))
        }
    }
    func testDefaultLimitAndCustomColorPreferencesPersist() async throws {
        await MainActor.run {
            let suite = "InPassingTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = DrawingPreferences(defaults: defaults)
            XCTAssertEqual(preferences.maximumShapes, 5)
            XCTAssertEqual(preferences.colorMode, .automatic)
            preferences.maximumShapes = 7
            preferences.colorMode = .custom
            preferences.customColor = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1)
            let restored = DrawingPreferences(defaults: defaults)
            XCTAssertEqual(restored.maximumShapes, 7)
            XCTAssertEqual(restored.colorMode, .custom)
            XCTAssertEqual(restored.customColor.redComponent, 0.2, accuracy: 0.0001)
            XCTAssertEqual(restored.customColor.blueComponent, 0.8, accuracy: 0.0001)
        }
    }
    func testWallpaperSamplesChooseWhiteForDarkAndBlackForLight() async throws {
        try await MainActor.run {
            for (value, expected) in [(0.0, 1.0), (0.1, 1.0), (0.9, 0.0), (1.0, 0.0)] {
                let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(CGColor(srgbRed: value, green: value, blue: value, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
                let result = WallpaperContrast.sample(try XCTUnwrap(context.makeImage()), screenSize: CGSize(width: 2560, height: 1440))
                XCTAssertTrue(result.sampled)
                XCTAssertEqual(result.color.usingColorSpace(.sRGB)!.redComponent, expected, accuracy: 0.001)
            }
        }
    }
}
