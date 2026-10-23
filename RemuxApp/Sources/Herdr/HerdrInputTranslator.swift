import Foundation

/// Turns what the phone types into the events Herdr's own client sends for the same input when it runs
/// in a plain terminal, one without the kitty keyboard protocol. Text is read as Herdr reads such a
/// terminal's bytes (`input/parse.rs`, `parse_legacy_key_sequence`); toolbar and hardware keys become
/// semantic keys. Herdr encodes each event for its pane's own keyboard mode.
enum HerdrInputTranslator {
    /// One event per Unicode scalar, as Herdr's raw input reads them. Control bytes become their keys
    /// and carry no text; ESC followed by one more scalar is that key with Alt. Every other scalar is a
    /// key that types itself (`TerminalKey::with_text_commit`), except that a pane asking for every key
    /// as an escape code gets non-ASCII text as a commit, as Herdr's client does on a plain terminal
    /// (`client/shell/input.rs`, `host_text_commit`).
    static func events(forText text: String, reportsAllKeys: Bool) -> [HerdrInputEvent] {
        var events: [HerdrInputEvent] = []
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            if scalar == escape, let next = scalars.next() {
                events.append(.key(key(for: next, alt: true)))
            } else if reportsAllKeys, !scalar.isASCII, controlKey(for: scalar) == nil {
                events.append(.text(String(scalar)))
            } else {
                events.append(.key(key(for: scalar, alt: false)))
            }
        }
        return events
    }

    /// The key for a toolbar or hardware key press, or nil for a release or a key Herdr has no code
    /// for. As in Herdr's client on a plain terminal, releases aren't sent; Herdr releases tracked
    /// presses itself when the surface deactivates. A repeat is another press.
    static func event(for key: GhosttySurfaceKeyEvent) -> HerdrInputEvent? {
        guard key.action != .release else { return nil }
        let modifiers = modifiers(for: key.mods)
        let code: HerdrKeyCode
        switch key.keyCode {
        case .enter: code = .enter
        case .escape: code = .escape
        case .backspace: code = .backspace
        case .delete: code = .delete
        case .arrowUp: code = .up
        case .arrowDown: code = .down
        case .arrowLeft: code = .left
        case .arrowRight: code = .right
        case .home: code = .home
        case .end: code = .end
        case .pageUp: code = .pageUp
        case .pageDown: code = .pageDown
        // Shift+Tab stays Tab with Shift: as BackTab its release would be lost under kitty event types.
        case .tab: code = .tab
        case .space:
            guard modifiers.isEmpty else {
                return .key(HerdrKeyEvent(code: .character(" "), modifiers: modifiers, tracksRelease: true))
            }
            return .key(HerdrKeyEvent(code: .character(" "), generatedText: " "))
        default:
            return nil
        }
        return .key(HerdrKeyEvent(code: code, modifiers: modifiers, tracksRelease: true))
    }

    /// Splits events into messages within Herdr's per-message event limit; over it, Herdr closes the
    /// connection.
    static func messages(_ events: [HerdrInputEvent]) -> [[HerdrInputEvent]] {
        stride(from: 0, to: events.count, by: HerdrConnection.maxInputEvents).map {
            Array(events[$0..<min($0 + HerdrConnection.maxInputEvents, events.count)])
        }
    }

    private static let escape: Unicode.Scalar = "\u{1b}"

    /// Only a plain or Shift-only character types itself, and only ASCII uppercase implies Shift.
    private static func key(for scalar: Unicode.Scalar, alt: Bool) -> HerdrKeyEvent {
        if let control = controlKey(for: scalar) {
            let modifiers = alt ? control.modifiers.union(.alt) : control.modifiers
            return HerdrKeyEvent(code: control.code, modifiers: modifiers, tracksRelease: true)
        }
        var modifiers: HerdrKeyModifiers = (0x41...0x5a).contains(scalar.value) ? [.shift] : []
        guard !alt else {
            modifiers.insert(.alt)
            return HerdrKeyEvent(code: .character(scalar), modifiers: modifiers, tracksRelease: true)
        }
        return HerdrKeyEvent(code: .character(scalar), modifiers: modifiers, generatedText: String(scalar))
    }

    /// Herdr's legacy control bytes. Carriage return, tab, ESC and DEL are their own keys; line feed is
    /// Ctrl+J, as in a raw-mode terminal.
    private static func controlKey(
        for scalar: Unicode.Scalar
    ) -> (code: HerdrKeyCode, modifiers: HerdrKeyModifiers)? {
        switch scalar.value {
        case 0x0d: return (.enter, [])
        case 0x09: return (.tab, [])
        case 0x1b: return (.escape, [])
        case 0x7f: return (.backspace, [])
        case 0x00: return (.character(" "), .control)
        case 0x01...0x1a: return (.character(Unicode.Scalar(scalar.value + 0x60)!), .control)
        case 0x1c: return (.character("\\"), .control)
        case 0x1d: return (.character("]"), .control)
        case 0x1e: return (.character("^"), .control)
        case 0x1f: return (.character("_"), .control)
        default: return nil
        }
    }

    private static func modifiers(for mods: GhosttySurfaceKeyEvent.Mods) -> HerdrKeyModifiers {
        var modifiers: HerdrKeyModifiers = []
        if mods.contains(.shift) { modifiers.insert(.shift) }
        if mods.contains(.ctrl) { modifiers.insert(.control) }
        if mods.contains(.alt) { modifiers.insert(.alt) }
        if mods.contains(.super) { modifiers.insert(.super) }
        return modifiers
    }
}
