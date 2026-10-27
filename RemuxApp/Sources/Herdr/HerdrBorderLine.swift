import Foundation

/// One straight run of the lines Herdr draws around and between a tab's panes, in one colour, as the
/// box-drawing glyphs in Herdr's frame show it. Herdr's client shows the frame's cells as they are
/// (`client/shell/composition.rs`); Remux crops each pane's text area into the pane's own terminal and
/// draws these lines itself.
///
/// They are read from the glyphs because the pane geometry doesn't say where Herdr's borders are: the
/// cells between a pane's rectangle and its text area can be a border or the scrollbar's column, and
/// which borders a pane has depends on Herdr's `pane_borders`, `pane_gaps` and `pane_outer_borders`
/// settings, which no message carries (`ui/panes.rs` `apply_pane_chrome`). The focused pane's lines
/// are Herdr's accent colour, which Herdr picks with its own rule (`line_touches_pane`).
struct HerdrBorderLine: Equatable, Sendable {
    enum Axis: Equatable, Sendable {
        case horizontal
        case vertical
    }

    let axis: Axis
    /// The row of a horizontal line, or the column of a vertical one. The line runs through the
    /// middle of its cells.
    let track: UInt16
    /// Where the line starts and ends along its axis, in half cells: each glyph's stroke runs from an
    /// edge or the middle of its cell to the other edge or the middle.
    let start: UInt32
    let end: UInt32
    let color: HerdrColor
}

extension HerdrBorderLine {
    /// The lines in the surface's frame, outside every pane's text area: each row's horizontal lines,
    /// then each column's vertical ones.
    ///
    /// A pane's label is written over its top border, so a line also continues across cells that
    /// aren't glyphs when the glyphs on both sides reach into them in one colour: the line runs on under
    /// the label.
    static func lines(in surface: HerdrPaneSurfaceFrame) -> [HerdrBorderLine] {
        let frame = surface.frame
        let width = Int(frame.width)
        let height = Int(frame.height)
        let textAreas = surface.panes.map(\.innerRect)
        func cell(_ x: Int, _ y: Int) -> Cell {
            guard !textAreas.contains(where: { $0.contains(x: x, y: y) }) else { return .text }
            let cell = frame.cells[y * width + x]
            return Strokes(glyph: cell.symbol).map { .line($0, cell.fg) } ?? .other
        }
        var lines: [HerdrBorderLine] = []
        for y in 0..<height {
            appendRuns(.horizontal, track: y, length: width, to: &lines) { cell($0, y) }
        }
        for x in 0..<width {
            appendRuns(.vertical, track: x, length: height, to: &lines) { cell(x, $0) }
        }
        return lines
    }

    private enum Cell {
        /// Inside a pane's text area.
        case text
        case line(Strokes, HerdrColor)
        /// Any other cell outside the text areas: a blank, a label's text, the scrollbar.
        case other
    }

    /// The sides of its cell a glyph's strokes reach from the cell's middle; a straight glyph reaches
    /// both sides.
    private struct Strokes {
        var left = false
        var right = false
        var up = false
        var down = false

        /// Herdr's border glyphs (`ui/panes.rs` `line_cell_symbol`).
        init?(glyph: String) {
            let scalars = glyph.unicodeScalars
            guard scalars.count == 1, let scalar = scalars.first else { return nil }
            switch scalar {
            case "─": (left, right) = (true, true)
            case "│": (up, down) = (true, true)
            case "┌": (right, down) = (true, true)
            case "┐": (left, down) = (true, true)
            case "└": (up, right) = (true, true)
            case "┘": (up, left) = (true, true)
            case "├": (up, down, right) = (true, true, true)
            case "┤": (up, down, left) = (true, true, true)
            case "┬": (left, right, down) = (true, true, true)
            case "┴": (left, right, up) = (true, true, true)
            case "┼": (left, right, up, down) = (true, true, true, true)
            default: return nil
            }
        }
    }

    /// The runs along one row or column, `cell(i)` being its cell at `i`.
    private static func appendRuns(
        _ axis: Axis,
        track: Int,
        length: Int,
        to lines: inout [HerdrBorderLine],
        cell: (Int) -> Cell
    ) {
        /// The run being built; `reachesOn` while its last glyph's stroke reaches its cell's far side.
        var run: (start: UInt32, end: UInt32, color: HerdrColor, reachesOn: Bool)?
        func finish() {
            if let current = run {
                lines.append(HerdrBorderLine(
                    axis: axis, track: UInt16(track), start: current.start, end: current.end, color: current.color
                ))
            }
            run = nil
        }
        for index in 0..<length {
            let near: Bool
            let far: Bool
            let color: HerdrColor
            switch cell(index) {
            case .text:
                finish()
                continue
            case .other:
                if run?.reachesOn != true { finish() }
                continue
            case .line(let strokes, let lineColor):
                (near, far) = axis == .horizontal ? (strokes.left, strokes.right) : (strokes.up, strokes.down)
                color = lineColor
            }
            guard near || far else {
                finish()
                continue
            }
            let start = UInt32(index) * 2 + (near ? 0 : 1)
            let end = UInt32(index) * 2 + (far ? 2 : 1)
            if let current = run, current.reachesOn, near, current.color == color {
                run = (current.start, end, color, far)
            } else {
                finish()
                run = (start, end, color, far)
            }
        }
        finish()
    }
}

extension HerdrColor {
    /// The colour as a terminal with these colours shows it in the foreground, as Herdr's client's
    /// terminal shows Herdr's cells. Only an RGB colour is known without them.
    func foregroundRGB(in colors: GhosttyTerminalColors?) -> GhosttyTerminalColors.Color? {
        func palette(_ index: Int) -> GhosttyTerminalColors.Color? {
            guard let colors, colors.palette.indices.contains(index) else { return nil }
            return colors.palette[index]
        }
        switch value {
        case .default:
            return colors?.foreground
        case .named(let name):
            // Black through White are the palette's first 16 entries.
            return palette(Int(name) - 1)
        case .indexed(let index):
            return palette(Int(index))
        case .rgb(let red, let green, let blue):
            return GhosttyTerminalColors.Color(red: red, green: green, blue: blue)
        }
    }
}

private extension HerdrSurfaceRect {
    func contains(x: Int, y: Int) -> Bool {
        x >= Int(self.x) && x < Int(self.x) + Int(width) && y >= Int(self.y) && y < Int(self.y) + Int(height)
    }
}
