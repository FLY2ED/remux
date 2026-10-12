import CryptoKit
import Foundation
import XCTest
@testable import Remux

final class HerdrPanePainterTests: XCTestCase {
    // MARK: - Recorded streams

    /// Every pane of every recorded surface, and the rows each applied patch changed, paint to the bytes
    /// of the reference painter (`Fixtures/HerdrWire`, `painted`). On 9 October that painter's output,
    /// written into a real Ghostty, reproduced Herdr's grid as Herdr's own encoder does (remux-docs
    /// `evidence/herdr-stage4-traces-20261009/frames/`, Question 2).
    func testPaintsEveryRecordedPaneAsTheReferencePainter() throws {
        var surfacePanes = 0
        var patchPanes = 0
        for fixture in try HerdrWireTests.goldenFixtures() {
            guard let negotiated = fixture.golden.negotiated else { continue }
            var decoder = HerdrSurfaceDecoder(deltaNegotiated: negotiated.delta, scrollNegotiated: negotiated.scroll)
            var presentation = HerdrPresentation()
            var splitter = HerdrFrameSplitter()
            splitter.append(fixture.serverStream)
            for entry in fixture.golden.server {
                let context = "\(fixture.name) @\(entry.offset)"
                let message = try HerdrServerMessage.decode(try XCTUnwrap(try splitter.nextPayload(), context))
                if case .control(let kind, let data) = message,
                   case .snapshot(let snapshot) = try HerdrEndpointControl.parse(kind: kind, data: data) {
                    presentation.receive(snapshot)
                }
                guard let surfaceMessage = try HerdrSurfaceDecoderTests.surfaceMessage(message) else { continue }
                switch try decoder.decode(surfaceMessage) {
                case .surface(let surface):
                    try presentation.receive(surface)
                    let expected = try XCTUnwrap(entry.painted, context)
                    XCTAssertEqual(Set(expected.keys), Set(surface.panes.map(\.paneID)), context)
                    for pane in surface.panes {
                        let area = pane.innerRect
                        let bytes = HerdrPanePainter.rows(0..<Int(area.height), of: surface.frame, area: area)
                        XCTAssertNil(expected[pane.paneID]?.rows, context)
                        XCTAssertEqual(Self.digest(bytes), expected[pane.paneID]?.digest, "\(context) \(pane.paneID)")
                        surfacePanes += 1
                    }
                case .patch(let patch):
                    guard presentation.receive(patch) == .applied else {
                        XCTAssertNil(entry.painted, context)
                        continue
                    }
                    let current = try XCTUnwrap(presentation.surface, context)
                    let expected = try XCTUnwrap(entry.painted, context)
                    var painted = Set<String>()
                    for listed in patch.panes {
                        let pane = try XCTUnwrap(current.panes.first { $0.paneID == listed.paneID }, context)
                        let rows = HerdrPanePainter.changedRows(patch, area: pane.innerRect)
                        guard !rows.isEmpty else { continue }
                        let bytes = HerdrPanePainter.rows(rows, of: current.frame, area: pane.innerRect)
                        XCTAssertEqual(rows, expected[pane.paneID]?.rows, "\(context) \(pane.paneID)")
                        XCTAssertEqual(Self.digest(bytes), expected[pane.paneID]?.digest, "\(context) \(pane.paneID)")
                        painted.insert(pane.paneID)
                        patchPanes += 1
                    }
                    XCTAssertEqual(painted, Set(expected.keys), context)
                }
            }
        }
        XCTAssertEqual(surfacePanes, 60)
        XCTAssertEqual(patchPanes, 55)
    }

    // MARK: - Cells

    func testRowsArePaintedRightToLeftWithEachCellAtItsColumn() {
        let frame = Self.frame(width: 5, rows: [["a", "漢", "", "b", "c"]])
        let area = HerdrSurfaceRect(x: 1, y: 0, width: 3, height: 1)

        XCTAssertEqual(
            Self.text(HerdrPanePainter.rows([0], of: frame, area: area)),
            "\u{1B}[1;3H\u{1B}[0;39;49mb\u{1B}[1;1H\u{1B}[0;39;49m漢\u{1B}[0m"
        )
    }

    /// Herdr's own expectations (`render_ansi.rs:1162-1164, 1187-1197`) and the rest of its mapping
    /// (`render_ansi.rs:341-477`).
    func testCellStylesUseHerdrsSGR() {
        func sgr(fg: UInt32, bg: UInt32, modifier: UInt16) -> String {
            let cell = HerdrCell(symbol: "x", fg: HerdrColor(raw: fg), bg: HerdrColor(raw: bg), modifier: modifier, skip: false, hyperlink: nil)
            let frame = HerdrFrame(cells: [cell], width: 1, height: 1, cursor: nil, hyperlinks: [], graphics: [])
            let text = Self.text(HerdrPanePainter.rows([0], of: frame, area: HerdrSurfaceRect(x: 0, y: 0, width: 1, height: 1)))
            return String(text.dropFirst("\u{1B}[1;1H".count).dropLast("x\u{1B}[0m".count))
        }

        XCTAssertEqual(sgr(fg: 0, bg: 0, modifier: 0), "\u{1B}[0;39;49m")
        XCTAssertEqual(sgr(fg: 0, bg: 0, modifier: 8 | 3 << 12), "\u{1B}[0;4:3;39;49m")
        XCTAssertEqual(sgr(fg: 2, bg: 1, modifier: 1), "\u{1B}[0;1;31;40m")
        XCTAssertEqual(sgr(fg: 9, bg: 16, modifier: 2 | 4 | 8), "\u{1B}[0;2;3;4;90;107m")
        XCTAssertEqual(sgr(fg: 0x0100_00C4, bg: 0x0200_0102, modifier: 16 | 32 | 64 | 128 | 256), "\u{1B}[0;5;6;7;8;9;38;5;196;48;2;0;1;2m")
        XCTAssertEqual(sgr(fg: 0xFF00_0000, bg: 17, modifier: 8 | 7 << 12), "\u{1B}[0;4;39;49m")
    }

    func testLinksAreWrappedPerCellWithoutControlCharacters() {
        var frame = Self.frame(width: 3, rows: [["a", "b", "c"]], hyperlinks: ["https://e.com/\u{1B}x\u{07}y\u{85}", "\u{1B}\u{07}"])
        frame.cells[0] = Self.cell("a", hyperlink: 0)
        frame.cells[1] = Self.cell("b", hyperlink: 1)
        frame.cells[2] = Self.cell("c", hyperlink: 7)

        XCTAssertEqual(
            Self.text(HerdrPanePainter.rows([0], of: frame, area: HerdrSurfaceRect(x: 0, y: 0, width: 3, height: 1))),
            "\u{1B}[1;3H\u{1B}[0;39;49mc"
                + "\u{1B}[1;2H\u{1B}[0;39;49mb"
                + "\u{1B}[1;1H\u{1B}[0;39;49m\u{1B}]8;;https://e.com/xy\u{1B}\\a\u{1B}]8;;\u{1B}\\"
                + "\u{1B}[0m"
        )
    }

    /// Herdr's client never writes a cell marked skip (`render_ansi.rs:871, 962`).
    func testSkippedCellsAreNotWritten() {
        var frame = Self.frame(width: 2, rows: [["a", "b"]])
        frame.cells[1] = HerdrCell(symbol: "b", fg: HerdrColor(raw: 0), bg: HerdrColor(raw: 0), modifier: 0, skip: true, hyperlink: nil)

        XCTAssertEqual(
            Self.text(HerdrPanePainter.rows([0], of: frame, area: HerdrSurfaceRect(x: 0, y: 0, width: 2, height: 1))),
            "\u{1B}[1;1H\u{1B}[0;39;49ma\u{1B}[0m"
        )
    }

    // MARK: - Cursor

    func testTheCursorIsShownOnlyInTheAreaThatHoldsIt() {
        let cursor = HerdrCursor(x: 5, y: 2, visible: true, shape: 6)
        let holding = HerdrSurfaceRect(x: 4, y: 1, width: 3, height: 2)
        let beside = HerdrSurfaceRect(x: 0, y: 1, width: 4, height: 2)

        XCTAssertEqual(HerdrPanePainter.cursor(cursor, in: holding), HerdrCursor(x: 1, y: 1, visible: true, shape: 6))
        XCTAssertNil(HerdrPanePainter.cursor(cursor, in: beside))
        XCTAssertNil(HerdrPanePainter.cursor(HerdrCursor(x: 5, y: 2, visible: false, shape: 6), in: holding))
        XCTAssertNil(HerdrPanePainter.cursor(nil, in: holding))
        // Placed, shaped, then shown, as Herdr's client writes it (`render_ansi.rs:1469, 1532`).
        XCTAssertEqual(Self.text(HerdrPanePainter.cursorBytes(HerdrCursor(x: 2, y: 1, visible: true, shape: 6))), "\u{1B}[2;3H\u{1B}[6 q\u{1B}[?25h")
        XCTAssertEqual(Self.text(HerdrPanePainter.cursorBytes(nil)), "\u{1B}[?25l")
    }

    // MARK: - Repaint and update

    func testARepaintSetsTheModesPaintsEveryRowAndEndsWithTheCursor() {
        var frame = Self.frame(width: 4, rows: [["a", "b", "c", "d"], ["e", "f", "g", "h"]])
        frame.cursor = HerdrCursor(x: 2, y: 1, visible: true, shape: 2)
        let area = HerdrSurfaceRect(x: 2, y: 0, width: 2, height: 2)

        XCTAssertEqual(
            Self.text(HerdrPanePainter.repaint(frame, area: area)),
            "\u{1B}[?2027h\u{1B}[?7l"
                + Self.text(HerdrPanePainter.rows([0, 1], of: frame, area: area))
                + "\u{1B}[2;1H\u{1B}[2 q\u{1B}[?25h"
        )
    }

    func testAnUpdatePaintsTheChangedRowsAndOnlyCursorChangesElsewhere() throws {
        var frame = Self.frame(width: 5, rows: [["a", "b", "|", "c", "d"], ["e", "f", "|", "g", "h"]])
        let left = HerdrSurfaceRect(x: 0, y: 0, width: 2, height: 2)
        let right = HerdrSurfaceRect(x: 3, y: 0, width: 2, height: 2)
        let previous = HerdrCursor(x: 1, y: 0, visible: true, shape: 0)
        frame.cursor = previous
        let patch = try Self.patch(rows: [HerdrPatchRow(x: 0, y: 1, cells: [Self.cell("x")])], cursor: previous)

        XCTAssertEqual(HerdrPanePainter.changedRows(patch, area: left), [1])
        XCTAssertEqual(HerdrPanePainter.changedRows(patch, area: right), [])
        XCTAssertEqual(
            HerdrPanePainter.update(after: patch, previousCursor: previous, frame: frame, area: left),
            HerdrPanePainter.rows([1], of: frame, area: left) + HerdrPanePainter.cursorBytes(HerdrCursor(x: 1, y: 0, visible: true, shape: 0))
        )
        XCTAssertEqual(HerdrPanePainter.update(after: patch, previousCursor: previous, frame: frame, area: right), [])

        // The cursor moves to the right area with no change to its rows: the left area hides its cursor,
        // the right one shows it.
        frame.cursor = HerdrCursor(x: 4, y: 1, visible: true, shape: 0)
        let moved = try Self.patch(rows: [], cursor: frame.cursor)
        XCTAssertEqual(Self.text(HerdrPanePainter.update(after: moved, previousCursor: previous, frame: frame, area: left)), "\u{1B}[?25l")
        XCTAssertEqual(Self.text(HerdrPanePainter.update(after: moved, previousCursor: previous, frame: frame, area: right)), "\u{1B}[2;2H\u{1B}[0 q\u{1B}[?25h")
    }

    func testASpanBesideTheAreaChangesNoRow() throws {
        let area = HerdrSurfaceRect(x: 2, y: 1, width: 2, height: 2)
        let rows = [
            HerdrPatchRow(x: 0, y: 1, cells: [Self.cell("a"), Self.cell("b")]),
            HerdrPatchRow(x: 4, y: 2, cells: [Self.cell("c")]),
            HerdrPatchRow(x: 2, y: 0, cells: [Self.cell("d")]),
            HerdrPatchRow(x: 2, y: 3, cells: [Self.cell("e")]),
        ]
        XCTAssertEqual(HerdrPanePainter.changedRows(try Self.patch(rows: rows, cursor: nil), area: area), [])
        let touching = [HerdrPatchRow(x: 1, y: 2, cells: [Self.cell("a"), Self.cell("b")]), HerdrPatchRow(x: 3, y: 1, cells: [Self.cell("c")])]
        XCTAssertEqual(HerdrPanePainter.changedRows(try Self.patch(rows: touching, cursor: nil), area: area), [0, 1])
    }
}

// MARK: - Helpers

extension HerdrPanePainterTests {
    static func digest(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    static func cell(_ symbol: String, hyperlink: UInt32? = nil) -> HerdrCell {
        HerdrCell(symbol: symbol, fg: HerdrColor(raw: 0), bg: HerdrColor(raw: 0), modifier: 0, skip: false, hyperlink: hyperlink)
    }

    static func frame(width: UInt16, rows: [[String]], hyperlinks: [String] = []) -> HerdrFrame {
        HerdrFrame(
            cells: rows.flatMap { $0.map { cell($0) } },
            width: width,
            height: UInt16(rows.count),
            cursor: nil,
            hyperlinks: hyperlinks,
            graphics: []
        )
    }

    static func patch(rows: [HerdrPatchRow], cursor: HerdrCursor?) throws -> HerdrPaneSurfacePatch {
        let cursorJSON = cursor.map { #"{"x":\#($0.x),"y":\#($0.y),"visible":\#($0.visible),"shape":\#($0.shape)}"# } ?? "null"
        let json = """
        {"boot_id":"boot","projection_revision":1,"base_surface_revision":1,
         "surface_revision":2,"rows":[],"panes":[],"cursor":\(cursorJSON)}
        """
        var patch = try JSONDecoder().decode(HerdrPaneSurfacePatch.self, from: Data(json.utf8))
        patch.rows = rows
        return patch
    }
}
