import CoreGraphics
import XCTest
@testable import InPassingCore

final class CompositionTests: XCTestCase {
    func testMaximumKeepsOnlyMostRecentShapes() {
        let desktop = CGRect(x: -1000, y: 0, width: 3000, height: 1200)
        let traces = (0..<14).map { index in WindowTrace(frame: CGRect(x: index * 20, y: 50, width: 500, height: 400), desktop: desktop)! }
        XCTAssertEqual(activeTraces(traces, maximum: 5).map(\.id), Array(traces.suffix(5)).map(\.id))
        XCTAssertEqual(activeTraces(traces, maximum: 10).count, 10)
        XCTAssertEqual(activeTraces(traces, maximum: 20).count, 14)
    }
    func testStrokeScalesWithHorizontalResolutionAndContrastIsBlackOrWhite() {
        XCTAssertEqual(outlineWidth(screenWidth: 1512), 7.56, accuracy: 0.00001)
        XCTAssertEqual(outlineWidth(screenWidth: 1512) * 2, 3024 * 0.005, accuracy: 0.00001)
        XCTAssertEqual(outlineWidth(screenWidth: 2560), 12.8, accuracy: 0.00001)
        XCTAssertTrue(prefersWhiteOutline(luminance: 0))
        XCTAssertTrue(prefersWhiteOutline(luminance: 0.05))
        XCTAssertFalse(prefersWhiteOutline(luminance: 0.5))
        XCTAssertFalse(prefersWhiteOutline(luminance: 1))
    }
}
