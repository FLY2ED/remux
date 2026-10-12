import Foundation

/// Turns part of a Herdr frame into VT bytes for a local terminal of exactly that part's size: a pane's
/// text area (`innerRect`) for that pane's producer, or a whole popup frame for the popup's (plan D9).
///
/// Each painted row is repainted whole, right to left, with every cell placed at its own column. A wide
/// grapheme painted after its right neighbour covers that column, and `""` covered cells aren't written,
/// so wide characters, emoji and combining marks land where Herdr's grid has them without a width table.
/// Cells and links are encoded as Herdr's own client encodes them (`protocol/render_ansi.rs`). The painted
/// terminal needs grapheme clustering on and autowrap off, as Herdr's client sets them: with clustering
/// off, ZWJ sequences, flags and VS16 emoji split across cells, and with autowrap on, a wide grapheme in the
/// last column wraps into the next row (remux-docs `evidence/herdr-stage4-traces-20261009/frames/`,
/// Question 2).
///
/// Every paint ends with the area's cursor, because placing cells moves the terminal's cursor. Feed each
/// paint in one producer call, so the renderer never draws a half-painted area. The area must lie inside
/// the frame, which `HerdrPresentation` checks for every surface it accepts.
enum HerdrPanePainter {
    /// Grapheme clustering (mode 2027) on and autowrap off.
    static let terminalSetup: [UInt8] = Array("\u{1B}[?2027h\u{1B}[?7l".utf8)

    /// Everything a terminal of the area's size needs to show it: the modes, every row and the cursor.
    /// For a new terminal, after a resize, and when a terminal is recovered.
    static func repaint(_ frame: HerdrFrame, area: HerdrSurfaceRect) -> [UInt8] {
        terminalSetup
            + rows(0..<Int(area.height), of: frame, area: area)
            + cursorBytes(cursor(frame.cursor, in: area))
    }

    /// After a patch was applied to `frame`: the area's rows the patch changed, then the cursor. Empty
    /// when the patch changed nothing the area shows, as for a patch that only updates pane metadata.
    static func update(
        after patch: HerdrPaneSurfacePatch,
        previousCursor: HerdrCursor?,
        frame: HerdrFrame,
        area: HerdrSurfaceRect
    ) -> [UInt8] {
        let changed = changedRows(patch, area: area)
        let shown = cursor(frame.cursor, in: area)
        if changed.isEmpty {
            return shown == cursor(previousCursor, in: area) ? [] : cursorBytes(shown)
        }
        return rows(changed, of: frame, area: area) + cursorBytes(shown)
    }

    /// The area's rows, top first, that a patch's spans touch inside the area's columns.
    static func changedRows(_ patch: HerdrPaneSurfacePatch, area: HerdrSurfaceRect) -> [Int] {
        let top = Int(area.y)
        let left = Int(area.x)
        var rows = Set<Int>()
        for row in patch.rows {
            let y = Int(row.y) - top
            let start = Int(row.x)
            if y >= 0, y < Int(area.height), start < left + Int(area.width), start + row.cells.count > left {
                rows.insert(y)
            }
        }
        return rows.sorted()
    }

    /// The listed rows of the area (0 is its top row), each right to left, then SGR 0.
    static func rows(_ rows: some Sequence<Int>, of frame: HerdrFrame, area: HerdrSurfaceRect) -> [UInt8] {
        let links = frame.hyperlinks.map(sanitizedLink)
        var bytes: [UInt8] = []
        for y in rows {
            let start = (Int(area.y) + y) * Int(frame.width) + Int(area.x)
            for x in stride(from: Int(area.width) - 1, through: 0, by: -1) {
                let cell = frame.cells[start + x]
                if cell.symbol.isEmpty || cell.skip { continue }
                let link = cell.hyperlink.flatMap { Int($0) < links.count ? links[Int($0)] : nil }
                appendCursorPosition(row: y, column: x, to: &bytes)
                appendSGR(cell, to: &bytes)
                if let link {
                    bytes += osc8Prefix
                    bytes += link
                    bytes += stringTerminator
                }
                bytes += cell.symbol.utf8
                if link != nil {
                    bytes += osc8Prefix
                    bytes += stringTerminator
                }
            }
        }
        bytes += resetSGR
        return bytes
    }

    /// The frame's cursor in area coordinates, or nil when it's hidden or outside the area (another
    /// pane's cursor, or none of the panes').
    static func cursor(_ cursor: HerdrCursor?, in area: HerdrSurfaceRect) -> HerdrCursor? {
        guard let cursor,
              cursor.visible,
              cursor.x >= area.x, Int(cursor.x) < Int(area.x) + Int(area.width),
              cursor.y >= area.y, Int(cursor.y) < Int(area.y) + Int(area.height)
        else {
            return nil
        }
        return HerdrCursor(x: cursor.x - area.x, y: cursor.y - area.y, visible: true, shape: cursor.shape)
    }

    /// A visible cursor is placed, shaped (DECSCUSR) and then shown, in the order of Herdr's client
    /// (`render_ansi.rs:833-844`); otherwise it is hidden.
    static func cursorBytes(_ cursor: HerdrCursor?) -> [UInt8] {
        guard let cursor else { return Array("\u{1B}[?25l".utf8) }
        var bytes: [UInt8] = []
        appendCursorPosition(row: Int(cursor.y), column: Int(cursor.x), to: &bytes)
        bytes += Array("\u{1B}[\(cursor.shape) q\u{1B}[?25h".utf8)
        return bytes
    }

    /// Herdr's client drops every control character from a link and treats an empty result as no link
    /// (`render_ansi.rs:904-910`).
    static func sanitizedLink(_ uri: String) -> [UInt8]? {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: uri.unicodeScalars.filter { $0.properties.generalCategory != .control })
        return scalars.isEmpty ? nil : Array(String(scalars).utf8)
    }

    // MARK: - Encoding

    private static let resetSGR: [UInt8] = Array("\u{1B}[0m".utf8)
    /// ratatui's modifier bits before and after underline, with their SGR codes.
    private static let leadingModifiers: [(bit: UInt16, code: UInt8)] = [(1, 0x31), (2, 0x32), (4, 0x33)]
    private static let trailingModifiers: [(bit: UInt16, code: UInt8)] = [
        (16, 0x35), (32, 0x36), (64, 0x37), (128, 0x38), (256, 0x39),
    ]
    private static let osc8Prefix: [UInt8] = Array("\u{1B}]8;;".utf8)
    private static let stringTerminator: [UInt8] = [0x1B, 0x5C]

    /// CUP, 1-based.
    private static func appendCursorPosition(row: Int, column: Int, to bytes: inout [UInt8]) {
        bytes += [0x1B, 0x5B]
        appendDecimal(row + 1, to: &bytes)
        bytes.append(0x3B)
        appendDecimal(column + 1, to: &bytes)
        bytes.append(0x48)
    }

    /// Herdr's `build_sgr` (`render_ansi.rs:341-477`): reset, the modifiers, then foreground and
    /// background.
    private static func appendSGR(_ cell: HerdrCell, to bytes: inout [UInt8]) {
        bytes += [0x1B, 0x5B, 0x30]
        let modifier = cell.modifier
        for (bit, code) in leadingModifiers where modifier & bit != 0 {
            bytes += [0x3B, code]
        }
        if modifier & 8 != 0 {
            bytes.append(0x3B)
            switch (modifier >> 12) & 0xF {
            case 2: bytes += "4:2".utf8
            case 3: bytes += "4:3".utf8
            case 4: bytes += "4:4".utf8
            case 5: bytes += "4:5".utf8
            default: bytes.append(0x34)
            }
        }
        for (bit, code) in trailingModifiers where modifier & bit != 0 {
            bytes += [0x3B, code]
        }
        bytes.append(0x3B)
        appendColor(cell.fg, foreground: true, to: &bytes)
        bytes.append(0x3B)
        appendColor(cell.bg, foreground: false, to: &bytes)
        bytes.append(0x6D)
    }

    private static func appendColor(_ color: HerdrColor, foreground: Bool, to bytes: inout [UInt8]) {
        switch color.value {
        case .default:
            bytes += (foreground ? "39" : "49").utf8
        case .named(let index):
            // Black through Gray are 30-37, DarkGray through White 90-97; backgrounds add 10.
            let code = index <= 8 ? 29 + Int(index) : 81 + Int(index)
            appendDecimal(foreground ? code : code + 10, to: &bytes)
        case .indexed(let index):
            bytes += (foreground ? "38;5;" : "48;5;").utf8
            appendDecimal(Int(index), to: &bytes)
        case .rgb(let red, let green, let blue):
            bytes += (foreground ? "38;2;" : "48;2;").utf8
            appendDecimal(Int(red), to: &bytes)
            bytes.append(0x3B)
            appendDecimal(Int(green), to: &bytes)
            bytes.append(0x3B)
            appendDecimal(Int(blue), to: &bytes)
        }
    }

    private static func appendDecimal(_ value: Int, to bytes: inout [UInt8]) {
        if value >= 10 {
            appendDecimal(value / 10, to: &bytes)
        }
        bytes.append(0x30 + UInt8(value % 10))
    }
}
