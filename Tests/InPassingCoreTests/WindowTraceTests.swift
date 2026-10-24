import CoreGraphics
import XCTest
@testable import InPassingCore
final class WindowTraceTests: XCTestCase {
    func testNormalizeAndClipAcrossDisplays() throws {
        let trace = try XCTUnwrap(WindowTrace(frame: CGRect(x: -1100, y: 100, width: 800, height: 600), desktop: CGRect(x: -1000, y: 0, width: 3000, height: 1200)))
        XCTAssertEqual(trace.x, 0); XCTAssertEqual(trace.width, 700.0 / 3000, accuracy: 0.00001)
        XCTAssertEqual(trace.y, 100.0 / 1200, accuracy: 0.00001)
        XCTAssertNil(WindowTrace(frame: CGRect(x: 5000, y: 0, width: 100, height: 100), desktop: CGRect(x: 0, y: 0, width: 1000, height: 800)))
    }
    func testCloseUsesLatestGeometryOnlyOnceAndResetCreatesNoTrace() {
        let id = UUID(); var ledger = WindowLedger()
        ledger.update(id, frame: CGRect(x: 10, y: 20, width: 300, height: 200))
        let final = CGRect(x: 70, y: 80, width: 500, height: 400)
        ledger.update(id, frame: final)
        XCTAssertEqual(ledger.close(id), final); XCTAssertNil(ledger.close(id))
        ledger.update(id, frame: final); ledger.reset(); XCTAssertNil(ledger.close(id))
    }
    func testHideOrMinimizeMarksOnceAndRestoreRearmsTheWindow() {
        let id = UUID(); var ledger = WindowLedger()
        let initial = CGRect(x: 10, y: 20, width: 300, height: 200)
        let moved = CGRect(x: 70, y: 80, width: 500, height: 400)
        ledger.update(id, frame: initial)
        ledger.update(id, frame: moved)
        XCTAssertEqual(ledger.setVisible(id, false), moved)
        // Duplicate hide/minimize signals cannot make another mark for the same disappearance.
        XCTAssertNil(ledger.setVisible(id, false))
        ledger.update(id, frame: initial)
        XCTAssertNil(ledger.setVisible(id, false))
        XCTAssertNil(ledger.setVisible(id, true))
        XCTAssertEqual(ledger.setVisible(id, false), initial)
        XCTAssertNil(ledger.close(id))
        XCTAssertEqual(ledger.count, 0)
    }
    func testHiddenBaselineAndPauseDoNotMakeMarks() {
        let id = UUID(); var ledger = WindowLedger()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        ledger.update(id, frame: frame, visible: false)
        XCTAssertNil(ledger.setVisible(id, false))
        XCTAssertNil(ledger.setVisible(id, true))
        XCTAssertEqual(ledger.close(id), frame)
        ledger.update(id, frame: frame, visible: false)
        XCTAssertNil(ledger.close(id))
        ledger.update(id, frame: frame)
        ledger.reset()
        XCTAssertNil(ledger.setVisible(id, false))
        XCTAssertNil(ledger.close(id))
    }
    func testSavedTraceHasOnlyGeometryIdentityAndClosureTime() throws {
        let trace = try XCTUnwrap(WindowTrace(frame: CGRect(x: 10, y: 20, width: 300, height: 200), desktop: CGRect(x: 0, y: 0, width: 1000, height: 800)))
        let data = try JSONEncoder().encode(trace)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set(["id", "closedAt", "x", "y", "width", "height", "desktop"]))
        let fallback = CGRect(x: -2000, y: 0, width: 5000, height: 2000)
        XCTAssertEqual(trace.frame(in: fallback), CGRect(x: 10, y: 20, width: 300, height: 200))
        var oldFields = fields; oldFields.removeValue(forKey: "desktop")
        let old = try JSONDecoder().decode(WindowTrace.self, from: JSONSerialization.data(withJSONObject: oldFields))
        XCTAssertNil(old.desktop)
        XCTAssertEqual(old.frame(in: CGRect(x: 0, y: 0, width: 1000, height: 800)), trace.frame(in: fallback))
    }
}
