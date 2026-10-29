import Foundation
import XCTest
@testable import Remux

/// Herdr's pane borders read from its frames: a real recording with Herdr's default settings, and frames
/// as Herdr's `ui/panes.rs` draws them for its other settings.
@MainActor
final class HerdrBorderLineTests: XCTestCase {
    /// Herdr's default palette: the focused pane's border in `accent`, the others' in `overlay0`
    /// (`app/state.rs` `Palette::catppuccin`).
    private static let accent = HerdrColor(raw: 0x0289_B4FA)
    private static let grey = HerdrColor(raw: 0x026C_7086)

    /// The real Herdr v0.9.3 frame of a split with the default settings, as painted: a box around each
    /// pane's rectangle, the focused pane's in the accent. The scrollbar's column beside each text area
    /// is not a line.
    func testASplitWithHerdrsDefaultsHasABoxPerPaneAsRecorded() async throws {
        let fixture = try XCTUnwrap(try HerdrWireTests.goldenFixtures().first { $0.name == "herdr-wide-cells-patch-A" })
        let negotiated = try XCTUnwrap(fixture.golden.negotiated)
        // The engine paints the panes into Ghostty terminals, which need Ghostty set up.
        let runtime = try GhosttyKitRuntime(terminalSettings: .default)
        defer { withExtendedLifetime(runtime) {} }
        let engine = HerdrTerminalEngine(cellWidthPx: 9, cellHeightPx: 18)
        let feed = await engine.beginConnection(1)
        var decoder = HerdrSurfaceDecoder(deltaNegotiated: negotiated.delta, scrollNegotiated: negotiated.scroll)
        var reference = HerdrPresentation()
        var splitter = HerdrFrameSplitter()
        splitter.append(fixture.serverStream)
        while let payload = try splitter.nextPayload() {
            let message = try HerdrServerMessage.decode(payload)
            if case .control(let kind, let data) = message,
               case .snapshot(let snapshot) = try HerdrEndpointControl.parse(kind: kind, data: data) {
                reference.receive(snapshot)
                await feed.receive(snapshot)
                continue
            }
            guard let surfaceMessage = try HerdrSurfaceDecoderTests.surfaceMessage(message) else { continue }
            let output = try decoder.decode(surfaceMessage)
            switch output {
            case .surface(let surface): try reference.receive(surface)
            case .patch(let patch): _ = reference.receive(patch)
            }
            await feed.receive(output)
        }
        await engine.stop()
        var layout: HerdrPaneLayout?
        for await update in engine.updates {
            if case .drawn(let next, _, _) = update { layout = next }
        }

        let surface = try XCTUnwrap(reference.presented?.surface)
        XCTAssertEqual(surface.panes.count, 2)
        XCTAssertEqual(surface.panes.filter(\.focused).count, 1)
        let expected = surface.panes.flatMap { Self.box($0.rect, $0.focused ? Self.accent : Self.grey) }
        XCTAssertEqual(Set(try XCTUnwrap(layout).borders.map(Self.describe)), Set(expected.map(Self.describe)))
    }

    /// The engine reads the borders again for every surface, not for patches, which only change text:
    /// after a patch, a surface for a wider left pane brings its own borders.
    func testTheLayoutTakesTheBordersOfEachSurfaceAcrossPatches() async throws {
        let runtime = try GhosttyKitRuntime(terminalSettings: .default)
        defer { withExtendedLifetime(runtime) {} }
        let engine = HerdrTerminalEngine(cellWidthPx: 9, cellHeightPx: 18)
        let feed = await engine.beginConnection(1)
        let narrow = [(x: 1, y: 1, width: 2, height: 1), (x: 5, y: 1, width: 2, height: 1)]
        let wide = [(x: 1, y: 1, width: 3, height: 1), (x: 6, y: 1, width: 2, height: 1)]
        await feed.receive(try HerdrPresentationTests.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            lines: ["┌──┐┌──┐", "│ab││cd│", "└──┘└──┘"],
            colors: ["AAAAGGGG", "A..AG..G", "AAAAGGGG"],
            textAreas: narrow
        )))
        let typed = "xy".map {
            HerdrCell(symbol: String($0), fg: HerdrColor(raw: 0), bg: HerdrColor(raw: 0), modifier: 0, skip: false, hyperlink: nil)
        }
        await feed.receive(.patch(try HerdrPresentationTests.patch(
            base: 1,
            rows: [HerdrPatchRow(x: 1, y: 1, cells: typed)],
            panes: [Self.pane(index: 0, textArea: narrow[0])]
        )))
        await feed.receive(.surface(try Self.surface(
            lines: ["┌───┐┌──┐", "│abc││cd│", "└───┘└──┘"],
            colors: ["AAAAAGGGG", "A...AG..G", "AAAAAGGGG"],
            textAreas: wide,
            revision: 3
        )))
        await engine.stop()
        var borders: [[String]] = []
        var last: HerdrPaneLayout?
        for await update in engine.updates {
            guard case .drawn(let layout, _, _) = update, layout != last else { continue }
            last = layout
            borders.append(layout.borders.map(Self.describe))
        }

        XCTAssertEqual(borders, [
            ["h0 1-7 A", "h0 9-15 G", "h2 1-7 A", "h2 9-15 G", "v0 1-5 A", "v3 1-5 A", "v4 1-5 G", "v7 1-5 G"],
            ["h0 1-9 A", "h0 11-17 G", "h2 1-9 A", "h2 11-17 G", "v0 1-5 A", "v4 1-5 A", "v5 1-5 G", "v8 1-5 G"],
        ])
    }

    /// With `pane_gaps = false`, neighbours share one line and the lines meet in T glyphs. Herdr colours
    /// a shared line with the focused pane's accent along that pane's side (`line_touches_pane`), so a
    /// line changes colour at the T, and the lines follow those colours.
    func testSharedDividersKeepHerdrsColoursAlongThem() throws {
        let surface = try Self.surface(
            lines: [
                "┌───┬───┐",
                "│aaa│bbb│",
                "│aaa├───┤",
                "│aaa│ccc│",
                "└───┴───┘",
            ],
            colors: [
                "AAAAAGGGG",
                "A...A...G",
                "A...AGGGG",
                "A...A...G",
                "AAAAAGGGG",
            ],
            textAreas: [(1, 1, 3, 3), (5, 1, 3, 1), (5, 3, 3, 1)]
        )

        XCTAssertEqual(HerdrBorderLine.lines(in: surface).map(Self.describe), [
            "h0 1-10 A", "h0 10-17 G",
            "h2 9-10 A", "h2 10-17 G",
            "h4 1-10 A", "h4 10-17 G",
            "v0 1-9 A", "v4 1-9 A", "v8 1-9 G",
        ])
    }

    /// A pane's label is written over its top border; the line runs on under it.
    func testALineRunsOnUnderAPanesLabel() throws {
        let surface = try Self.surface(
            lines: ["┌ editor ──┐", "│xxxxxxxxx │", "└──────────┘"],
            colors: ["AAAAAAAAAAAA", "A.........-A", "AAAAAAAAAAAA"],
            textAreas: [(1, 1, 9, 1)]
        )

        XCTAssertEqual(HerdrBorderLine.lines(in: surface).map(Self.describe), [
            "h0 1-23 A", "h2 1-23 A", "v0 1-5 A", "v11 1-5 A",
        ])
    }

    /// Herdr's own wide label (`ui/panes.rs` tests): `1 模块组织（已定）` in a 12-column pane is ` 1 模块… `.
    /// Ratatui leaves the cell each wide character covers in the default colour, and the line under
    /// it keeps the label's colour.
    func testALineUnderAWideLabelKeepsTheLabelsColour() throws {
        let surface = try Self.surface(
            lines: ["┌ 1 模 块 … ─┐", "│xxxxxxxxx │", "└──────────┘"],
            colors: ["AAAAA.A.AAAA", "A.........-A", "AAAAAAAAAAAA"],
            textAreas: [(1, 1, 9, 1)]
        )

        XCTAssertEqual(HerdrBorderLine.lines(in: surface).map(Self.describe), [
            "h0 1-23 A", "h2 1-23 A", "v0 1-5 A", "v11 1-5 A",
        ])
    }

    /// With `pane_gaps = false` a label can follow the T where a focused neighbour's accent line meets
    /// the labelled pane's grey border. Herdr writes the label in its pane's colour, and the line under
    /// it takes that colour too.
    func testALineUnderALabelTakesTheLabelsColour() throws {
        let surface = try Self.surface(
            lines: ["┌──┬ ab ─┐", "│xx│xxxxx│", "└──┴─────┘"],
            colors: ["AAAAGGGGGG", "A..A.....G", "AAAAGGGGGG"],
            textAreas: [(1, 1, 2, 1), (4, 1, 5, 1)]
        )

        XCTAssertEqual(HerdrBorderLine.lines(in: surface).map(Self.describe), [
            "h0 1-8 A", "h0 8-19 G", "h2 1-8 A", "h2 8-19 G",
            "v0 1-5 A", "v3 1-5 A", "v9 1-5 G",
        ])
    }

    /// A program's own box-drawing in a pane's text area is the pane's content, and neither the blank
    /// gap Herdr leaves with its borders off nor the scrollbar's glyphs are lines.
    func testOnlyGlyphsOutsideTheTextAreasAreLines() throws {
        let surface = try Self.surface(
            lines: ["┌─┐▐ ┌─┐▕", "└─┘▕ └─┘ "],
            colors: ["......-.."],
            textAreas: [(0, 0, 3, 2), (5, 0, 3, 2)]
        )

        XCTAssertEqual(HerdrBorderLine.lines(in: surface), [])
    }

    /// Herdr's border colours as the phone's terminal shows them: an RGB colour as it is, a named or
    /// indexed one from the palette, the default from the foreground.
    func testAColourIsShownAsThePhonesTerminalShowsIt() {
        let palette = (0..<256).map { GhosttyTerminalColors.Color(red: UInt8($0), green: 0, blue: 1) }
        let colors = GhosttyTerminalColors(
            foreground: .init(red: 9, green: 9, blue: 9),
            background: .init(red: 0, green: 0, blue: 0),
            palette: palette
        )
        XCTAssertEqual(HerdrColor(raw: 0x0289_B4FA).foregroundRGB(in: colors), .init(red: 0x89, green: 0xB4, blue: 0xFA))
        XCTAssertEqual(HerdrColor(raw: 0x0289_B4FA).foregroundRGB(in: nil), .init(red: 0x89, green: 0xB4, blue: 0xFA))
        // Named Blue (5) is palette 4, named Gray (8) palette 7, named White (16) palette 15.
        XCTAssertEqual(HerdrColor(raw: 5).foregroundRGB(in: colors), palette[4])
        XCTAssertEqual(HerdrColor(raw: 8).foregroundRGB(in: colors), palette[7])
        XCTAssertEqual(HerdrColor(raw: 16).foregroundRGB(in: colors), palette[15])
        XCTAssertEqual(HerdrColor(raw: 0x0100_00F0).foregroundRGB(in: colors), palette[240])
        XCTAssertEqual(HerdrColor(raw: 0).foregroundRGB(in: colors), colors.foreground)
        XCTAssertNil(HerdrColor(raw: 5).foregroundRGB(in: nil))
    }

    // MARK: - Fixtures

    /// The four lines of a box drawn around `rect`, through the middle of its edge cells, in half cells.
    private static func box(_ rect: HerdrSurfaceRect, _ color: HerdrColor) -> [HerdrBorderLine] {
        let right = UInt32(rect.x) + UInt32(rect.width) - 1
        let bottom = UInt32(rect.y) + UInt32(rect.height) - 1
        let across = (start: UInt32(rect.x) * 2 + 1, end: right * 2 + 1)
        let down = (start: UInt32(rect.y) * 2 + 1, end: bottom * 2 + 1)
        return [
            HerdrBorderLine(axis: .horizontal, track: rect.y, start: across.start, end: across.end, color: color),
            HerdrBorderLine(axis: .horizontal, track: UInt16(bottom), start: across.start, end: across.end, color: color),
            HerdrBorderLine(axis: .vertical, track: rect.x, start: down.start, end: down.end, color: color),
            HerdrBorderLine(axis: .vertical, track: UInt16(right), start: down.start, end: down.end, color: color),
        ]
    }

    private static func describe(_ line: HerdrBorderLine) -> String {
        let color = switch line.color {
        case accent: "A"
        case grey: "G"
        default: String(line.color.raw, radix: 16)
        }
        return "\(line.axis == .horizontal ? "h" : "v")\(line.track) \(line.start)-\(line.end) \(color)"
    }

    /// A surface whose cells are `lines`, coloured by `colors` (`A` accent, `G` grey, anything else
    /// the default; a row without colours is all default), with one pane per text area.
    private static func surface(
        lines: [String],
        colors: [String],
        textAreas: [(x: Int, y: Int, width: Int, height: Int)],
        revision: UInt64 = 1
    ) throws -> HerdrPaneSurfaceFrame {
        let width = lines[0].count
        precondition(lines.allSatisfy { $0.count == width })
        let cells = lines.enumerated().flatMap { y, line in
            let rowColors = y < colors.count ? Array(colors[y]) : []
            return line.enumerated().map { x, symbol in
                let fg: UInt32 = switch x < rowColors.count ? rowColors[x] : "." {
                case "A": accent.raw
                case "G": grey.raw
                default: 0
                }
                return #"{"symbol":"\#(symbol)","fg":\#(fg),"bg":0,"modifier":0,"skip":false,"hyperlink":null}"#
            }
        }
        let panes = textAreas.enumerated().map { pane(index: $0, textArea: $1) }
        let json = """
        {"boot_id":"boot","projection_revision":1,"surface_revision":\(revision),
         "frame":{"cells":[\(cells.joined(separator: ","))],"width":\(width),"height":\(lines.count),"cursor":null,"hyperlinks":[],"graphics":[]},
         "panes":[\(panes.joined(separator: ","))],"splits":[],"popup":null,
         "graphics":{"assets":[],"placements":[],"retained_assets":[]}}
        """
        return try JSONDecoder().decode(HerdrPaneSurfaceFrame.self, from: Data(json.utf8))
    }

    /// Pane `p<index>`, its rectangle its text area.
    private static func pane(index: Int, textArea area: (x: Int, y: Int, width: Int, height: Int)) -> String {
        let rect = #"{"x":\#(area.x),"y":\#(area.y),"width":\#(area.width),"height":\#(area.height)}"#
        return """
        {"pane_id":"p\(index)","content_revision":1,"rect":\(rect),"inner_rect":\(rect),"scrollbar_rect":null,
         "scroll":null,"focused":false,"mouse_reporting":false,"sgr_pixel_mouse":false,
         "alternate_screen_active":false,"pixel_width":0,"pixel_height":0}
        """
    }
}
