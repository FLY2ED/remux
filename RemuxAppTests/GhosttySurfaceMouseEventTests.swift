import XCTest
import CoreGraphics
import GhosttyKit
@testable import Remux

final class GhosttySurfaceMouseEventTests: XCTestCase {
    func testMouseButtonEventPreservesCValues() {
        let event = GhosttySurfaceMouseButtonEvent(
            state: .press,
            button: .right,
            mods: [.alt, .ctrl]
        )

        event.withCValues { state, button, mods in
            XCTAssertEqual(state, GHOSTTY_MOUSE_PRESS)
            XCTAssertEqual(button, GHOSTTY_MOUSE_RIGHT)
            XCTAssertEqual(mods.rawValue, GhosttySurfaceKeyEvent.Mods([.alt, .ctrl]).rawValue)
        }
    }

    func testMouseScrollModsEncodePrecisionAndMomentum() {
        let mods = GhosttySurfaceMouseScrollMods(
            precision: true,
            momentum: .changed
        )

        XCTAssertTrue(mods.precision)
        XCTAssertEqual(mods.momentum, .changed)
        XCTAssertEqual(mods.rawValue, 0b0000_0111)
    }

    func testMouseScrollModsRoundTripRawValue() {
        let mods = GhosttySurfaceMouseScrollMods(rawValue: 0b0000_1001)

        XCTAssertTrue(mods.precision)
        XCTAssertEqual(mods.momentum, .ended)
    }

    func testTapGestureActivatesInputOnlyWhenMouseIsNotCaptured() {
        XCTAssertEqual(
            GhosttySurfaceTapGesture.actions(
                forLocalPoint: CGPoint(x: 10, y: 20),
                mouseCaptured: false
            ),
            [.activateInput]
        )
    }

    /// A tap on a pane that isn't focused only focuses it, keyboard aside, unless its program reads the
    /// mouse: then it is a click there too, as tmux's and Herdr's own clients make it.
    func testTapGestureOnAnUnfocusedPaneFocusesItAndClicksWhenMouseIsCaptured() {
        let point = CGPoint(x: 10, y: 20)

        XCTAssertEqual(
            GhosttySurfaceTapGesture.actions(forLocalPoint: point, mouseCaptured: false, showsKeyboard: false),
            [.focusPane]
        )
        XCTAssertEqual(
            GhosttySurfaceTapGesture.actions(forLocalPoint: point, mouseCaptured: true, showsKeyboard: false),
            [
                .focusPane,
                .mousePosition(point),
                .mouseButton(.init(state: .press, button: .left)),
                .mouseButton(.init(state: .release, button: .left)),
            ]
        )
    }

    func testTapGestureActivatesInputAndEmitsMouseClickWhenMouseIsCaptured() {
        let point = CGPoint(x: 10, y: 20)

        XCTAssertEqual(
            GhosttySurfaceTapGesture.actions(
                forLocalPoint: point,
                mouseCaptured: true
            ),
            [
                .activateInput,
                .mousePosition(point),
                .mouseButton(.init(state: .press, button: .left)),
                .mouseButton(.init(state: .release, button: .left)),
            ]
        )
    }

}
