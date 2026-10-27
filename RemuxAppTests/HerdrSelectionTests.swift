import GhosttyKit
import UIKit
import XCTest
@testable import Remux

/// Selection on a Herdr pane: the screen's selection kept in Herdr's history rows as Herdr's viewport
/// moves, and its text read by Herdr (`pane.selection.read`), over a scripted bridge with real renderers.
@MainActor
final class HerdrSelectionTests: XCTestCase {
    private var harnesses: [HerdrModelHarness] = []
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows {
            window.isHidden = true
        }
        windows.removeAll()
        for harness in harnesses {
            await harness.model.stop()
        }
        harnesses.removeAll()
    }

    // MARK: - Where a history selection shows

    /// On screen, each endpoint shows at its own cell; the row counts from the viewport's top.
    func testASelectionOnScreenShowsAtItsCells() {
        let selection = GhosttyHistorySelection(start: cell(41, 2), end: cell(42, 5))
        let shown = selection.shown(top: 40, rows: 3, columns: 10)
        XCTAssertEqual(shown?.start, .init(cell: cell(1, 2), isOnScreen: true))
        XCTAssertEqual(shown?.end, .init(cell: cell(2, 5), isOnScreen: true))
    }

    /// The part on screen is highlighted from the viewport's first cell, or to its last, and the endpoint
    /// off screen has no handle; Ghostty's roles stay, so a backwards selection clamps the same way.
    func testAnEndpointOffScreenShowsAtTheViewportsEdge() {
        let above = GhosttyHistorySelection(start: cell(38, 4), end: cell(41, 1))
        XCTAssertEqual(above.shown(top: 40, rows: 3, columns: 10)?.start, .init(cell: cell(0, 0), isOnScreen: false))
        XCTAssertEqual(above.shown(top: 40, rows: 3, columns: 10)?.end, .init(cell: cell(1, 1), isOnScreen: true))

        let below = GhosttyHistorySelection(start: cell(45, 0), end: cell(41, 7))
        XCTAssertEqual(below.shown(top: 40, rows: 3, columns: 10)?.start, .init(cell: cell(2, 9), isOnScreen: false))
        XCTAssertEqual(below.shown(top: 40, rows: 3, columns: 10)?.end, .init(cell: cell(1, 7), isOnScreen: true))

        let across = GhosttyHistorySelection(start: cell(10, 3), end: cell(90, 3))
        XCTAssertEqual(across.shown(top: 40, rows: 3, columns: 10)?.start, .init(cell: cell(0, 0), isOnScreen: false))
        XCTAssertEqual(across.shown(top: 40, rows: 3, columns: 10)?.end, .init(cell: cell(2, 9), isOnScreen: false))
    }

    /// None of it on screen, it doesn't show at all; a column past a narrower viewport's last shows there.
    func testASelectionOffScreenDoesntShow() {
        XCTAssertNil(GhosttyHistorySelection(start: cell(30, 0), end: cell(39, 9)).shown(top: 40, rows: 3, columns: 10))
        XCTAssertNil(GhosttyHistorySelection(start: cell(43, 0), end: cell(50, 9)).shown(top: 40, rows: 3, columns: 10))
        XCTAssertEqual(
            GhosttyHistorySelection(start: cell(40, 30), end: cell(40, 31)).shown(top: 40, rows: 3, columns: 10)?.end,
            .init(cell: cell(0, 9), isOnScreen: true)
        )
    }

    /// Herdr's client sends a selection in reading order, rows from the top of the history.
    func testTheReadSendsTheSelectionInReadingOrder() throws {
        let read = HerdrSelectionRead(
            paneID: "w1:p1",
            selection: GhosttyHistorySelection(start: cell(41, 4), end: cell(39, 0))
        )
        XCTAssertEqual(
            try JSONDecoder().decode(SentRead.self, from: JSONEncoder().encode(read)),
            SentRead(paneID: "w1:p1", anchor: .init(row: 39, col: 0), cursor: .init(row: 41, col: 4))
        )
        XCTAssertEqual(
            try HerdrSelectionRead.text(fromReply: Data(#"{"id":"c1","result":{"type":"pane_selection","pane_id":"w1:p1","text":"a\nb"}}"#.utf8)),
            "a\nb"
        )
    }

    // MARK: - On a shown session

    /// A word selected on screen is kept in Herdr's history rows, and Copy reads it from Herdr: its text
    /// is Herdr's, whatever the painted rows hold.
    func testCopyReadsTheSelectionFromHerdrByHistoryRows() async throws {
        var session = try await shownSession(scroll: (0, 40, 3))
        let surface = try session.surface()

        let selected = surface.selectWord(at: session.point(row: 1, column: 1))
        XCTAssertTrue(isActive(selected))
        XCTAssertEqual(surface.historySelection, GhosttyHistorySelection(start: cell(41, 0), end: cell(41, 4)))

        let copy = Task { await session.adapter.selectedText(in: session.surfaceID) }
        let request = try await session.nextSelectionRead()
        XCTAssertEqual(
            request.params,
            SentRead(paneID: "w1:p1", anchor: .init(row: 41, col: 0), cursor: .init(row: 41, col: 4))
        )
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: request.id,
            json: #"{"type":"pane_selection","pane_id":"w1:p1","text":"gamma wrapped on"}"#
        ))
        let copied = await copy.value
        XCTAssertEqual(copied, "gamma wrapped on")
    }

    /// Herdr scrolling its history moves the highlight with the selection's lines; once none of it is on
    /// screen the selection ends, since the terminal holds only the rows on screen.
    func testTheHighlightFollowsHerdrsViewport() async throws {
        let session = try await shownSession(scroll: (0, 40, 3))
        let surface = try session.surface()
        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))

        try await session.serveScroll(fromBottom: 1, revision: 3)
        XCTAssertEqual(try session.shownCells(), [cell(2, 0), cell(2, 4)], "the highlight didn't move down a row")
        XCTAssertEqual(surface.historySelection, GhosttyHistorySelection(start: cell(41, 0), end: cell(41, 4)))

        try await session.serveScroll(fromBottom: 2, revision: 4)
        XCTAssertFalse(isActive(surface.selectionSnapshot()), "a selection off screen stayed")
        XCTAssertNil(surface.historySelection)
    }

    /// Scrolled into history, an endpoint moved there reaches rows the first frame never showed; scrolled
    /// back, that endpoint is off screen without a handle, and Copy still reads from it.
    func testASelectionReachesHistoryBeyondTheFrame() async throws {
        var session = try await shownSession(scroll: (0, 40, 3))
        let surface = try session.surface()
        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))

        try await session.serveScroll(fromBottom: 2, revision: 3)
        XCTAssertNil(surface.historySelection, "a selection two rows down a three-row viewport should be off screen")

        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 2, column: 1))))
        XCTAssertEqual(surface.historySelection, GhosttyHistorySelection(start: cell(40, 0), end: cell(40, 4)))
        let moved = surface.setSelectionEndpoint(
            GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_START,
            at: session.point(row: 0, column: 0)
        )
        XCTAssertTrue(isActive(moved))
        XCTAssertEqual(surface.historySelection, GhosttyHistorySelection(start: cell(38, 0), end: cell(40, 4)))

        try await session.serveScroll(fromBottom: 0, revision: 4)
        guard case .snapshot(let snapshot) = surface.selectionSnapshot() else { return XCTFail("no snapshot") }
        XCTAssertTrue(snapshot.isActive)
        XCTAssertNil(snapshot.start, "the endpoint scrolled off screen kept its handle")
        XCTAssertNotNil(snapshot.end)
        XCTAssertEqual(try session.localCells(), [cell(0, 0), cell(0, 4)], "the highlight didn't cover the rows on screen")

        let copy = Task { await session.adapter.selectedText(in: session.surfaceID) }
        let request = try await session.nextSelectionRead()
        XCTAssertEqual(
            request.params,
            SentRead(paneID: "w1:p1", anchor: .init(row: 38, col: 0), cursor: .init(row: 40, col: 4))
        )
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: request.id,
            json: #"{"type":"pane_selection","pane_id":"w1:p1","text":"history"}"#
        ))
        let copied = await copy.value
        XCTAssertEqual(copied, "history")
    }

    /// A read Herdr refuses copies nothing and says so, as Herdr's client does; content that changed
    /// meanwhile says nothing.
    func testARefusedReadSaysCopyFailed() async throws {
        var session = try await shownSession(scroll: (0, 40, 3))
        let surface = try session.surface()
        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))

        let stale = Task { await session.adapter.selectedText(in: session.surfaceID) }
        let first = try await session.nextSelectionRead()
        await session.bridge.serve(HerdrConnectionTests.reply(id: first.id, error: ("stale_content", "pane content changed")))
        let staleCopy = await stale.value
        XCTAssertNil(staleCopy)
        XCTAssertNil(session.adapter.commandFailureEvent)

        let refused = Task { await session.adapter.selectedText(in: session.surfaceID) }
        let second = try await session.nextSelectionRead()
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: second.id,
            error: ("selection_unavailable", "selection text is unavailable")
        ))
        let refusedCopy = await refused.value
        XCTAssertNil(refusedCopy)
        XCTAssertEqual(session.adapter.commandFailureEvent?.message, "Herdr: copy failed")
    }

    /// Typing ends the pane's selection, as on a tmux pane; a key's release, which Herdr doesn't get,
    /// doesn't.
    func testTypingEndsTheSelection() async throws {
        let session = try await shownSession(scroll: (0, 40, 3))
        let surface = try session.surface()
        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))

        let release = GhosttySurfaceKeyEvent(action: .release, keyCode: .arrowUp)
        XCTAssertEqual(session.adapter.sendKeyEventToFocusedSurface(release), .accepted)
        XCTAssertTrue(isActive(surface.selectionSnapshot()))

        XCTAssertEqual(session.adapter.sendInputToFocusedSurface("x"), .accepted)
        XCTAssertFalse(isActive(surface.selectionSnapshot()))
        XCTAssertNil(surface.historySelection)

        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))
        XCTAssertEqual(session.adapter.sendKeyEventToFocusedSurface(GhosttySurfaceKeyEvent(keyCode: .arrowUp)), .accepted)
        XCTAssertFalse(isActive(surface.selectionSnapshot()))
    }

    // MARK: - Support

    private func cell(_ row: UInt64, _ column: UInt16) -> GhosttyTerminalCell {
        GhosttyTerminalCell(row: row, column: column)
    }

    /// What a `pane.selection.read` asks for.
    private struct SentRead: Decodable, Equatable {
        struct Point: Decodable, Equatable {
            let row: Int
            let col: Int
        }

        let paneID: String
        let anchor: Point
        let cursor: Point

        private enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case anchor, cursor
        }
    }

    private func isActive(_ outcome: GhosttyLocalSelectionOutcome) -> Bool {
        if case .snapshot(let snapshot) = outcome { snapshot.isActive } else { false }
    }

    @MainActor
    private struct Session {
        let harness: HerdrModelHarness
        let bridge: FakeBridgeTransport
        let surfaceID: UUID
        var adapter: HerdrTerminalScreenAdapter { harness.model.terminalScreenAdapter }
        let lines: [String]
        var next: Int

        func surface() throws -> GhosttyManagedSurface {
            try XCTUnwrap(adapter.terminalManagedSurfaceLookup.managedSurface(for: surfaceID))
        }

        /// The middle of a cell of the pane, in its points.
        func point(row: Int, column: Int) -> CGPoint {
            let metrics = harness.model.measurement!.cellMetrics
            return CGPoint(
                x: (CGFloat(column) + 0.5) * metrics.pointWidth,
                y: (CGFloat(row) + 0.5) * metrics.pointHeight
            )
        }

        /// The viewport cells the terminal's selection covers, whether its handles show or not.
        func localCells() throws -> [GhosttyTerminalCell] {
            let control = try surface().controlSurface
            guard case .snapshot(let snapshot) = control.selectionSnapshot(), snapshot.isActive else { return [] }
            return [snapshot.start, snapshot.end].compactMap { $0.flatMap(control.viewportCell(of:)) }
        }

        /// The viewport cells of the endpoints the screen shows.
        func shownCells() throws -> [GhosttyTerminalCell] {
            let surface = try surface()
            guard case .snapshot(let snapshot) = surface.selectionSnapshot(), snapshot.isActive else { return [] }
            return [snapshot.start, snapshot.end].compactMap { $0.flatMap(surface.controlSurface.viewportCell(of:)) }
        }

        /// The same lines with Herdr's viewport `fromBottom` lines up a history of 40, once the pane has it.
        func serveScroll(fromBottom: UInt64, revision: UInt64) async throws {
            await bridge.serve(try harness.shownSurface(
                projection: 1,
                revision: revision,
                lines: lines,
                panes: [Self.pane(scroll: (fromBottom, 40, 3))]
            ))
            let surface = try surface()
            try await harness.waitUntil("Herdr's viewport didn't reach the pane") {
                surface.scrollState.offset == 40 - fromBottom
            }
        }

        /// The next `pane.selection.read`: its id and what it asks for.
        mutating func nextSelectionRead() async throws -> (id: String, params: SentRead) {
            struct Request: Decodable {
                let id: String
                let method: String
                let params: SentRead?
            }
            while true {
                let frame = try await bridge.written(next)
                next += 1
                var reader = HerdrWireReader(Array(frame.dropFirst(4)))
                guard try reader.variant() == 15 else { continue }
                _ = try reader.string()
                let request = try JSONDecoder().decode(Request.self, from: Data(try reader.string().utf8))
                guard request.method == HerdrScreenModel.paneSelectionReadMethod else { continue }
                return (request.id, try XCTUnwrap(request.params))
            }
        }

        static func pane(scroll: (UInt64, UInt64, UInt64)) -> HerdrServerScript.Pane {
            .init(id: "w1:p1", x: 0, width: 10, height: 3, focused: true, scroll: scroll)
        }
    }

    /// A session shown with one three-row pane, `w1:p1`, whose history Herdr scrolls as `scroll` says,
    /// drawn in a window as on the screen.
    private func shownSession(scroll: (UInt64, UInt64, UInt64)) async throws -> Session {
        let harness = await HerdrModelHarness()
        harnesses.append(harness)
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        let lines = ["alpha beta", "gamma delt", "epsil zeta"]
        let pane = Session.pane(scroll: scroll)
        await bridge.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: lines, panes: [pane]))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 2, lines: lines, panes: [pane]))
        try await harness.waitUntil("the pane's renderer wasn't created") { harness.model.paneSurface("w1:p1") != nil }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let viewController = UIViewController()
        window.rootViewController = viewController
        if let view = harness.model.paneSurface("w1:p1")?.renderer.view {
            viewController.view.addSubview(view)
        }
        window.isHidden = false
        windows.append(window)
        try await harness.waitUntil("the pane didn't draw") { harness.model.presentation(ofPane: "w1:p1") == .ready }
        try await harness.waitUntil("the session wasn't shown") { harness.model.isInputAvailable }

        let surfaceID = try XCTUnwrap(harness.model.terminalScreenAdapter.terminalScreenPresentationProjection.viewport.panes.first?.id)
        let surface = try XCTUnwrap(harness.model.terminalScreenAdapter.terminalManagedSurfaceLookup.managedSurface(for: surfaceID))
        try await harness.waitUntil("Herdr's viewport didn't reach the pane") { surface.scrollState.offset == 40 - scroll.0 }
        return Session(harness: harness, bridge: bridge, surfaceID: surfaceID, lines: lines, next: index)
    }
}
