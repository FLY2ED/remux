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

    override func setUp() async throws {
        runtime = try GhosttyKitRuntime(terminalSettings: .default)
        measurement = try XCTUnwrap(runtime.measureTmuxViewportLayout(size: CGSize(width: 390, height: 844), scale: 3))
    }

    override func tearDown() async throws {
        for renderer in renderers {
            await close(renderer)
        }
        measurement = nil
        runtime = nil
    }

    // MARK: - Painting

    /// A pane's terminal is painted before any renderer exists; a renderer created later shows it.
    func testPanesArePaintedBeforeTheirRenderersExist() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection()
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
        let feed = await engine.beginConnection()
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
    /// projection revision Herdr acknowledged, and at the size asked for. The frame from before it, one
    /// below the floor and one at another size don't complete it; the next at the floor and size does,
    /// though none of its cells changed.
    func testAShowCompletesOnAFrameAfterItAtTheAcknowledgedRevisionAndSize() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection()
        let panes = [Self.pane("P", x: 0, width: 4, height: 2)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["one ", "two "], panes: panes)))
        _ = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()

        await feed.beginActivation(request: 1, columns: 4, rows: 2)
        await feed.acknowledgeActivation(request: 1, floor: 2)
        await feed.receive(.surface(try Self.surface(revision: 2, lines: ["one ", "two "], panes: panes)))
        await feed.receive(try Self.snapshot(revision: 2))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 3, lines: ["one  ", "two  "], panes: panes)))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 4, lines: ["one ", "two "], panes: panes)))

        guard case .layout(let wider) = try await updates.next(),
              case .layout(let shown) = try await updates.next(),
              case .activated(let request, let connection) = try await updates.next()
        else { return XCTFail("the show completed before its frame") }
        XCTAssertEqual(wider.columns, 5)
        XCTAssertEqual(shown.columns, 4)
        XCTAssertEqual(request, 1)
        XCTAssertEqual(connection, feed.connection)
        await engine.stop()
    }

    /// A frame can arrive before Herdr's answer to the show; the answer then completes it. A resize while
    /// the show is in progress needs a frame at the new size, as Herdr's client drops its evidence.
    func testAFrameBeforeTheAnswerCountsAndAResizeNeedsAFrameAtTheNewSize() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection()
        let panes = [Self.pane("P", x: 0, width: 4, height: 2)]
        await feed.receive(try Self.snapshot(revision: 1))

        await feed.beginActivation(request: 1, columns: 4, rows: 2)
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["one ", "two "], panes: panes)))
        _ = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()
        await feed.acknowledgeActivation(request: 1, floor: 1)
        guard case .activated(1, _) = try await updates.next() else {
            return XCTFail("the answer didn't complete the show its frame came before")
        }

        await feed.beginActivation(request: 2, columns: 4, rows: 2)
        await feed.receive(.surface(try Self.surface(revision: 2, lines: ["one ", "two "], panes: panes)))
        await feed.resizeActivation(columns: 5, rows: 2)
        await feed.acknowledgeActivation(request: 2, floor: 1)
        await feed.receive(.surface(try Self.surface(revision: 3, lines: ["one  ", "two  "], panes: panes)))
        guard case .layout(let resized) = try await updates.next(),
              case .activated(2, _) = try await updates.next()
        else { return XCTFail("a frame from before the resize completed the show") }
        XCTAssertEqual(resized.columns, 5)
        await engine.stop()
    }

    /// A pane whose text area changes size is resized and repainted at once: none of its old text
    /// survives beside the new content.
    func testAResizedPaneIsRepaintedAtItsNewSize() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection()
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
            let feed = await engine.beginConnection()
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
                case .layout, .paneScroll, .activated: break
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
        let feed = await engine.beginConnection()
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
        let feed = await engine.beginConnection()
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
        let feed = await engine.beginConnection()
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
        let feed = await engine.beginConnection()
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
        let first = await engine.beginConnection()
        let panes = [Self.pane("P", x: 0, width: 3, height: 1)]
        await first.receive(try Self.snapshot(revision: 1))
        await first.receive(.surface(try Self.surface(revision: 1, lines: ["one"], panes: panes)))
        let terminal = try await updates.terminal(for: "P")
        let layout = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: terminal, columns: 3, rows: 1)

        let second = await engine.beginConnection()
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
        let rest = await updates.drain()
        XCTAssertTrue(rest.isEmpty, "the same panes need no new terminals or layout: \(rest)")
        XCTAssertEqual(layout.tab, nil)
    }

    /// A pane Ghostty couldn't paint stays unpainted for the rest of its connection, and gets a new
    /// terminal from the next connection's first frame.
    func testAFailedPaneGetsANewTerminalFromTheNextConnection() async throws {
        let producerFailure = ProducerFailure()
        let engine = makeEngine(producerFailure: producerFailure)
        let updates = UpdateLog(engine)
        let panes = [Self.pane("P", x: 0, width: 3, height: 1)]
        let first = await engine.beginConnection()
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

        let second = await engine.beginConnection()
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
        let feed = await engine.beginConnection()
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

    // MARK: - Fence and stop

    /// One registered surface per pane; a closed renderer is unregistered before its surface is freed,
    /// and the engine never wakes it again.
    func testRegistrationGoesThroughTheEngineAndUnregistrationFencesWakes() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection()
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
        let feed = await engine.beginConnection()
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

    static func cells(_ text: String) -> [HerdrCell] {
        text.map {
            HerdrCell(symbol: String($0), fg: HerdrColor(raw: 0), bg: HerdrColor(raw: 0), modifier: 0, skip: false, hyperlink: nil)
        }
    }

    /// `scroll` is the viewport's lines from the bottom, the most it can be, and the program's rows.
    static func pane(
        _ id: String,
        x: Int,
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
        {"pane_id":"\(id)","content_revision":1,"rect":{"x":\(x),"y":0,"width":\(width),"height":\(height)},
         "inner_rect":{"x":\(x),"y":0,"width":\(width),"height":\(height)},"scrollbar_rect":null,"scroll":\(scrollJSON),
         "focused":\(focused),"mouse_reporting":\(mouseReporting),"sgr_pixel_mouse":false,
         "alternate_screen_active":false,"pixel_width":0,"pixel_height":0}
        """
    }

    /// A surface of the given lines, all of one width.
    static func surface(
        boot: String = "boot",
        projection: UInt64 = 1,
        revision: UInt64,
        lines: [String],
        panes: [String]
    ) throws -> HerdrPaneSurfaceFrame {
        let width = lines.first?.count ?? 0
        precondition(lines.allSatisfy { $0.count == width })
        let cells = lines.joined().map {
            #"{"symbol":"\#($0)","fg":0,"bg":0,"modifier":0,"skip":false,"hyperlink":null}"#
        }
        let json = """
        {"boot_id":"\(boot)","projection_revision":\(projection),"surface_revision":\(revision),
         "frame":{"cells":[\(cells.joined(separator: ","))],"width":\(width),"height":\(lines.count),"cursor":null,"hyperlinks":[],"graphics":[]},
         "panes":[\(panes.joined(separator: ","))],"splits":[],"popup":null,
         "graphics":{"assets":[],"placements":[],"retained_assets":[]}}
        """
        return try JSONDecoder().decode(HerdrPaneSurfaceFrame.self, from: Data(json.utf8))
    }

    static func patch(base: UInt64, rows: [HerdrPatchRow], panes: [String]) throws -> HerdrPaneSurfacePatch {
        try HerdrPresentationTests.patch(base: base, rows: rows, panes: panes)
    }
}

/// The engine's updates, read in order through the stream's one iterator.
@MainActor
private final class UpdateLog {
    private var iterator: AsyncStream<HerdrEngineUpdate>.AsyncIterator

    init(_ engine: HerdrTerminalEngine) {
        iterator = engine.updates.makeAsyncIterator()
    }

    func next() async throws -> HerdrEngineUpdate {
        guard let update = await nextOrEnd() else { throw UpdateLogError.finished }
        return update
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
