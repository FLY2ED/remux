import XCTest
@testable import Remux

final class GhosttySurfaceKeyEventTests: XCTestCase {
    func testKeyCodeConstantsUseGhosttyDarwinNativeKeycodes() {
        XCTAssertEqual(GhosttySurfaceKeyEvent.KeyCode.backspace.rawValue, 0x33)
        XCTAssertEqual(GhosttySurfaceKeyEvent.KeyCode.escape.rawValue, 0x35)
        XCTAssertEqual(GhosttySurfaceKeyEvent.KeyCode.enter.rawValue, 0x24)
        XCTAssertEqual(GhosttySurfaceKeyEvent.KeyCode.tab.rawValue, 0x30)
        XCTAssertEqual(GhosttySurfaceKeyEvent.KeyCode.delete.rawValue, 0x75)
        XCTAssertEqual(GhosttySurfaceKeyEvent.KeyCode.arrowLeft.rawValue, 0x7B)
        XCTAssertEqual(GhosttySurfaceKeyEvent.KeyCode.arrowRight.rawValue, 0x7C)
        XCTAssertEqual(GhosttySurfaceKeyEvent.KeyCode.arrowDown.rawValue, 0x7D)
        XCTAssertEqual(GhosttySurfaceKeyEvent.KeyCode.arrowUp.rawValue, 0x7E)
    }

    /// Ghostty's macOS keycodes for F1 to F12 and Help/Insert (`src/input/keycodes.zig`).
    func testFunctionKeyAndInsertCodesUseGhosttyDarwinNativeKeycodes() {
        XCTAssertEqual(
            GhosttySurfaceKeyEvent.KeyCode.functionKeys.map(\.rawValue),
            [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
        )
        XCTAssertEqual(GhosttySurfaceKeyEvent.KeyCode.insert.rawValue, 0x72)
    }

    func testWithCValuePreservesCoreFields() {
        let event = GhosttySurfaceKeyEvent(
            action: .repeat,
            keyCode: .arrowRight,
            text: "x",
            composing: true,
            mods: [.shift, .ctrl],
            consumedMods: [.alt],
            unshiftedCodepoint: 120
        )

        event.withCValue { cValue in
            XCTAssertEqual(cValue.action.rawValue, event.action.rawValue)
            XCTAssertEqual(cValue.keycode, event.keyCode.rawValue)
            XCTAssertTrue(cValue.composing)
            XCTAssertEqual(cValue.mods.rawValue, (GhosttySurfaceKeyEvent.Mods.shift.union(.ctrl)).rawValue)
            XCTAssertEqual(cValue.consumed_mods.rawValue, GhosttySurfaceKeyEvent.Mods.alt.rawValue)
            XCTAssertEqual(cValue.unshifted_codepoint, 120)
            XCTAssertNotNil(cValue.text)
            if let text = cValue.text {
                XCTAssertEqual(String(cString: text), "x")
            }
        }
    }

    func testWithCValueLeavesTextNilWhenAbsent() {
        let event = GhosttySurfaceKeyEvent(
            action: .press,
            keyCode: .escape
        )

        event.withCValue { cValue in
            XCTAssertEqual(cValue.action.rawValue, event.action.rawValue)
            XCTAssertEqual(cValue.keycode, event.keyCode.rawValue)
            XCTAssertNil(cValue.text)
        }
    }
}
