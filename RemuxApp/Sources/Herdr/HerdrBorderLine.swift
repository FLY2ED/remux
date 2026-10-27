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
    /// aren't glyphs when the glyphs on both sides reach into them: the line runs on under the label,
    /// in the label's colour, which is its pane's border colour (`render_pane_border_titles`).
    static func lines(in surface: HerdrPaneSurfaceFrame) -> [HerdrBorderLine] {
        let frame = surface.frame
        let width = Int(frame.width)
        let height = Int(frame.height)
        let textAreas = surface.panes.map(\.innerRect)
        /// A cell outside the text areas.
        func cell(_ x: Int, _ y: Int) -> Cell {
            let cell = frame.cells[y * width + x]
            return Strokes(glyph: cell.symbol).map { .line($0, cell.fg) } ?? .other(cell.fg)
        }
        // Only cells outside the text areas are read: most of a frame is text, and lines are read
        // again for every frame painted.
        var lines: [HerdrBorderLine] = []
        for y in 0..<height {
            let text = textAreas.filter { y >= Int($0.y) && y < Int($0.y) + Int($0.height) }
                .map { Int($0.x)..<(Int($0.x) + Int($0.width)) }
            appendRuns(.horizontal, track: y, along: outside(text, length: width), to: &lines) { cell($0, y) }
        }
        for x in 0..<width {
            let text = textAreas.filter { x >= Int($0.x) && x < Int($0.x) + Int($0.width) }
                .map { Int($0.y)..<(Int($0.y) + Int($0.height)) }
            appendRuns(.vertical, track: x, along: outside(text, length: height), to: &lines) { cell(x, $0) }
        }
        return lines
    }

    /// The stretches of `0..<length` outside `text`.
    private static func outside(_ text: [Range<Int>], length: Int) -> [Range<Int>] {
        var stretches: [Range<Int>] = []
        var next = 0
        for range in text.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if range.lowerBound > next { stretches.append(next..<min(range.lowerBound, length)) }
            next = max(next, range.upperBound)
        }
        if next < length { stretches.append(next..<length) }
        return stretches
    }

    private enum Cell {
        case line(Strokes, HerdrColor)
        /// Any other cell outside the text areas: a blank, a label's text, the scrollbar.
        case other(HerdrColor)
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

    /// The runs along one row or column, in its `stretches` outside the text areas, `cell(i)` being its
    /// cell at `i`. No line crosses a text area.
    private static func appendRuns(
        _ axis: Axis,
        track: Int,
        along stretches: [Range<Int>],
        to lines: inout [HerdrBorderLine],
        cell: (Int) -> Cell
    ) {
        /// The run being built; `reachesOn` while its last stroke reaches its cell's far side.
        var run: (start: UInt32, end: UInt32, color: HerdrColor, reachesOn: Bool)?
        /// The first of the cells the run reaches into that aren't glyphs, such as a label's.
        var writtenOver: Int?
        func finish() {
            if let current = run {
                lines.append(HerdrBorderLine(
                    axis: axis, track: UInt16(track), start: current.start, end: current.end, color: current.color
                ))
            }
            run = nil
            writtenOver = nil
        }
        /// A cell's stroke, in half cells: it continues the run when both reach their shared side in one
        /// colour, else it starts a run.
        func add(start: UInt32, end: UInt32, color: HerdrColor, near: Bool, far: Bool) {
            if let current = run, current.reachesOn, near, current.color == color {
                run = (current.start, end, color, far)
            } else {
                finish()
                run = (start, end, color, far)
            }
        }
        for stretch in stretches {
            finish()
            for index in stretch {
                switch cell(index) {
                case .other:
                    if run?.reachesOn == true {
                        writtenOver = writtenOver ?? index
                    } else {
                        finish()
                    }
                case .line(let strokes, let color):
                    let (near, far) = axis == .horizontal ? (strokes.left, strokes.right) : (strokes.up, strokes.down)
                    guard near || far else {
                        finish()
                        continue
                    }
                    if near, let first = writtenOver {
                        for covered in first..<index {
                            guard case .other(let coveredColor) = cell(covered) else { continue }
                            let start = UInt32(covered) * 2
                            add(start: start, end: start + 2, color: coveredColor, near: true, far: true)
                        }
                    }
                    writtenOver = nil
                    let start = UInt32(index) * 2
                    add(start: start + (near ? 0 : 1), end: start + (far ? 2 : 1), color: color, near: near, far: far)
                }
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
