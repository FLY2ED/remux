import Foundation

/// The messages of Herdr's direct terminal connection, the one `herdr terminal attach` makes: a
/// `TerminalHello` instead of the endpoint hello, then one terminal's stream as terminal bytes (Herdr
/// v0.9.3 and v0.9.5 `src/protocol/wire.rs`, protocol 22; the variant order is the tag, as on the
/// endpoint connection). Remux sends no input this way (`HerdrTerminalAttachment`).
enum HerdrDirectTerminalClientMessage: Equatable, Sendable {
    enum ScrollDirection: UInt32, Equatable, Sendable {
        case up = 0
        case down = 1
    }

    /// Must be the first message: the client's terminal size, which an attach gives the terminal.
    case hello(columns: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32)
    case resize(columns: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32)
    case detach
    /// Without `takeover`, Herdr refuses a terminal another direct client already holds.
    case attach(terminalID: String, takeover: Bool)
    /// A mouse wheel step, which Herdr routes as the program asks: a mouse report, cursor keys on the
    /// alternate screen, or the terminal's own history (`server/pane_input.rs` `apply_scroll`).
    case scroll(ScrollDirection, lines: UInt16, column: UInt16?, row: UInt16?)

    static let protocolVersion: UInt32 = 22

    var frame: [UInt8] {
        HerdrWire.frame(payload)
    }

    var payload: [UInt8] {
        var writer = HerdrWireWriter()
        switch self {
        case .hello(let columns, let rows, let cellWidthPx, let cellHeightPx):
            writer.variant(0)
            writer.u32(Self.protocolVersion)
            writer.u16(columns)
            writer.u16(rows)
            writer.u32(cellWidthPx)
            writer.u32(cellHeightPx)
            writer.bool(false)
        case .resize(let columns, let rows, let cellWidthPx, let cellHeightPx):
            writer.variant(3)
            writer.u16(columns)
            writer.u16(rows)
            writer.u32(cellWidthPx)
            writer.u32(cellHeightPx)
            writer.bool(false)
        case .detach:
            writer.variant(4)
        case .attach(let terminalID, let takeover):
            writer.variant(5)
            writer.string(terminalID)
            writer.bool(takeover)
        case .scroll(let direction, let lines, let column, let row):
            writer.variant(6)
            writer.variant(0)
            writer.variant(direction.rawValue)
            writer.u16(lines)
            writer.optional(column) { $0.u16($1) }
            writer.optional(row) { $0.u16($1) }
            writer.u8(0)
        }
        return writer.bytes
    }
}

/// One frame of a direct terminal: terminal bytes for a terminal of `columns` × `rows`, a full redraw or
/// changes to the frame before.
struct HerdrDirectTerminalFrame: Equatable, Sendable {
    let sequence: UInt64
    let columns: UInt16
    let rows: UInt16
    let full: Bool
    let bytes: [UInt8]
}

/// What Herdr sends a direct terminal client. The other types Herdr sends one, such as graphics,
/// notifications, sounds and window titles, are skipped; the rest go only to Herdr's own client
/// (`server/headless.rs` `send_to_client_shells`). The direct terminal protocol is Herdr's private one, not
/// its stable endpoint contract (`protocol/endpoint.rs`), so a type outside these is an error: the caller
/// stops trusting the connection.
enum HerdrDirectTerminalServerMessage: Equatable, Sendable {
    case welcome(version: UInt32, terminalBytes: Bool, error: String?)
    case frame(HerdrDirectTerminalFrame)
    /// The connection ends after this: a detach, a refused attach, or the terminal gone.
    case shutdown(reason: String?)
    case mouseCapture(enabled: Bool)
    /// The keyboard protocol the program asked for, as Herdr's client sets it on its own terminal
    /// (`terminal_modes.rs` `set_direct_host_keyboard_protocol`): kitty flags, 0 for none, and the
    /// modifyOtherKeys level.
    case keyboardProtocol(kittyFlags: UInt16, modifyOtherKeysLevel: UInt8)
    case skipped(tag: UInt32)

    /// Decodes one payload (without its length prefix) and requires it to be consumed exactly.
    static func decode(_ payload: [UInt8]) throws -> HerdrDirectTerminalServerMessage {
        var reader = HerdrWireReader(payload)
        let tag = try reader.variant()
        let message: HerdrDirectTerminalServerMessage
        switch tag {
        case 0:
            let version = try reader.u32()
            let encoding = try reader.variant()
            guard encoding <= 1 else {
                throw HerdrWireError.invalidVariant(type: "RenderEncoding", index: encoding)
            }
            message = .welcome(version: version, terminalBytes: encoding == 1, error: try reader.optional { try $0.string() })
        case 1:
            message = .frame(HerdrDirectTerminalFrame(
                sequence: try reader.u64(),
                columns: try reader.u16(),
                rows: try reader.u16(),
                full: try reader.bool(),
                bytes: try reader.byteArray()
            ))
        case 3:
            message = .shutdown(reason: try reader.optional { try $0.string() })
        case 8:
            let enabled = try reader.bool()
            _ = try reader.bool()
            message = .mouseCapture(enabled: enabled)
        case 16:
            message = .keyboardProtocol(kittyFlags: try reader.u16(), modifyOtherKeysLevel: try reader.u8())
        case 2, 4, 5, 6, 7, 9, 10, 11:
            return .skipped(tag: tag)
        default:
            throw HerdrWireError.unknownMessage(tag: tag)
        }
        try reader.finish()
        return message
    }
}
