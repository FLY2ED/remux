import XCTest
@testable import Remux

/// Expected values come from Herdr's own tests and rules: `input/parse.rs`
/// (`legacy_ctrl_byte_matrix_is_covered`, `parse_legacy_lf_sequence_as_ctrl_j`), `TerminalKey::with_text_commit`,
/// `ClientPaneInputEvent::from_terminal_key` (tracks_release) and `host_text_commit`.
final class HerdrInputTranslatorTests: XCTestCase {
    func testControlBytesAreControlKeysWithoutText() {
        for (byte, character) in [(0x01, "a"), (0x02, "b"), (0x03, "c"), (0x1a, "z"), (0x0a, "j"),
                                  (0x1c, "\\"), (0x1d, "]"), (0x1e, "^"), (0x1f, "_"), (0x00, " ")] {
            XCTAssertEqual(
                events(String(UnicodeScalar(UInt8(byte)))),
                [chord(.character(Unicode.Scalar(character)!), [.control])],
                "byte \(byte)"
            )
        }
    }

    func testCarriageReturnTabEscapeAndDeleteAreTheirKeys() {
        XCTAssertEqual(events("\r"), [chord(.enter)])
        XCTAssertEqual(events("\t"), [chord(.tab)])
        XCTAssertEqual(events("\u{1b}"), [chord(.escape)])
        XCTAssertEqual(events("\u{7f}"), [chord(.backspace)])
    }

    func testEscapeFollowedByAKeyIsThatKeyWithAlt() {
        XCTAssertEqual(events("\u{1b}x"), [chord(.character("x"), [.alt])])
        XCTAssertEqual(events("\u{1b}X"), [chord(.character("X"), [.shift, .alt])])
        XCTAssertEqual(events("\u{1b}\u{7f}"), [chord(.backspace, [.alt])])
        XCTAssertEqual(events("\u{1b}\u{03}"), [chord(.character("c"), [.control, .alt])])
    }

    func testTypedCharactersTypeThemselves() {
        XCTAssertEqual(events("ab"), [typed("a"), typed("b")])
        XCTAssertEqual(events("A"), [typed("A", [.shift])])
        XCTAssertEqual(events(" "), [typed(" ")])
        // Only ASCII uppercase implies Shift.
        XCTAssertEqual(events("éÉ"), [typed("é"), typed("É")])
        // One event per scalar, so a skin-tone emoji reaches the pane as its two scalars in order.
        XCTAssertEqual(events("👍🏽"), [typed("👍"), typed("🏽")])
    }

    func testReportAllPaneGetsNonASCIITextAsCommits() {
        XCTAssertEqual(
            HerdrInputTranslator.events(forText: "日本a\u{03}", reportsAllKeys: true),
            [.text("日"), .text("本"), typed("a"), chord(.character("c"), [.control])]
        )
    }

    func testKeysBecomeSemanticKeysWithoutText() {
        XCTAssertEqual(key(.arrowUp), chord(.up))
        XCTAssertEqual(key(.enter), chord(.enter))
        XCTAssertEqual(key(.tab, [.shift]), chord(.tab, [.shift]))
        XCTAssertEqual(key(.arrowLeft, [.ctrl, .alt]), chord(.left, [.control, .alt]))
        XCTAssertEqual(key(.pageDown, [.super]), chord(.pageDown, [.super]))
        XCTAssertEqual(key(.space), typed(" "))
        XCTAssertEqual(key(.space, [.ctrl]), chord(.character(" "), [.control]))
        XCTAssertEqual(
            HerdrInputTranslator.event(for: GhosttySurfaceKeyEvent(action: .repeat, keyCode: .backspace)),
            chord(.backspace)
        )
        XCTAssertNil(HerdrInputTranslator.event(for: GhosttySurfaceKeyEvent(action: .release, keyCode: .enter)))
        XCTAssertNil(key(GhosttySurfaceKeyEvent.KeyCode(rawValue: 0x00)))
    }

    func testMessagesStayWithinHerdrsEventLimit() {
        let events = Array(repeating: typed("a"), count: HerdrConnection.maxInputEvents + 1)
        let messages = HerdrInputTranslator.messages(events)
        XCTAssertEqual(messages.map(\.count), [HerdrConnection.maxInputEvents, 1])
        XCTAssertEqual(HerdrInputTranslator.messages([]), [])
    }

    /// The bytes of a typed character and a paste match the v0.9.3 recording (`herdr-14-input-A`).
    func testTranslatedInputMatchesRecordedWireBytes() {
        XCTAssertEqual(
            hex(HerdrClientMessage.paneInput(paneID: "w1:p1", events: events("x")).frame),
            "150000000d0577313a703101000f7800000100010178000000"
        )
        XCTAssertEqual(
            hex(HerdrClientMessage.paneInput(paneID: "w1:p1", events: [.paste("pasted\ntext")]).frame),
            "150000000d0577313a703101030b7061737465640a74657874"
        )
    }

    private func events(_ text: String) -> [HerdrInputEvent] {
        HerdrInputTranslator.events(forText: text, reportsAllKeys: false)
    }

    private func key(
        _ code: GhosttySurfaceKeyEvent.KeyCode,
        _ mods: GhosttySurfaceKeyEvent.Mods = []
    ) -> HerdrInputEvent? {
        HerdrInputTranslator.event(for: GhosttySurfaceKeyEvent(keyCode: code, mods: mods))
    }

    private func typed(_ character: Unicode.Scalar, _ modifiers: HerdrKeyModifiers = []) -> HerdrInputEvent {
        .key(HerdrKeyEvent(code: .character(character), modifiers: modifiers, generatedText: String(character)))
    }

    private func chord(_ code: HerdrKeyCode, _ modifiers: HerdrKeyModifiers = []) -> HerdrInputEvent {
        .key(HerdrKeyEvent(code: code, modifiers: modifiers, tracksRelease: true))
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
