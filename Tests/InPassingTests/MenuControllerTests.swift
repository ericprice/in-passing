import AppKit
import XCTest
@testable import InPassing

final class MenuControllerTests: XCTestCase {
    func testNativeCheckStatesShareAnImageFreeGutter() async throws {
        await MainActor.run {
            var state = MenuController.State()
            let controller = MenuController(state: { state }, perform: { _ in })
            XCTAssertEqual(controller.menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "—" : $0.title }, [
                "About In Passing", "—", "Check for Updates…", "Open at Login", "—", "Pause", "—",
                "Color", "Maximum Shapes", "—", "Clear…", "—", "Quit In Passing"
            ])
            let maximum = controller.menu.items.first { $0.title == "Maximum Shapes" }!.submenu!
            let choices = maximum.items.filter { !$0.isSeparatorItem }
            XCTAssertEqual(choices.filter { $0.state == .on }.map(\.title), ["5"])
            XCTAssertTrue(choices.allSatisfy { $0.image == nil && $0.indentationLevel == 0 })
            state.maximum = 15; controller.refresh(controller.menu)
            XCTAssertEqual(choices.filter { $0.state == .on }.map(\.title), ["15"])
            state.maximum = 7; controller.refresh(controller.menu)
            XCTAssertEqual(choices.filter { $0.state == .on }.map(\.title), ["Custom…"])
            let colors = controller.menu.items.first { $0.title == "Color" }!.submenu!.items
            XCTAssertEqual(colors.filter { $0.state == .on }.map(\.title), ["Match Wallpaper"])
            state.customColor = true; controller.refresh(controller.menu)
            XCTAssertEqual(colors.filter { $0.state == .on }.map(\.title), ["Custom Color…"])
            XCTAssertTrue(colors.allSatisfy { $0.image == nil && $0.indentationLevel == 0 })
        }
    }
    func testPermissionAndPauseStateUpdateWithoutStatusRows() async throws {
        await MainActor.run {
            var state = MenuController.State()
            let controller = MenuController(state: { state }, perform: { _ in })
            @MainActor func item(_ action: MenuController.Action) -> NSMenuItem {
                controller.menu.items.first { ($0.representedObject as? MenuController.Action) == action }!
            }
            XCTAssertTrue(item(.accessibility).isHidden)
            XCTAssertEqual(item(.pauseResume).title, "Pause")
            state.trusted = false; state.canCheckForUpdates = false; controller.refresh(controller.menu)
            XCTAssertFalse(item(.accessibility).isHidden)
            XCTAssertFalse(item(.pauseResume).isEnabled)
            XCTAssertFalse(item(.updates).isEnabled)
            state.trusted = true; state.paused = true; state.openAtLogin = true; controller.refresh(controller.menu)
            XCTAssertEqual(item(.pauseResume).title, "Resume")
            XCTAssertTrue(item(.pauseResume).isEnabled)
            XCTAssertEqual(item(.openAtLogin).state, .on)
        }
    }
}
