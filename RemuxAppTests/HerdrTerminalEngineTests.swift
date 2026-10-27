import GhosttyKit
import UIKit
import XCTest
@testable import Remux

/// The engine against real GhosttyKit: producers, renderers created through `HerdrPaneRendererFence`,
/// and the terminals' text read back through Ghostty's own selection.
@MainActor
final class HerdrTerminalEngineTests: XCTestCase {
    private var runtime: GhosttyKitRuntime!
    private var measurement: GhosttyTerminalViewportMeasurement!
    private var renderers: [TerminalPaneRenderer] = []
    /// Holds the renderers' views, as on screen, while a test reads their pixels.
    private var window: UIWindow?

    override func setUp() async throws {
        runtime = try GhosttyKitRuntime(terminalSettings: .default)
        measurement = try XCTUnwrap(runtime.measureTmuxViewportLayout(size: CGSize(width: 390, height: 844), scale: 3))
    }

    override func tearDown() async throws {
        for renderer in renderers {
            await close(renderer)
        }
        window?.isHidden = true
        window = nil
        measurement = nil
        runtime = nil
    }

    // MARK: - Painting

    /// A pane's terminal is painted before any renderer exists; a renderer created later shows it.
    func testPanesArePaintedBeforeTheirRenderersExist() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: ["left 1    right 1", "left 2    right 2"],
            panes: [Self.pane("L", x: 0, width: 8, height: 2, focused: true), Self.pane("R", x: 10, width: 7, height: 2)]
        )))

        let terminals = try await updates.terminals(count: 2)
        XCTAssertEqual(Set(terminals.keys), ["L", "R"])
        let layout = try await updates.nextLayout()
        XCTAssertEqual(layout.panes.map(\.paneID), ["L", "R"])

        let left = try await makeRenderer(engine: engine, paneID: "L", terminal: try XCTUnwrap(terminals["L"]), columns: 8, rows: 2)
        let right = try await makeRenderer(engine: engine, paneID: "R", terminal: try XCTUnwrap(terminals["R"]), columns: 7, rows: 2)
        XCTAssertEqual(rows(of: left, columns: 8, rows: 2), ["left 1", "left 2"])
        XCTAssertEqual(rows(of: right, columns: 7, rows: 2), ["right 1", "right 2"])
        await engine.stop()
    }

    /// A patch repaints only what changed; the rest of the pane, and the other pane, keep their text.
    func testAPatchChangesOnlyTheRowsItTouches() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let panes = [Self.pane("L", x: 0, width: 8, height: 2), Self.pane("R", x: 10, width: 7, height: 2)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["left 1    right 1", "left 2    right 2"], panes: panes)))
        let terminals = try await updates.terminals(count: 2)
        let left = try await makeRenderer(engine: engine, paneID: "L", terminal: try XCTUnwrap(terminals["L"]), columns: 8, rows: 2)
        let right = try await makeRenderer(engine: engine, paneID: "R", terminal: try XCTUnwrap(terminals["R"]), columns: 7, rows: 2)

        await feed.receive(.patch(try Self.patch(
            base: 1,
            rows: [HerdrPatchRow(x: 0, y: 1, cells: Self.cells("LEFT 2  "))],
            panes: panes
        )))

        XCTAssertEqual(rows(of: left, columns: 8, rows: 2), ["left 1", "LEFT 2"])
        XCTAssertEqual(rows(of: right, columns: 7, rows: 2), ["right 1", "right 2"])
        await engine.stop()
    }

    // MARK: - Showing

    /// As in Herdr's client, a show completes on a frame painted after it began, at or after the
    /// projection revision Herdr acknowledged, and at the size asked for. Frames are held meanwhile: one
    /// below the floor and one at another size aren't drawn and don't complete it; the next at the floor
    /// and size does, though none of its cells changed.
    func testAShowCompletesOnAFrameAfterItAtTheAcknowledgedRevisionAndSize() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let panes = [Self.pane("P", x: 0, width: 4, height: 2)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["one ", "two "], panes: panes)))
        _ = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()

        await feed.beginActivation(request: 1, columns: 4, rows: 2)
        await feed.settle(request: 1, answer: nil)
        await feed.acknowledgeActivation(show: 1, floor: 2)
        await feed.receive(.surface(try Self.surface(revision: 2, lines: ["one ", "two "], panes: panes)))
        await feed.receive(try Self.snapshot(revision: 2))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 3, lines: ["one  ", "two  "], panes: panes)))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 4, lines: ["one ", "two "], panes: panes)))

        guard case .activated(let request, let connection) = try await updates.next() else {
            return XCTFail("a frame was drawn before the show completed")
        }
        XCTAssertEqual(request, 1)
        XCTAssertEqual(connection, feed.connection)
        let before = try await updates.nextPresented()
        let shown = try await updates.nextPresented()
        XCTAssertEqual([before.projectionRevision, shown.projectionRevision], [1, 2], "the show completed below its floor")
        await engine.stop()
    }

    /// What the screen shows, for counting agents as seen: each frame drawn against a new snapshot reports
    /// that snapshot's revision and its panes once, and a frame waiting for its snapshot reports nothing
    /// until that snapshot is in.
    func testAFrameOfANewSnapshotReportsThePanesItShows() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let two = [Self.pane("A", x: 0, width: 2, height: 1), Self.pane("B", x: 3, width: 2, height: 1)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["ab cd"], panes: two)))
        let first = try await updates.nextPresented()
        XCTAssertEqual(first.projectionRevision, 1)
        XCTAssertEqual(first.paneIDs, ["A", "B"])

        await feed.receive(.surface(try Self.surface(revision: 2, lines: ["xy cd"], panes: two)))
        await feed.receive(.surface(try Self.surface(
            projection: 2,
            revision: 3,
            lines: ["three"],
            panes: [Self.pane("C", x: 0, width: 5, height: 1)]
        )))
        await feed.receive(try Self.snapshot(revision: 2))
        let second = try await updates.nextPresented()
        XCTAssertEqual(second.projectionRevision, 2)
        XCTAssertEqual(second.paneIDs, ["C"])
        await engine.stop()
    }

    /// A frame can arrive before Herdr's answer to the show; the answer then completes it on that frame.
    /// A resize while the show is in progress needs a frame at the new size, as Herdr's client drops its
    /// evidence.
    func testAFrameBeforeTheAnswerCountsAndAResizeNeedsAFrameAtTheNewSize() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let panes = [Self.pane("P", x: 0, width: 4, height: 2)]
        await feed.receive(try Self.snapshot(revision: 1))

        await feed.beginActivation(request: 1, columns: 4, rows: 2)
        await feed.settle(request: 1, answer: nil)
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["one ", "two "], panes: panes)))
        await feed.acknowledgeActivation(show: 1, floor: 1)
        _ = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()
        guard case .activated(1, _) = try await updates.next() else {
            return XCTFail("the answer didn't complete the show its frame came before")
        }

        await feed.beginActivation(request: 2, columns: 4, rows: 2)
        await feed.settle(request: 2, answer: nil)
        await feed.receive(.surface(try Self.surface(revision: 2, lines: ["one ", "two "], panes: panes)))
        await feed.resizeActivation(columns: 5, rows: 2)
        await feed.acknowledgeActivation(show: 2, floor: 1)
        await feed.receive(.surface(try Self.surface(revision: 3, lines: ["one  ", "two  "], panes: panes)))
        guard case .layout(let resized) = try await updates.next(),
              case .activated(2, _) = try await updates.next()
        else { return XCTFail("a frame from before the resize completed the show") }
        XCTAssertEqual(resized.columns, 5)
        await engine.stop()
    }

    /// As in Herdr's client, the frame completing a show is drawn against the newest snapshot: a snapshot
    /// that arrives after the received frame, before Herdr's answer, waits for its own frame.
    func testAShowWaitsForTheFrameOfASnapshotNewerThanThePaintedOne() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        await feed.receive(try Self.snapshot(revision: 1))

        await feed.beginActivation(request: 1, columns: 4, rows: 2)
        await feed.settle(request: 1, answer: nil)
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: ["one ", "two "],
            panes: [Self.pane("P", x: 0, width: 4, height: 2)]
        )))
        await feed.receive(try Self.snapshot(revision: 2))
        await feed.acknowledgeActivation(show: 1, floor: 1)
        await feed.receive(.surface(try Self.surface(
            projection: 2,
            revision: 2,
            lines: ["one ", "two "],
            panes: [Self.pane("P", x: 0, width: 4, height: 2, scroll: (fromBottom: 0, max: 5, rows: 2))]
        )))

        _ = try await updates.nextLayout()
        guard case .paneScroll(let scrolls) = try await updates.next(),
              case .activated(1, _) = try await updates.next()
        else { return XCTFail("the show completed on a frame its snapshot had replaced") }
        XCTAssertEqual(scrolls["P"]?.maxLinesFromBottom, 5)
        await engine.stop()
    }

    /// Frames Herdr sends after a hide, such as the one showing a zoom the leave undid, aren't drawn: the
    /// frame from before the hide stays until the next show completes, whose frame is drawn.
    func testFramesAfterAHideWaitForTheNextShow() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let one = [Self.pane("P", x: 0, width: 4, height: 2)]
        let two = [Self.pane("P", x: 0, width: 2, height: 2), Self.pane("Q", x: 2, width: 2, height: 2)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["one ", "two "], panes: one)))
        _ = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()

        await feed.endActivation()
        await feed.receive(try Self.snapshot(revision: 2))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 2, lines: ["o t ", "w o "], panes: two)))
        await feed.beginActivation(request: 1, columns: 4, rows: 2)
        await feed.settle(request: 1, answer: nil)
        await feed.acknowledgeActivation(show: 1, floor: 3)
        await feed.receive(try Self.snapshot(revision: 3))
        await feed.receive(.surface(try Self.surface(projection: 3, revision: 3, lines: ["one ", "two "], panes: one)))

        guard case .activated(1, _) = try await updates.next() else {
            return XCTFail("a frame that came after the hide was drawn")
        }
        await engine.stop()
    }

    /// A show carrying Remux's zoom completes once Herdr has answered the zoom, on a frame showing it:
    /// Herdr's frame for the show from before the zoom isn't drawn, whether the answer comes before the
    /// zoomed frame or after it. A zoom that didn't go holds nothing.
    func testAShowCarryingAZoomCompletesOnAFrameFromAfterTheZoom() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let one = [Self.pane("P", x: 0, width: 4, height: 2)]
        let two = [Self.pane("P", x: 0, width: 2, height: 2), Self.pane("Q", x: 2, width: 2, height: 2)]

        await feed.beginActivation(request: 1, columns: 4, rows: 2)
        await feed.acknowledgeActivation(show: 1, floor: 1)
        await feed.receive(try Self.tabSnapshot(revision: 1, zoomed: false))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["o t ", "w o "], panes: two)))
        await feed.settle(request: 1, answer: Self.zoomAnswer(sentAfter: 0, answeredAfter: 1))
        await feed.receive(try Self.tabSnapshot(revision: 2, zoomed: true))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 2, lines: ["one ", "two "], panes: one)))
        guard case .paneTerminal("P", _) = try await updates.next(),
              case .layout(let shown) = try await updates.next()
        else { return XCTFail("the show's frame from before the zoom was drawn") }
        XCTAssertEqual(shown.panes.map(\.paneID), ["P"])
        _ = try await updates.nextPaneScroll()
        guard case .activated(1, _) = try await updates.next() else { return XCTFail("the show didn't complete") }

        await feed.endActivation()
        await feed.beginActivation(request: 2, columns: 4, rows: 2)
        await feed.acknowledgeActivation(show: 2, floor: 3)
        await feed.receive(try Self.tabSnapshot(revision: 3, zoomed: true))
        await feed.receive(.surface(try Self.surface(projection: 3, revision: 3, lines: ["one ", "two "], panes: one)))
        await feed.settle(request: 2, answer: Self.zoomAnswer(sentAfter: 2, answeredAfter: 3))
        guard case .activated(2, _) = try await updates.next() else {
            return XCTFail("an answer after the zoomed frame didn't complete the show")
        }

        await feed.endActivation()
        await feed.beginActivation(request: 3, columns: 4, rows: 2)
        await feed.acknowledgeActivation(show: 3, floor: 4)
        await feed.receive(try Self.tabSnapshot(revision: 4, zoomed: true))
        await feed.receive(.surface(try Self.surface(projection: 4, revision: 4, lines: ["one ", "two "], panes: one)))
        await feed.settle(request: 3, answer: nil)
        guard case .activated(3, _) = try await updates.next() else {
            return XCTFail("a zoom that didn't go held the show")
        }
        await engine.stop()
    }

    /// A move holds the frames until one showing the move's last command: neither the tab left as its
    /// zoom comes off nor the tab reached before its zoom is drawn, only the tab reached as it ends up. A
    /// move whose focus fails shows the newest frame at once.
    func testAMoveToAnotherTabShowsOnlyTheTabItReaches() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let one = [Self.pane("P", x: 0, width: 4, height: 2)]
        let two = [Self.pane("P", x: 0, width: 2, height: 2), Self.pane("Q", x: 2, width: 2, height: 2)]
        await feed.receive(try Self.tabSnapshot(revision: 1, zoomed: true))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["one ", "two "], panes: one)))
        _ = try await updates.terminal(for: "P")
        _ = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()

        await feed.retarget(request: 5, columns: 4, rows: 2)
        await feed.receive(try Self.tabSnapshot(revision: 2, zoomed: false))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 2, lines: ["o t ", "w o "], panes: two)))
        await feed.receive(try Self.tabSnapshot(revision: 3, zoomed: false))
        await feed.receive(.surface(try Self.surface(projection: 3, revision: 3, lines: ["a b ", "c d "], panes: two)))
        await feed.settle(request: 5, answer: Self.zoomAnswer(sentAfter: 3, answeredAfter: 3))
        await feed.receive(try Self.tabSnapshot(revision: 4, zoomed: true))
        await feed.receive(.surface(try Self.surface(projection: 4, revision: 4, lines: ["new ", "tab "], panes: one)))
        guard case .activated(5, _) = try await updates.next() else {
            return XCTFail("a frame from before the move's zoom was drawn")
        }

        await feed.retarget(request: 6, columns: 4, rows: 2)
        await feed.receive(try Self.tabSnapshot(revision: 5, zoomed: false))
        await feed.receive(.surface(try Self.surface(projection: 5, revision: 5, lines: ["o t ", "w o "], panes: two)))
        await feed.settle(request: 6, answer: nil)
        _ = try await updates.terminal(for: "Q")
        while true {
            if case .activated(6, _) = try await updates.next() { break }
        }
        await engine.stop()
    }

    /// As in Herdr's client, a move completes once its focus is answered on a frame showing its pane,
    /// also one that came before the answer: Herdr can send the snapshot and frame first, and sends
    /// nothing more for a move it has already made.
    func testAMoveCompletesOnAFrameShowingItsPaneThatCameBeforeTheAnswer() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let two = [Self.pane("P", x: 0, width: 2, height: 2), Self.pane("Q", x: 2, width: 2, height: 2)]
        await feed.receive(try Self.tabSnapshot(revision: 1, zoomed: false))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["o t ", "w o "], panes: two)))
        _ = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()

        await feed.retarget(request: 2, columns: 4, rows: 2)
        await feed.receive(try Self.tabSnapshot(revision: 2, zoomed: false, focusedPane: "Q"))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 2, lines: ["o t ", "w o "], panes: two)))
        try await Task.sleep(for: .milliseconds(50))
        await feed.settle(request: 2, answer: Self.focusAnswer("Q", sentAfter: 1, answeredAfter: 2))
        guard case .activated(2, _) = try await updates.next() else {
            return XCTFail("the move waited for a frame Herdr had already sent")
        }
        await engine.stop()
    }

    /// A move holds the frames from its start, also when the newest snapshot's frame hasn't come yet,
    /// and the answer of a request it took over completes nothing.
    func testAMoveHoldsFramesFromItsStartAndAnOlderAnswerCompletesNothing() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let one = [Self.pane("P", x: 0, width: 4, height: 2)]
        let two = [Self.pane("P", x: 0, width: 2, height: 2), Self.pane("Q", x: 2, width: 2, height: 2)]
        await feed.receive(try Self.tabSnapshot(revision: 1, zoomed: true))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["one ", "two "], panes: one)))
        _ = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()

        // The next snapshot is in, its frame not yet.
        await feed.receive(try Self.tabSnapshot(revision: 2, zoomed: true))
        await feed.retarget(request: 3, columns: 4, rows: 2)
        await feed.retarget(request: 4, columns: 4, rows: 2)
        await feed.settle(request: 3, answer: nil)
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 2, lines: ["one ", "two "], panes: one)))
        await feed.receive(try Self.tabSnapshot(revision: 3, zoomed: false))
        await feed.receive(.surface(try Self.surface(projection: 3, revision: 3, lines: ["o t ", "w o "], panes: two)))
        try await Task.sleep(for: .milliseconds(50))
        await feed.settle(request: 4, answer: nil)
        guard case .paneTerminal("Q", _) = try await updates.next(),
              case .layout(let reached) = try await updates.next()
        else { return XCTFail("a frame was drawn before the newest move completed") }
        XCTAssertEqual(reached.panes.map(\.paneID), ["P", "Q"])
        _ = try await updates.nextPaneScroll()
        guard case .activated(4, _) = try await updates.next() else { return XCTFail("the newest move didn't complete") }
        await engine.stop()
    }

    /// A pane whose text area changes size is resized and repainted at once: none of its old text
    /// survives beside the new content.
    func testAResizedPaneIsRepaintedAtItsNewSize() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: ["0123456789AB", "second line ", "third line  "],
            panes: [Self.pane("P", x: 0, width: 12, height: 3)]
        )))
        let terminal = try await updates.terminal(for: "P")
        _ = try await updates.nextLayout()
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: terminal, columns: 12, rows: 3)

        await feed.receive(try Self.snapshot(revision: 2))
        await feed.receive(.surface(try Self.surface(
            projection: 2,
            revision: 2,
            lines: ["abcde", "fghij"],
            panes: [Self.pane("P", x: 0, width: 5, height: 2)]
        )))

        let layout = try await updates.nextLayout()
        XCTAssertEqual(layout.panes.first?.innerRect, HerdrSurfaceRect(x: 0, y: 0, width: 5, height: 2))
        XCTAssertEqual(rows(of: renderer, columns: 12, rows: 2), ["abcde", "fghij"])
        await engine.stop()
    }

    /// Every recorded stream, decoded and painted, leaves each pane's terminal showing its cells in the
    /// last frame drawn.
    func testRecordedStreamsLeaveEveryPaneShowingTheLastDrawnFrame() async throws {
        var comparedRows = 0
        for fixture in try HerdrWireTests.goldenFixtures() {
            guard let negotiated = fixture.golden.negotiated else { continue }
            let engine = makeEngine()
            let updates = UpdateLog(engine)
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
            guard let surface = reference.presented?.surface else { continue }
            var terminals: [String: HerdrRetainedTerminal] = [:]
            for update in await updates.drain() {
                switch update {
                case .paneTerminal(let paneID, let terminal): terminals[paneID] = terminal
                case .paneTerminalFailed, .rendererWakeFailed, .failed: XCTFail("\(fixture.name): \(update)")
                case .layout, .paneScroll, .activated, .presented: break
                }
            }
            for pane in surface.panes where pane.innerRect.width > 0 && pane.innerRect.height > 0 {
                let terminal = try XCTUnwrap(terminals[pane.paneID], fixture.name)
                let columns = Int(pane.innerRect.width)
                let height = Int(pane.innerRect.height)
                let renderer = try await makeRenderer(engine: nil, paneID: pane.paneID, terminal: terminal, columns: columns, rows: height)
                let shown = rows(of: renderer, columns: columns, rows: height)
                for (y, expected) in Self.expectedRows(of: surface.frame, area: pane.innerRect).enumerated() {
                    guard let expected else { continue }
                    XCTAssertEqual(shown[y], expected, "\(fixture.name) pane \(pane.paneID) row \(y)")
                    comparedRows += 1
                }
                await close(renderer)
            }
        }
        XCTAssertGreaterThan(comparedRows, 100)
    }

    /// Panes the next frame doesn't list are dropped; their renderers can't register any more.
    func testAPaneMissingFromTheNextFrameIsDropped() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: ["a  b"],
            panes: [Self.pane("A", x: 0, width: 1, height: 1), Self.pane("B", x: 3, width: 1, height: 1)]
        )))
        let terminals = try await updates.terminals(count: 2)
        _ = try await updates.nextLayout()

        await feed.receive(try Self.snapshot(revision: 2))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 2, lines: ["a   "], panes: [Self.pane("A", x: 0, width: 4, height: 1)])))
        let layout = try await updates.nextLayout()
        XCTAssertEqual(layout.panes.map(\.paneID), ["A"])

        let error = await registrationError(engine: engine, paneID: "B", terminal: try XCTUnwrap(terminals["B"]))
        XCTAssertEqual(error, .terminalGone)
        await engine.stop()
    }

    /// A pane's scrolling goes out on its own whenever it changes, never with a new layout: the history
    /// grows with every line a program prints.
    func testAPanesScrollingGoesOutWhenItChanges() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        await feed.receive(try Self.snapshot(revision: 1))
        func surface(_ revision: UInt64, max: Int, mouse: Bool = false) throws -> HerdrSurfaceDecoder.Output {
            .surface(try Self.surface(
                revision: revision,
                lines: ["one"],
                panes: [Self.pane("P", x: 0, width: 3, height: 1, scroll: (0, max, 1), mouseReporting: mouse)]
            ))
        }
        await feed.receive(try surface(1, max: 5))
        _ = try await updates.nextLayout()
        let first = try await updates.nextPaneScroll()
        XCTAssertEqual(first, ["P": HerdrPaneScroll(
            linesFromBottom: 0,
            maxLinesFromBottom: 5,
            rows: 1,
            mouseReporting: false,
            alternateScreenActive: false
        )])

        await feed.receive(try surface(2, max: 6))
        guard case .paneScroll(let grown) = try await updates.next() else {
            return XCTFail("the grown history didn't go out on its own")
        }
        XCTAssertEqual(grown["P"]?.maxLinesFromBottom, 6)

        await feed.receive(try surface(3, max: 6))
        await feed.receive(try surface(4, max: 6, mouse: true))
        guard case .paneScroll(let reporting) = try await updates.next() else {
            return XCTFail("an unchanged frame sent the scrolling again")
        }
        XCTAssertEqual(reporting["P"]?.mouseReporting, true)
        await engine.stop()
    }

    /// A listed pane with no text area has no terminal; with room again it gets a new one.
    func testAPaneWithoutRoomGetsANewTerminalWhenItHasRoomAgain() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["ab"], panes: [Self.pane("P", x: 0, width: 2, height: 1)])))
        let first = try await updates.terminal(for: "P")
        _ = try await updates.nextLayout()

        await feed.receive(try Self.snapshot(revision: 2))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 2, lines: ["ab"], panes: [Self.pane("P", x: 0, width: 0, height: 1)])))
        let layout = try await updates.nextLayout()
        XCTAssertEqual(layout.panes.map(\.paneID), ["P"])
        let stale = await registrationError(engine: engine, paneID: "P", terminal: first)
        XCTAssertEqual(stale, .terminalGone)

        await feed.receive(try Self.snapshot(revision: 3))
        await feed.receive(.surface(try Self.surface(projection: 3, revision: 3, lines: ["cd"], panes: [Self.pane("P", x: 0, width: 2, height: 1)])))
        let second = try await updates.terminal(for: "P")
        XCTAssertFalse(first === second)
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: second, columns: 2, rows: 1)
        XCTAssertEqual(rows(of: renderer, columns: 2, rows: 1), ["cd"])
        await engine.stop()
    }

    /// A new server boot's panes get new terminals, even under the same ids.
    func testANewBootGivesItsPanesNewTerminals() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        await feed.receive(try Self.snapshot(revision: 1, boot: "one"))
        await feed.receive(.surface(try Self.surface(boot: "one", revision: 1, lines: ["one"], panes: [Self.pane("P", x: 0, width: 3, height: 1)])))
        let first = try await updates.terminal(for: "P")
        _ = try await updates.nextLayout()

        await feed.receive(try Self.snapshot(revision: 1, boot: "two"))
        await feed.receive(.surface(try Self.surface(boot: "two", revision: 1, lines: ["two"], panes: [Self.pane("P", x: 0, width: 3, height: 1)])))
        let second = try await updates.terminal(for: "P")
        XCTAssertFalse(first === second)
        let layout = try await updates.nextLayout()
        XCTAssertEqual(layout.bootID, "two")

        let stale = await registrationError(engine: engine, paneID: "P", terminal: first)
        XCTAssertEqual(stale, .terminalGone)
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: second, columns: 3, rows: 1)
        XCTAssertEqual(rows(of: renderer, columns: 3, rows: 1), ["two"])
        await engine.stop()
    }

    /// A later connection's feed takes over: the earlier one's late events are dropped, and the same
    /// boot's next frame is painted into the same terminals, so the last frame stays until then.
    func testALaterConnectionDropsTheEarlierOnesEventsAndKeepsThePanes() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let first = await engine.beginConnection(1)
        let panes = [Self.pane("P", x: 0, width: 3, height: 1)]
        await first.receive(try Self.snapshot(revision: 1))
        await first.receive(.surface(try Self.surface(revision: 1, lines: ["one"], panes: panes)))
        let terminal = try await updates.terminal(for: "P")
        let layout = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: terminal, columns: 3, rows: 1)

        let second = await engine.beginConnection(2)
        await first.receive(.patch(try Self.patch(
            base: 1,
            rows: [HerdrPatchRow(x: 0, y: 0, cells: Self.cells("old"))],
            panes: panes
        )))
        XCTAssertEqual(rows(of: renderer, columns: 3, rows: 1), ["one"])

        // Revisions restart with each connection.
        await second.receive(try Self.snapshot(revision: 1))
        await second.receive(.surface(try Self.surface(revision: 1, lines: ["two"], panes: panes)))
        XCTAssertEqual(rows(of: renderer, columns: 3, rows: 1), ["two"])
        await engine.stop()
        // Only the new connection's frame is reported as what the screen shows.
        let rest = await updates.drain()
        XCTAssertTrue(
            rest.allSatisfy {
                if case .presented(_, _, ["P"], let connection) = $0 { connection == second.connection } else { false }
            },
            "the same panes need no new terminals or layout: \(rest)"
        )
        XCTAssertEqual(layout.tab, nil)
    }

    /// The owner numbers its connections in the order it makes them. Once it ends one, that connection's
    /// events are dropped and the last frame stays; a connection that begins after a newer one began or
    /// ended, as a given-up opening's late one does, changes nothing.
    func testAnEndedConnectionsEventsAreDroppedAndAnOlderOneCannotBeginAgain() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let panes = [Self.pane("P", x: 0, width: 3, height: 1)]
        let second = await engine.beginConnection(2)
        await second.receive(try Self.snapshot(revision: 1))
        await second.receive(.surface(try Self.surface(revision: 1, lines: ["one"], panes: panes)))
        let terminal = try await updates.terminal(for: "P")
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: terminal, columns: 3, rows: 1)

        let first = await engine.beginConnection(1)
        await first.receive(try Self.snapshot(revision: 1))
        await first.receive(.surface(try Self.surface(revision: 1, lines: ["old"], panes: panes)))
        XCTAssertEqual(rows(of: renderer, columns: 3, rows: 1), ["one"])

        await engine.endConnection(2)
        await second.receive(.patch(try Self.patch(
            base: 1,
            rows: [HerdrPatchRow(x: 0, y: 0, cells: Self.cells("two"))],
            panes: panes
        )))
        _ = await engine.beginConnection(2)
        await second.receive(try Self.snapshot(revision: 2))
        await second.receive(.surface(try Self.surface(revision: 2, lines: ["two"], panes: panes)))
        XCTAssertEqual(rows(of: renderer, columns: 3, rows: 1), ["one"])

        let third = await engine.beginConnection(3)
        await third.receive(try Self.snapshot(revision: 1))
        await third.receive(.surface(try Self.surface(revision: 1, lines: ["new"], panes: panes)))
        XCTAssertEqual(rows(of: renderer, columns: 3, rows: 1), ["new"])
        await engine.stop()
    }

    /// A pane Ghostty couldn't paint stays unpainted for the rest of its connection, and gets a new
    /// terminal from the next connection's first frame.
    func testAFailedPaneGetsANewTerminalFromTheNextConnection() async throws {
        let producerFailure = ProducerFailure()
        let engine = makeEngine(producerFailure: producerFailure)
        let updates = UpdateLog(engine)
        let panes = [Self.pane("P", x: 0, width: 3, height: 1)]
        let first = await engine.beginConnection(1)
        await first.receive(try Self.snapshot(revision: 1))
        await first.receive(.surface(try Self.surface(revision: 1, lines: ["one"], panes: panes)))
        let failed = try await updates.terminal(for: "P")
        _ = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()

        producerFailure.isOn = true
        await first.receive(.patch(try Self.patch(
            base: 1,
            rows: [HerdrPatchRow(x: 0, y: 0, cells: Self.cells("two"))],
            panes: panes
        )))
        guard case .paneTerminalFailed("P") = try await updates.next() else {
            return XCTFail("expected the pane's failure")
        }
        producerFailure.isOn = false
        await first.receive(.patch(try Self.patch(
            base: 2,
            rows: [HerdrPatchRow(x: 0, y: 0, cells: Self.cells("six"))],
            panes: panes
        )))

        let second = await engine.beginConnection(2)
        await second.receive(try Self.snapshot(revision: 1))
        await second.receive(.surface(try Self.surface(revision: 1, lines: ["new"], panes: panes)))
        guard case .paneTerminal("P", let fresh) = try await updates.next() else {
            return XCTFail("expected a new terminal from the next connection, not an update on the failed one")
        }
        XCTAssertFalse(fresh === failed)
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: fresh, columns: 3, rows: 1)
        XCTAssertEqual(rows(of: renderer, columns: 3, rows: 1), ["new"])
        await engine.stop()
    }

    /// A grid Remux can't index ends the engine as a wire failure; nothing after it is painted.
    func testAnUnindexableSurfaceIsAWireFailure() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: ["abcd"],
            panes: [Self.pane("P", x: 2, width: 5, height: 1)]
        )))
        guard case .failed(.wire, _) = try await updates.next() else {
            return XCTFail("expected a wire failure")
        }
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["abcd"], panes: [Self.pane("P", x: 0, width: 4, height: 1)])))
        await engine.stop()
        let after = await updates.drain()
        XCTAssertTrue(after.isEmpty, "\(after)")
    }

    // MARK: - Images

    /// An image Herdr places in a pane is drawn by that pane's terminal at its cells, counted from the
    /// pane's own text area, and by no other pane's.
    func testAnImageIsDrawnInItsPaneAtItsCells() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let image = Self.redImage(pane: "R")
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: ["left 1    right 1 ", "left 2    right 2 ", "                  ", "                  "],
            panes: [Self.pane("L", x: 0, y: 1, width: 8, height: 3), Self.pane("R", x: 10, y: 1, width: 8, height: 3)],
            graphics: Self.scene(placing: image, at: [(x: 13, y: 2, columns: 3, rows: 2)], sendingBytes: true)
        )))
        let terminals = try await updates.terminals(count: 2)
        let left = try await makeRenderer(engine: engine, paneID: "L", terminal: try XCTUnwrap(terminals["L"]), columns: 8, rows: 3)
        let right = try await makeRenderer(engine: engine, paneID: "R", terminal: try XCTUnwrap(terminals["R"]), columns: 8, rows: 3)

        let drawn = try await cellColor(of: right, column: 4, row: 1.5, until: \.isRed)
        XCTAssertTrue(drawn.isRed, "the image's cells in its pane: \(drawn)")
        let outside = try await cellColor(of: right, column: 1, row: 0, until: { !$0.isRed })
        XCTAssertFalse(outside.isRed, "a cell of the pane the image doesn't cover: \(outside)")
        let otherPane = try await cellColor(of: left, column: 4, row: 1.5, until: { !$0.isRed })
        XCTAssertFalse(otherPane.isRed, "the same cells in the other pane: \(otherPane)")
        await engine.stop()
    }

    /// Herdr sends an image's bytes once and then only places it. A pane whose terminal is new, here
    /// back after another tab was shown while Herdr kept the image, draws it from the bytes Herdr sent
    /// before.
    func testAPaneBackFromAnotherTabDrawsTheImageHerdrKept() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let image = Self.redImage(pane: "P")
        let lines = ["first   ", "second  ", "third   "]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: lines,
            panes: [Self.pane("P", x: 0, width: 8, height: 3)],
            graphics: Self.scene(placing: image, at: [(x: 2, y: 0, columns: 4, rows: 2)], sendingBytes: true)
        )))
        let first = try await updates.terminal(for: "P")

        await feed.receive(try Self.snapshot(revision: 2))
        await feed.receive(.surface(try Self.surface(
            projection: 2,
            revision: 2,
            lines: lines,
            panes: [Self.pane("Q", x: 0, width: 8, height: 3)],
            graphics: Self.scene(retaining: image)
        )))
        await feed.receive(try Self.snapshot(revision: 3))
        await feed.receive(.surface(try Self.surface(
            projection: 3,
            revision: 3,
            lines: lines,
            panes: [Self.pane("P", x: 0, width: 8, height: 3)],
            graphics: Self.scene(placing: image, at: [(x: 2, y: 0, columns: 4, rows: 2)], sendingBytes: false)
        )))
        let back = try await updates.terminal(for: "P")
        XCTAssertFalse(first === back)
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: back, columns: 8, rows: 3)
        let drawn = try await cellColor(of: renderer, column: 4, row: 1, until: \.isRed)
        XCTAssertTrue(drawn.isRed, "the kept image in the pane's new terminal: \(drawn)")
        await engine.stop()
    }

    /// Each frame's scene is the whole of what is placed: a placement Herdr moves is drawn at its new
    /// cells and not at its old ones, and one it no longer lists is gone.
    func testAPlacementFollowsEachFramesScene() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let image = Self.redImage(pane: "P")
        let lines = ["one     ", "two     ", "three   ", "four    "]
        let panes = [Self.pane("P", x: 0, width: 8, height: 4)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: lines,
            panes: panes,
            graphics: Self.scene(placing: image, at: [(x: 4, y: 0, columns: 3, rows: 1)], sendingBytes: true)
        )))
        let renderer = try await makeRenderer(
            engine: engine, paneID: "P", terminal: try await updates.terminal(for: "P"), columns: 8, rows: 4
        )
        let placed = try await cellColor(of: renderer, column: 5, row: 0, until: \.isRed)
        XCTAssertTrue(placed.isRed, "\(placed)")

        await feed.receive(.surface(try Self.surface(
            revision: 2,
            lines: lines,
            panes: panes,
            graphics: Self.scene(placing: image, at: [(x: 4, y: 2, columns: 3, rows: 1)], sendingBytes: false)
        )))
        let moved = try await cellColor(of: renderer, column: 5, row: 2, until: \.isRed)
        XCTAssertTrue(moved.isRed, "the new cells: \(moved)")
        let left = try await cellColor(of: renderer, column: 5, row: 0, until: { !$0.isRed })
        XCTAssertFalse(left.isRed, "the old cells: \(left)")

        await feed.receive(.surface(try Self.surface(revision: 3, lines: lines, panes: panes)))
        let gone = try await cellColor(of: renderer, column: 5, row: 2, until: { !$0.isRed })
        XCTAssertFalse(gone.isRed, "a placement the scene no longer lists: \(gone)")
        await engine.stop()
    }

    /// Herdr can send a replaced image's bytes in a later frame, past its per-message budget. Until they
    /// arrive, a placement that is otherwise the same keeps showing the image it had, as in Herdr's
    /// client; then it shows the new one.
    func testAReplacedImageShowsTheOldOneUntilItsBytesArrive() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let old = Self.image(pane: "P", version: 7)
        let new = Self.image(pane: "P", version: 8)
        let marker = Self.image(pane: "P", id: 9)
        let lines = ["one     ", "two     ", "three   ", "four    "]
        let panes = [Self.pane("P", x: 0, width: 8, height: 4)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: lines,
            panes: panes,
            graphics: Self.scene([(image: old, x: 2, y: 0, columns: 4, rows: 2, pixel: Self.red)])
        )))
        let renderer = try await makeRenderer(
            engine: engine, paneID: "P", terminal: try await updates.terminal(for: "P"), columns: 8, rows: 4
        )
        let before = try await cellColor(of: renderer, column: 4, row: 1, until: \.isRed)
        XCTAssertTrue(before.isRed, "\(before)")

        // The marker, whose bytes come with this frame, shows once the frame is drawn.
        await feed.receive(.surface(try Self.surface(
            revision: 2,
            lines: lines,
            panes: panes,
            graphics: Self.scene([
                (image: new, x: 2, y: 0, columns: 4, rows: 2, pixel: nil),
                (image: marker, x: 0, y: 3, columns: 2, rows: 1, pixel: Self.green),
            ])
        )))
        let drawn = try await cellColor(of: renderer, column: 1, row: 3, until: \.isGreen)
        XCTAssertTrue(drawn.isGreen, "the frame with the replacement: \(drawn)")
        let waiting = try await cellColor(of: renderer, column: 4, row: 1, until: { _ in true })
        XCTAssertTrue(waiting.isRed, "the old image while the new bytes are on their way: \(waiting)")

        await feed.receive(.surface(try Self.surface(
            revision: 3,
            lines: lines,
            panes: panes,
            graphics: Self.scene([
                (image: new, x: 2, y: 0, columns: 4, rows: 2, pixel: Self.green),
                (image: marker, x: 0, y: 3, columns: 2, rows: 1, pixel: nil),
            ])
        )))
        let replaced = try await cellColor(of: renderer, column: 4, row: 1, until: \.isGreen)
        XCTAssertTrue(replaced.isGreen, "the new image once its bytes arrive: \(replaced)")
        await engine.stop()
    }

    // MARK: - Fence and stop

    /// One registered surface per pane; a closed renderer is unregistered before its surface is freed,
    /// and the engine never wakes it again.
    func testRegistrationGoesThroughTheEngineAndUnregistrationFencesWakes() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let panes = [Self.pane("P", x: 0, width: 4, height: 1)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["abcd"], panes: panes)))
        let terminal = try await updates.terminal(for: "P")
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: terminal, columns: 4, rows: 1)

        // Ghostty gives a terminal one renderer at a time, so only the same surface can come back.
        let surface = HerdrRendererSurface(handle: try XCTUnwrap(renderer.rawSurface))
        guard case .failure(.alreadyRegistered) = await engine.register(surface, paneID: "P", terminal: terminal) else {
            return XCTFail("expected the second registration to be refused")
        }

        await close(renderer)
        // The surface is freed: painting the pane now must not wake it.
        for revision in UInt64(2)...UInt64(20) {
            await feed.receive(.patch(try Self.patch(
                base: revision - 1,
                rows: [HerdrPatchRow(x: 0, y: 0, cells: Self.cells(String(format: "%04d", revision)))],
                panes: panes
            )))
        }
        let again = try await makeRenderer(engine: engine, paneID: "P", terminal: terminal, columns: 4, rows: 1)
        XCTAssertEqual(rows(of: again, columns: 4, rows: 1), ["0020"])
        await engine.stop()
    }

    /// Frames and cell sizes still arriving while the engine stops are either applied before the stop
    /// or dropped; after it, registration fails, an unregistration still completes, and the updates end.
    func testStopWithWorkInFlight() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let panes = [Self.pane("P", x: 0, width: 4, height: 1)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["abcd"], panes: panes)))
        let terminal = try await updates.terminal(for: "P")
        _ = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: terminal, columns: 4, rows: 1)

        let patches = try (UInt64(2)...UInt64(400)).map { revision in
            try Self.patch(
                base: revision - 1,
                rows: [HerdrPatchRow(x: 0, y: 0, cells: Self.cells(String(format: "%04d", revision)))],
                panes: panes
            )
        }
        let feeding = Task.detached {
            for patch in patches { await feed.receive(.patch(patch)) }
        }
        let resizing = Task.detached {
            for size in UInt32(10)...UInt32(60) { await engine.setCellSize(widthPx: size, heightPx: size * 2) }
        }
        await Task.yield()
        await engine.stop()
        await feeding.value
        await resizing.value

        await close(renderer)
        let afterStop = await registrationError(engine: engine, paneID: "P", terminal: terminal)
        XCTAssertEqual(afterStop, .engineEnded)
        let rest = await updates.drain()
        XCTAssertTrue(rest.isEmpty, "\(rest)")
    }

    // MARK: - Fixtures

    private func makeEngine(producerFailure: ProducerFailure? = nil) -> HerdrTerminalEngine {
        let cellWidth = measurement.cellMetrics.pixelWidth
        let cellHeight = measurement.cellMetrics.pixelHeight
        guard let producerFailure else {
            return HerdrTerminalEngine(cellWidthPx: cellWidth, cellHeightPx: cellHeight)
        }
        return HerdrTerminalEngine(
            cellWidthPx: cellWidth,
            cellHeightPx: cellHeight,
            makeProducer: SwitchableProducer.factory(producerFailure)
        )
    }

    /// A renderer of `columns` × `rows` cells over `terminal`, registered through the engine's fence,
    /// or through a fence that admits it as is for a stopped engine's terminal.
    private func makeRenderer(
        engine: HerdrTerminalEngine?,
        paneID: String,
        terminal: HerdrRetainedTerminal,
        columns: Int,
        rows: Int
    ) async throws -> TerminalPaneRenderer {
        let fence: any TerminalPaneRendererFence = engine.map { HerdrPaneRendererFence(engine: $0, paneID: paneID, terminal: terminal) }
            ?? AdmittingFence()
        let metrics = try XCTUnwrap(measurement.displayMetrics(columns: UInt32(columns), rows: UInt32(rows)))
        let renderer = try await withCheckedThrowingContinuation { continuation in
            TerminalPaneRenderer.create(
                app: runtime.appHandleForTesting,
                terminal: terminal,
                fence: fence,
                writeInput: nil,
                baseConfig: runtime.makeTmuxBaseSurfaceConfig(),
                metrics: metrics,
                theme: .ghosttyDefault,
                diagnosticName: "test pane=\(paneID)",
                onRendererFailure: {}
            ) { result in continuation.resume(with: result) }
        }
        renderers.append(renderer)
        return renderer
    }

    private func close(_ renderer: TerminalPaneRenderer) async {
        renderers.removeAll { $0 === renderer }
        await withCheckedContinuation { continuation in
            renderer.close { continuation.resume() }
        }
    }

    private func registrationError(
        engine: HerdrTerminalEngine,
        paneID: String,
        terminal: HerdrRetainedTerminal
    ) async -> HerdrRendererRegistrationError? {
        do {
            let renderer = try await makeRenderer(engine: engine, paneID: paneID, terminal: terminal, columns: 1, rows: 1)
            await close(renderer)
            return nil
        } catch TerminalPaneRenderer.CreateError.registrationFailed(let error) {
            return error as? HerdrRendererRegistrationError
        } catch {
            XCTFail("unexpected error \(error)")
            return nil
        }
    }

    private func rows(of renderer: TerminalPaneRenderer, columns: Int, rows: Int) -> [String] {
        RendererText.rows(of: renderer, columns: columns, rows: rows)
    }

    /// The colour Ghostty draws at a point of the renderer's grid, given in cells (the middle of cell
    /// `column` is `column + 0.5`), from frames it draws on request: the first that satisfies `done`, or
    /// the last one after 10 s.
    private func cellColor(
        of renderer: TerminalPaneRenderer,
        column: Double,
        row: Double,
        until done: (RendererColor) -> Bool
    ) async throws -> RendererColor {
        let surface = try XCTUnwrap(renderer.rawSurface)
        if renderer.view.window == nil {
            let window = self.window ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = window.rootViewController ?? UIViewController()
            window.isHidden = false
            window.rootViewController?.view.addSubview(renderer.view)
            self.window = window
        }
        var size = ghostty_surface_size_s()
        XCTAssertEqual(ghostty_terminal_surface_size(surface, &size), GHOSTTY_TERMINAL_SURFACE_RESULT_OK)
        let point = CGRect(
            x: (column + 0.5) * Double(size.cell_width_px),
            y: (row + 0.5) * Double(size.cell_height_px),
            width: 1,
            height: 1
        )
        let deadline = Date().addingTimeInterval(10)
        var last: RendererColor?
        repeat {
            _ = ghostty_terminal_surface_request_frame(surface)
            ghostty_app_tick(runtime.appHandleForTesting)
            try await Task.sleep(for: .milliseconds(50))
            if let layer = GhosttyIOSurfaceFrame.rendererLayer(in: renderer.view.layer),
               let frame = try? GhosttyIOSurfaceFrame.read(from: layer, sourceRect: point) {
                let pixel = Array(frame.bytes.prefix(4))
                let color = RendererColor(red: pixel[2], green: pixel[1], blue: pixel[0])
                last = color
                if done(color) { return color }
            }
        } while Date() < deadline
        return try XCTUnwrap(last, "the renderer published no frame")
    }

    /// Each row of the area as text without surrounding blanks; nil for a row this check can't predict
    /// (anything but printable ASCII).
    private static func expectedRows(of frame: HerdrFrame, area: HerdrSurfaceRect) -> [String?] {
        (0..<Int(area.height)).map { y in
            let start = (Int(area.y) + y) * Int(frame.width) + Int(area.x)
            let symbols = frame.cells[start..<(start + Int(area.width))].map(\.symbol)
            guard symbols.allSatisfy({ $0.unicodeScalars.count == 1 && $0.unicodeScalars.allSatisfy { (0x20..<0x7F).contains($0.value) } })
            else { return nil }
            return symbols.joined().trimmingCharacters(in: .whitespaces)
        }
    }

    static func snapshot(revision: UInt64, boot: String = "boot") throws -> HerdrSnapshot {
        try HerdrPresentationTests.snapshot(revision: revision, boot: boot)
    }

    /// A snapshot whose focused tab `t1` is `zoomed` or not, with `focusedPane` focused.
    static func tabSnapshot(revision: UInt64, zoomed: Bool, focusedPane: String = "P") throws -> HerdrSnapshot {
        let json = """
        {"boot_id":"boot","revision":\(revision),"focused_workspace_id":"w1","focused_tab_id":"t1",
         "focused_pane_id":"\(focusedPane)","workspaces":[],"tabs":[{"tab_id":"t1","workspace_id":"w1","number":1,
         "label":"main","custom_label":true,"zoomed":\(zoomed),"focused":true,"agent_status":"idle"}],
         "panes":[],"agents":[]}
        """
        return try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
    }

    /// Herdr's answer zooming tab `t1`, sent and answered after the given snapshots.
    static func zoomAnswer(sentAfter: UInt64, answeredAfter: UInt64) -> HerdrTerminalEngine.CommandAnswer {
        HerdrTerminalEngine.CommandAnswer(sentAfter: sentAfter, answeredAfter: answeredAfter) { snapshot in
            snapshot.tabs.first { $0.tabID == "t1" }?.zoomed == true
        }
    }

    /// Herdr's answer focusing `paneID`, sent and answered after the given snapshots.
    static func focusAnswer(_ paneID: String, sentAfter: UInt64, answeredAfter: UInt64) -> HerdrTerminalEngine.CommandAnswer {
        HerdrTerminalEngine.CommandAnswer(sentAfter: sentAfter, answeredAfter: answeredAfter) { $0.focusedPaneID == paneID }
    }

    static func cells(_ text: String) -> [HerdrCell] {
        text.map {
            HerdrCell(symbol: String($0), fg: HerdrColor(raw: 0), bg: HerdrColor(raw: 0), modifier: 0, skip: false, hyperlink: nil)
        }
    }

    /// `scroll` is the viewport's lines from the bottom, the most it can be, and the program's rows.
    static func pane(
        _ id: String,
        x: Int,
        y: Int = 0,
        width: Int,
        height: Int,
        focused: Bool = false,
        scroll: (fromBottom: Int, max: Int, rows: Int)? = nil,
        mouseReporting: Bool = false
    ) -> String {
        let scrollJSON = scroll.map {
            #"{"offset_from_bottom":\#($0.fromBottom),"max_offset_from_bottom":\#($0.max),"viewport_rows":\#($0.rows)}"#
        } ?? "null"
        return """
        {"pane_id":"\(id)","content_revision":1,"rect":{"x":\(x),"y":\(y),"width":\(width),"height":\(height)},
         "inner_rect":{"x":\(x),"y":\(y),"width":\(width),"height":\(height)},"scrollbar_rect":null,"scroll":\(scrollJSON),
         "focused":\(focused),"mouse_reporting":\(mouseReporting),"sgr_pixel_mouse":false,
         "alternate_screen_active":false,"pixel_width":0,"pixel_height":0}
        """
    }

    /// A surface of the given lines, all of one width, with `graphics` as its scene.
    static func surface(
        boot: String = "boot",
        projection: UInt64 = 1,
        revision: UInt64,
        lines: [String],
        panes: [String],
        graphics: String = #"{"assets":[],"placements":[],"retained_assets":[]}"#
    ) throws -> HerdrPaneSurfaceFrame {
        let width = lines.first?.count ?? 0
        precondition(lines.allSatisfy { $0.count == width })
        let cells = lines.joined().map {
            #"{"symbol":"\#($0)","fg":0,"bg":0,"modifier":0,"skip":false,"hyperlink":null}"#
        }
        let json = """
        {"boot_id":"\(boot)","projection_revision":\(projection),"surface_revision":\(revision),
         "frame":{"cells":[\(cells.joined(separator: ","))],"width":\(width),"height":\(lines.count),"cursor":null,"hyperlinks":[],"graphics":[]},
         "panes":[\(panes.joined(separator: ","))],"splits":[],"popup":null,"graphics":\(graphics)}
        """
        return try JSONDecoder().decode(HerdrPaneSurfaceFrame.self, from: Data(json.utf8))
    }

    static func patch(base: UInt64, rows: [HerdrPatchRow], panes: [String]) throws -> HerdrPaneSurfacePatch {
        try HerdrPresentationTests.patch(base: base, rows: rows, panes: panes)
    }

    /// The key of a solid red 2×2 RGBA image from terminal image 7 of pane `pane`.
    static func redImage(pane: String) -> String {
        image(pane: pane)
    }

    /// The key of a solid 2×2 RGBA image from terminal image `id` of pane `pane`. A new `version` is
    /// that image replaced: the same source with other contents.
    static func image(pane: String, id: Int = 7, version: Int = 7) -> String {
        #"{"source":{"Terminal":{"target":{"Pane":{"pane_id":"\#(pane)"}},"image_id":\#(id)}},"#
            + #""image_width":2,"image_height":2,"format":"Rgba","data_len":16,"data_fingerprint":\#(version)}"#
    }

    static let red = "255,0,0,255"
    static let green = "0,255,0,255"

    /// A scene placing the red `image` at each of `cells` (in the frame's cells), carrying its bytes or not.
    static func scene(
        placing image: String,
        at cells: [(x: Int, y: Int, columns: Int, rows: Int)],
        sendingBytes: Bool
    ) -> String {
        scene(cells.map { (image: image, x: $0.x, y: $0.y, columns: $0.columns, rows: $0.rows, pixel: sendingBytes ? red : nil) })
    }

    /// A scene placing each image at its cells, carrying the bytes of those given a `pixel` colour.
    static func scene(_ placed: [(image: String, x: Int, y: Int, columns: Int, rows: Int, pixel: String?)]) -> String {
        var sent = Set<String>()
        let assets = placed.compactMap { item -> String? in
            guard let pixel = item.pixel, sent.insert(item.image).inserted else { return nil }
            return #"{"key":\#(item.image),"data":[\#(Array(repeating: pixel, count: 4).joined(separator: ","))]}"#
        }
        let placements = placed.enumerated().map { index, item in
            #"{"asset":\#(item.image),"logical_placement_id":\#(index + 1),"x":\#(item.x),"y":\#(item.y),"#
                + #""cols":\#(item.columns),"rows":\#(item.rows),"source_x":0,"source_y":0,"source_width":0,"#
                + #""source_height":0,"x_offset":0,"y_offset":0,"z":0,"scrollback_offset":0}"#
        }
        return #"{"assets":[\#(assets.joined(separator: ","))],"placements":[\#(placements.joined(separator: ","))],"#
            + #""retained_assets":[]}"#
    }

    /// A scene that places nothing and keeps `image`, as Herdr keeps an image whose pane is out of view.
    static func scene(retaining image: String) -> String {
        #"{"assets":[],"placements":[],"retained_assets":[\#(image)]}"#
    }
}

/// A colour read from a renderer's frame.
struct RendererColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    /// The red of the test images, through Ghostty's colour handling.
    var isRed: Bool { red > 200 && green < 80 && blue < 80 }
    var isGreen: Bool { green > 200 && red < 80 && blue < 80 }
}

/// The engine's updates, read in order through the stream's one iterator.
@MainActor
/// The engine's updates in order. `next` leaves out the frames reported as presented, which only the
/// model's acknowledgement of seen agents reads; `nextPresented` reads them.
private final class UpdateLog {
    private var iterator: AsyncStream<HerdrEngineUpdate>.AsyncIterator
    private var presented: [(bootID: String, projectionRevision: UInt64, paneIDs: Set<String>)] = []

    init(_ engine: HerdrTerminalEngine) {
        iterator = engine.updates.makeAsyncIterator()
    }

    func next() async throws -> HerdrEngineUpdate {
        while true {
            guard let update = await nextOrEnd() else { throw UpdateLogError.finished }
            guard case .presented(let bootID, let revision, let paneIDs, _) = update else { return update }
            presented.append((bootID, revision, paneIDs))
        }
    }

    /// The next frame reported as presented, passing over any other update.
    func nextPresented() async throws -> (bootID: String, projectionRevision: UInt64, paneIDs: Set<String>) {
        while presented.isEmpty {
            guard let update = await nextOrEnd() else { throw UpdateLogError.finished }
            if case .presented(let bootID, let revision, let paneIDs, _) = update {
                presented.append((bootID, revision, paneIDs))
            }
        }
        return presented.removeFirst()
    }

    /// The rest of the updates, once the engine has stopped.
    func drain() async -> [HerdrEngineUpdate] {
        var rest: [HerdrEngineUpdate] = []
        while let update = await nextOrEnd() { rest.append(update) }
        return rest
    }

    func terminals(count: Int) async throws -> [String: HerdrRetainedTerminal] {
        var terminals: [String: HerdrRetainedTerminal] = [:]
        while terminals.count < count {
            guard case .paneTerminal(let paneID, let terminal) = try await next() else { continue }
            terminals[paneID] = terminal
        }
        return terminals
    }

    func terminal(for paneID: String) async throws -> HerdrRetainedTerminal {
        while true {
            if case .paneTerminal(paneID, let terminal) = try await next() { return terminal }
        }
    }

    func nextLayout() async throws -> HerdrPaneLayout {
        while true {
            if case .layout(let layout) = try await next() { return layout }
        }
    }

    func nextPaneScroll() async throws -> [String: HerdrPaneScroll] {
        while true {
            if case .paneScroll(let scrolls) = try await next() { return scrolls }
        }
    }

    private func nextOrEnd() async -> HerdrEngineUpdate? {
        var iterator = self.iterator
        defer { self.iterator = iterator }
        return await iterator.next(isolation: #isolation)
    }
}

private enum UpdateLogError: Error {
    case finished
}

/// Admits renderers over a stopped engine's terminals, which nothing feeds any more.
@MainActor
private final class AdmittingFence: TerminalPaneRendererFence {
    func registerRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
    ) {
        completion(.success(()))
    }

    func unregisterRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        completion()
    }
}
