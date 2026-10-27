import Combine
import GhosttyKit
import UIKit
import XCTest
@testable import Remux

/// `HerdrScreenModel` over scripted bridges, with a real connection, engine and Ghostty renderers.
@MainActor
final class HerdrScreenModelTests: XCTestCase {
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

    private func makeHarness(
        settings: TerminalSettings = .default,
        timing: HerdrConnection.Timing = HerdrConnection.Timing(),
        recovery: HerdrScreenModel.RecoveryTiming = HerdrScreenModel.RecoveryTiming(),
        failingOpenWith error: Error? = nil,
        bridgeOpeningTakes: Duration = .zero,
        producerFailure: ProducerFailure? = nil,
        rendererFenceGate: RendererFenceGate? = nil
    ) async -> HerdrModelHarness {
        let harness = await HerdrModelHarness(
            settings: settings,
            timing: timing,
            recovery: recovery,
            failingOpenWith: error,
            bridgeOpeningTakes: bridgeOpeningTakes,
            producerFailure: producerFailure,
            rendererFenceGate: rendererFenceGate
        )
        harnesses.append(harness)
        return harness
    }

    // MARK: - Opening

    /// The bridge opens with the session; the hello waits for the screen's size and asks for the
    /// session hidden.
    func testTheBridgeOpensAtOnceAndTheHelloWaitsForTheScreensSize() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        try await Task.sleep(for: .milliseconds(100))
        let earlyWrites = await bridge.writtenCount
        XCTAssertEqual(earlyWrites, 0)

        harness.setScreenSize()
        let hello = try await harness.writes(bridge, count: 1)
        let measurement = try XCTUnwrap(harness.model.measurement)
        XCTAssertEqual(hello, [.hello(
            cols: Int(measurement.controlViewport.columns),
            rows: Int(measurement.controlViewport.rows),
            cellWidth: Int(measurement.cellMetrics.pixelWidth),
            cellHeight: Int(measurement.cellMetrics.pixelHeight),
            surfaceActive: false
        )])
        let opened = await harness.bridges.opened.count
        let closed = await bridge.isClosed
        XCTAssertEqual(opened, 1, "a size in time needs no second bridge")
        XCTAssertFalse(closed)
    }

    /// Herdr's server drops a connection that sends no hello within 4 s of the bridge reaching it, which
    /// can be well before a slow opening returns. A bridge still waiting for the screen's size is closed
    /// within 4 s of its opening's start, keeping its SSH connection for reuse, and a new one opens once
    /// the size arrives; the hello goes on it.
    func testABridgeWaitingTooLongForTheSizeIsClosedAndOpenedAgain() async throws {
        let beforeOpening = ContinuousClock.now
        let harness = await makeHarness(bridgeOpeningTakes: .milliseconds(1500))
        let first = try await harness.bridge(0)
        let openingStarts = await harness.bridges.openingsStartedAt
        let openingStarted = try XCTUnwrap(openingStarts.first)

        try await harness.waitUntil("the waiting bridge wasn't closed", timeout: .seconds(5)) { await first.isClosed }
        let closedAt = ContinuousClock.now
        XCTAssertLessThan(closedAt - openingStarted, .seconds(4), "closed after Herdr's server would have given up")
        XCTAssertGreaterThanOrEqual(closedAt - beforeOpening, HerdrScreenModel.helloDeadline)
        let reusable = await first.closedReusable
        let firstWrites = await first.writtenCount
        XCTAssertEqual(reusable, true)
        XCTAssertEqual(firstWrites, 0)
        XCTAssertFalse(harness.states.contains { $0.disconnectedReason != nil }, "\(harness.states)")

        harness.setScreenSize()
        let second = try await harness.bridge(1)
        let hello = try await harness.writes(second, count: 1)
        guard case .hello(_, _, _, _, false) = hello[0] else { return XCTFail("expected the hello, got \(hello)") }
    }

    /// The phone's theme goes out right after the hello, before any show, as Herdr's client reports its
    /// terminal: light or dark, then the Ghostty colours. It goes out again in full when the theme
    /// changes.
    func testTheThemeIsReportedBeforeTheFirstShowAndAgainWhenItChanges() async throws {
        let harness = await makeHarness(settings: TerminalSettings(fontSize: nil, theme: .remuxDark))
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.setScreenSize()
        harness.model.setSelected(true)

        let writes = try await harness.writes(bridge, count: 8)
        XCTAssertEqual(writes[1], .theme(.appearance(.dark)))
        XCTAssertEqual(writes[2], .theme(.defaultColor(.foreground, HerdrRGB(red: 0xCD, green: 0xD6, blue: 0xF4))))
        XCTAssertEqual(writes[3], .theme(.defaultColor(.background, HerdrRGB(red: 0x1E, green: 0x1E, blue: 0x2E))))
        guard case .theme(.paletteColors(let palette)) = writes[4] else {
            return XCTFail("expected the palette, got \(writes[4])")
        }
        XCTAssertEqual(palette.count, 256)
        XCTAssertEqual(palette[1], HerdrRGB(red: 0xF3, green: 0x8B, blue: 0xA8))
        // Ghostty's own colour cube above the 16 the theme sets.
        XCTAssertEqual(palette[196], HerdrRGB(red: 0xFF, green: 0x00, blue: 0x00))
        XCTAssertTrue(writes[5...].contains { $0.isSurfaceSet }, "\(writes)")

        try harness.model.applyTerminalSettings(TerminalSettings(fontSize: nil, theme: .remuxLight))
        let changed = try await harness.writes(bridge, from: 8, count: 4)
        XCTAssertEqual(changed[0], .theme(.appearance(.light)))
        XCTAssertEqual(changed[1], .theme(.defaultColor(.foreground, HerdrRGB(red: 0x4C, green: 0x4F, blue: 0x69))))
        XCTAssertEqual(changed[2], .theme(.defaultColor(.background, HerdrRGB(red: 0xEF, green: 0xF1, blue: 0xF5))))
        guard case .theme(.paletteColors) = changed[3] else { return XCTFail("expected the palette, got \(changed[3])") }
    }

    // MARK: - Showing

    /// Connected hidden, the session is shown once the root selects it and a snapshot is in, and hidden
    /// in the background: focus with the show, focus off before the hide.
    func testShowsOnceSelectedAndHidesInTheBackground() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome())
        harness.setScreenSize()
        harness.model.setSelected(true)
        _ = try await harness.writes(bridge, count: 5)
        try await Task.sleep(for: .milliseconds(100))
        let beforeSnapshot = await bridge.writtenCount
        XCTAssertEqual(beforeSnapshot, 5, "nothing is shown before a snapshot")

        await bridge.serve(HerdrServerScript.snapshot(revision: 1))
        let show = try await harness.writes(bridge, from: 5, count: 3)
        guard case .resize = show[0], case .surfaceSet(let showID, true) = show[1] else {
            return XCTFail("expected a show, got \(show)")
        }
        XCTAssertEqual(show[2], .focus(true))
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: showID, active: true))

        harness.model.handleAppLifecyclePhase(.inactive)
        try await Task.sleep(for: .milliseconds(100))
        let afterInactive = await bridge.writtenCount
        XCTAssertEqual(afterInactive, 8, "an inactive app stays shown")

        harness.model.handleAppLifecyclePhase(.background)
        let hide = try await harness.writes(bridge, from: 8, count: 2)
        XCTAssertEqual(hide[0], .focus(false))
        guard case .surfaceSet(_, false) = hide[1] else { return XCTFail("expected a hide, got \(hide)") }
    }

    /// Herdr takes the newest of a show and a hide: a hide goes out while the show is unanswered, and
    /// the show that follows it too.
    func testEachVisibilityChangeGoesOutAtOnceInOrder() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let first = try await harness.nextSurfaceSet(bridge, from: &index)
        harness.model.setSelected(false)
        harness.model.setSelected(true)

        let second = try await harness.nextSurfaceSet(bridge, from: &index)
        let third = try await harness.nextSurfaceSet(bridge, from: &index)
        XCTAssertEqual([first.active, second.active, third.active], [true, false, true])
        for request in [first, second, third] {
            await bridge.serve(HerdrServerScript.surfaceSetReply(id: request.id, active: request.active))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(harness.states.contains { $0.disconnectedReason != nil }, "\(harness.states)")
    }

    /// Calls made together reach Herdr in the order they were made, each in full before the next: a
    /// resize, a theme change, a hide, a show, and the background's hide.
    func testABurstOfCallsReachesHerdrInTheOrderTheyWereMade() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.setScreenSize()
        let model = harness.model
        model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        index += 1

        model.terminalScreenAdapter.prepareInitialViewport(size: CGSize(width: 390, height: 500), scale: 3)
        try model.applyTerminalSettings(TerminalSettings(fontSize: nil, theme: .remuxLight))
        model.setSelected(false)
        model.setSelected(true)
        model.handleAppLifecyclePhase(.background)

        let measurement = try XCTUnwrap(model.measurement)
        let resize = ClientWrite.resize(
            cols: measurement.controlViewport.columns,
            rows: measurement.controlViewport.rows,
            cellWidth: measurement.cellMetrics.pixelWidth,
            cellHeight: measurement.cellMetrics.pixelHeight
        )
        let burst = try await harness.writes(bridge, from: index, count: 12)
        XCTAssertEqual(burst[0], resize)
        XCTAssertEqual(burst[1], .theme(.appearance(.light)))
        guard case .theme(.defaultColor(.foreground, _)) = burst[2],
              case .theme(.defaultColor(.background, _)) = burst[3],
              case .theme(.paletteColors) = burst[4],
              case .surfaceSet(_, false) = burst[6],
              case .surfaceSet(_, true) = burst[8],
              case .surfaceSet(_, false) = burst[11]
        else { return XCTFail("out of order: \(burst)") }
        XCTAssertEqual(burst[5], .focus(false))
        XCTAssertEqual(burst[7], resize)
        XCTAssertEqual(burst[9], .focus(true))
        XCTAssertEqual(burst[10], .focus(false))
        try await Task.sleep(for: .milliseconds(100))
        let written = await bridge.writtenCount
        XCTAssertEqual(written, index + 12)
    }

    /// A show Herdr doesn't answer ends the connection, and the session reconnects by itself. The path
    /// may be dead, so the reconnect doesn't get the same SSH connection, which it would wait on.
    func testAShowHerdrDoesNotAnswerEndsTheConnection() async throws {
        var timing = HerdrConnection.Timing()
        timing.activation = .milliseconds(200)
        let harness = await makeHarness(timing: timing)
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.setScreenSize()
        harness.model.setSelected(true)

        try await harness.waitUntil("the failed show didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }
        try await harness.waitUntil("the connection wasn't closed") { await bridge.isClosed }
        let reusable = await bridge.closedReusable
        XCTAssertEqual(reusable, false)
        _ = try await harness.bridge(1)
        XCTAssertFalse(harness.states.contains { $0.disconnectedReason != nil }, "\(harness.states)")
    }

    /// Shown again, the session keeps its last frame and reads as connected, but takes no input until
    /// the show completes: Herdr's answer alone doesn't, a frame Herdr sends after it does, as Herdr's
    /// client freezes input while a show is in progress.
    func testAShownAgainSessionTakesInputOnlyOnceTheShowCompletes() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter

        harness.model.setSelected(false)
        harness.model.setSelected(true)
        let hide = try await harness.nextSurfaceSet(session.bridge, from: &index)
        let show = try await harness.nextSurfaceSet(session.bridge, from: &index)
        XCTAssertEqual([hide.active, show.active], [false, true])
        XCTAssertEqual(harness.model.presentation(ofPane: "w1:p1"), .ready, "the last frame left the screen")
        XCTAssertEqual(harness.states.last, .connected)
        XCTAssertFalse(adapter.terminalInteractionProjection.isInputAvailable)
        XCTAssertEqual(adapter.sendInputToFocusedSurface("x"), .transportUnavailable)

        await session.bridge.serve(HerdrServerScript.surfaceSetReply(id: hide.id, active: false))
        await session.bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(harness.model.isInputAvailable, "Herdr's answer completed the show without a frame")

        await session.bridge.serve(try harness.shownSurface(
            projection: 1,
            revision: 3,
            lines: ["one two"],
            panes: [
                .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
                .init(id: "w1:p2", x: 4, width: 3, height: 1),
            ]
        ))
        try await harness.waitUntil("input wasn't offered once the show's frame came") {
            adapter.terminalInteractionProjection.isInputAvailable
        }
        XCTAssertEqual(harness.states.last, .connected)
    }

    /// A show Herdr answers without sending a frame in time is rolled back: the connection ends and the
    /// session reconnects, as for a show Herdr doesn't answer.
    func testAShowWithoutAFrameInTimeEndsTheConnection() async throws {
        var timing = HerdrConnection.Timing()
        timing.activation = .milliseconds(300)
        let harness = await makeHarness(timing: timing)
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))

        try await harness.waitUntil("the show that didn't complete wasn't rolled back") {
            harness.states.last == .reconnecting(.transportLoss)
        }
        try await harness.waitUntil("the connection wasn't closed") { await bridge.isClosed }
        _ = try await harness.bridge(1)
        XCTAssertFalse(harness.states.contains { $0.disconnectedReason != nil }, "\(harness.states)")
    }

    // MARK: - Panes

    /// Each pane with a text area gets a renderer showing its cells; the tab is the screen's one
    /// top-level, named by the snapshot.
    func testPanesAreRenderedAndTheTabIsTheTopLevel() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, tabLabel: "build"))
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["left 1  | right 1", "left 2  | right 2"],
            panes: [
                .init(id: "w1:p1", x: 0, width: 8, height: 2, focused: true),
                .init(id: "w1:p2", x: 10, width: 7, height: 2),
            ]
        ))
        harness.setScreenSize()

        try await harness.waitUntil("renderers weren't created") {
            harness.model.paneSurface("w1:p1") != nil && harness.model.paneSurface("w1:p2") != nil
        }
        XCTAssertEqual(harness.shownRows(), ["w1:p1": ["left 1", "left 2"], "w1:p2": ["right 1", "right 2"]])

        let adapter = harness.model.terminalScreenAdapter
        let projection = adapter.terminalScreenPresentationProjection
        XCTAssertEqual(adapter.windowSelectionSheetRenderProjection().windows.map(\.displayName), ["build"])
        XCTAssertEqual(projection.viewport.windowGrid, GhosttyTerminalGridSize(columns: 17, rows: 2))
        XCTAssertEqual(projection.viewport.panes.map(\.normalFrame), [
            GhosttyTerminalGridRect(x: 0, y: 0, columns: 8, rows: 2),
            GhosttyTerminalGridRect(x: 10, y: 0, columns: 7, rows: 2),
        ])
        let focused = try XCTUnwrap(projection.viewport.panes.first(where: \.isFocused))
        XCTAssertEqual(projection.viewport.focusedSurfaceID, focused.id)
        let managed = try XCTUnwrap(adapter.terminalManagedSurfaceLookup.managedSurface(for: focused.id))
        XCTAssertTrue(managed.view === harness.model.paneSurface("w1:p1")?.renderer.view)
        XCTAssertEqual(adapter.topLevelNoun, .tab)
    }

    /// The pane sheet shows, as for a tmux pane, the folder of the pane's foreground program, and names
    /// each pane as Herdr's pane navigator does within a tab: its manual label or agent's name, else
    /// its title, else its agent's kind, else "terminal", numbered by its place among the tab's panes
    /// in the snapshot when the tab has more than one.
    func testPanesAreNamedAsHerdrsPaneNavigatorListsThem() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        let snapshot = HerdrServerScript.snapshot(
            revision: 1,
            panes: [
                HerdrServerScript.snapshotPane("w1:p1", label: "editor", cwd: "/repo", foregroundCWD: "/repo/src"),
                HerdrServerScript.snapshotPane("w1:p2", cwd: "/home"),
                HerdrServerScript.snapshotPane("w1:q1", tab: "t2"),
                HerdrServerScript.snapshotPane("w1:p3", cwd: "/srv", foregroundCWD: "/srv/app"),
                HerdrServerScript.snapshotPane("w1:p4"),
                HerdrServerScript.snapshotPane("w1:p5"),
                HerdrServerScript.snapshotPane("w1:p6"),
            ],
            agents: [
                HerdrServerScript.snapshotAgent("w1:p1", name: "fixer", title: "Fixing tests", agent: "claude"),
                HerdrServerScript.snapshotAgent("w1:p2", name: "reviewer", title: "Reviewing", agent: "codex"),
                HerdrServerScript.snapshotAgent(
                    "w1:p3", title: "Fixing tests", terminalTitleStripped: "claude", displayAgent: "Claude Code"
                ),
                HerdrServerScript.snapshotAgent("w1:p4", terminalTitleStripped: "vim notes.md"),
                HerdrServerScript.snapshotAgent("w1:p5", agent: "codex", displayAgent: "Codex"),
            ]
        )
        await bridge.serve(try HerdrServerScript.welcome() + snapshot)
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["a b c d e f"],
            panes: (0..<6).map { .init(id: "w1:p\($0 + 1)", x: UInt16($0 * 2), width: 1, height: 1, focused: $0 == 0) }
        ))
        harness.setScreenSize()

        let adapter = harness.model.terminalScreenAdapter
        try await harness.waitUntil("the panes weren't laid out") {
            adapter.terminalScreenPresentationProjection.viewport.panes.count == 6
        }
        var panes = adapter.terminalScreenPresentationProjection.viewport.panes
        XCTAssertEqual(panes.map(\.currentCommand), [
            "editor · 1", "reviewer · 2", "Fixing tests · 3", "vim notes.md · 4", "codex · 5", "terminal · 6",
        ])
        XCTAssertEqual(panes.map(\.currentPath), ["/repo/src", "/home", "/srv/app", "", "", ""])

        // A tab's only pane has no number.
        await bridge.serve(HerdrServerScript.snapshot(
            revision: 2,
            panes: [HerdrServerScript.snapshotPane("w1:p6"), HerdrServerScript.snapshotPane("w1:q1", tab: "t2")]
        ))
        await bridge.serve(HerdrServerScript.surface(
            projection: 2,
            revision: 2,
            lines: ["a"],
            panes: [.init(id: "w1:p6", x: 0, width: 1, height: 1, focused: true)]
        ))
        try await harness.waitUntil("the tab's only pane wasn't laid out") {
            adapter.terminalScreenPresentationProjection.viewport.panes.count == 1
        }
        panes = adapter.terminalScreenPresentationProjection.viewport.panes
        XCTAssertEqual(panes.map(\.currentCommand), ["terminal"])
    }

    /// A frame left behind by a lost connection shows no live cursor: the focused pane is unfocused
    /// while the session reconnects, as Herdr's client hides its cursor while its session is offline,
    /// and focused again once the new connection is open.
    func testThePaneIsUnfocusedWhileTheConnectionIsDown() async throws {
        let harness = await makeHarness()
        let first = try await harness.bridge(0)
        await first.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        let frame = HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["one"],
            panes: [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        )
        await first.serve(frame)
        harness.setScreenSize()
        harness.model.setSelected(true)
        let adapter = harness.model.terminalScreenAdapter
        try await harness.waitUntil("the pane's renderer wasn't created") {
            adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID != nil
        }
        let surfaceID = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)
        let managed = try XCTUnwrap(adapter.terminalManagedSurfaceLookup.managedSurface(for: surfaceID))
        try await harness.waitUntil("the pane wasn't focused while connected") { managed.isFocused }

        await first.finishServing()
        try await harness.waitUntil("the lost connection didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }
        XCTAssertFalse(managed.isFocused)

        let second = try await harness.bridge(1)
        XCTAssertFalse(managed.isFocused, "nothing is live before the new connection opens")
        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1) + frame)
        try await harness.waitUntil("the pane wasn't focused again") { managed.isFocused }
    }

    /// A size that only arrives after the hello deadline is too late, even while the bridge's opening is
    /// still under way: Herdr may already have dropped the bridge. It is closed, keeping its SSH
    /// connection, and another opens; the hello goes on that one.
    func testASizeArrivingAfterTheDeadlineDuringASlowOpeningOpensAnotherBridge() async throws {
        let harness = await makeHarness(bridgeOpeningTakes: .seconds(4))
        try await harness.waitUntil("the opening didn't start") {
            await harness.bridges.openingsStartedAt.count == 1
        }
        let openingStarts = await harness.bridges.openingsStartedAt
        let openingStarted = try XCTUnwrap(openingStarts.first)
        try await Task.sleep(until: openingStarted + .milliseconds(3400), clock: .continuous)
        harness.setScreenSize()

        let first = try await harness.bridge(0)
        let second = try await harness.bridge(1, timeout: .seconds(6))
        let hello = try await harness.writes(second, count: 1)
        guard case .hello = hello[0] else { return XCTFail("expected the hello, got \(hello)") }
        let firstWrites = await first.writtenCount
        let reusable = await first.closedReusable
        XCTAssertEqual(firstWrites, 0)
        XCTAssertEqual(reusable, true)
    }

    /// A size known before the bridge's opening started is in time however long the opening takes: the
    /// hello goes as soon as the bridge is open, and no other bridge opens.
    func testASizeKnownBeforeASlowOpeningIsInTime() async throws {
        let harness = await makeHarness(bridgeOpeningTakes: .milliseconds(3500))
        harness.setScreenSize()
        let first = try await harness.bridge(0, timeout: .seconds(6))
        _ = try await harness.writes(first, count: 1)

        harness.model.reconnect()
        let second = try await harness.bridge(1, timeout: .seconds(6))
        let hello = try await harness.writes(second, count: 1)
        guard case .hello = hello[0] else { return XCTFail("expected the hello, got \(hello)") }
        try await Task.sleep(for: .seconds(1))
        let opened = await harness.bridges.opened.count
        let closed = await second.isClosed
        XCTAssertEqual(opened, 2)
        XCTAssertFalse(closed)
    }

    /// Only the selected session's panes are presented and focused: deselecting hides them from Ghostty
    /// and takes their focus, and selecting the session again brings both back.
    func testOnlyTheSelectedSessionsPanesArePresentedAndFocused() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["one"],
            panes: [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        ))
        harness.setScreenSize()
        harness.model.setSelected(true)
        let adapter = harness.model.terminalScreenAdapter
        try await harness.waitUntil("the pane's renderer wasn't created") {
            adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID != nil
        }
        let surfaceID = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)
        let managed = try XCTUnwrap(adapter.terminalManagedSurfaceLookup.managedSurface(for: surfaceID))
        try await harness.waitUntil("the selected pane wasn't presented and focused") {
            managed.isVisible && managed.isFocused
        }

        harness.model.setSelected(false)
        XCTAssertFalse(managed.isVisible)
        XCTAssertFalse(managed.isFocused)

        harness.model.setSelected(true)
        XCTAssertTrue(managed.isVisible)
        XCTAssertTrue(managed.isFocused)
    }

    /// Ghostty requires its app to outlive every surface, so a stop releases the runtime only once every
    /// renderer is freed: one closed because its pane left the layout, one whose creation lands after the
    /// stop began, and the one the stop closes itself.
    func testStopReleasesGhosttyOnlyOnceEveryRendererIsFreed() async throws {
        let gate = RendererFenceGate()
        let harness = await makeHarness(rendererFenceGate: gate)
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        let first = HerdrServerScript.Pane(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["one two"],
            panes: [first, .init(id: "w1:p2", x: 4, width: 3, height: 1)]
        ))
        harness.setScreenSize()
        let model = harness.model
        try await harness.waitUntil("the panes' renderers weren't created") {
            model.paneSurface("w1:p1") != nil && model.paneSurface("w1:p2") != nil
        }

        gate.holdsCloses = true
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 2,
            lines: ["one two"],
            panes: [first]
        ))
        try await harness.waitUntil("the pane that left wasn't closed") {
            model.paneSurface("w1:p2") == nil && gate.heldCloseCount == 1
        }
        gate.holdsRegistrations = true
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 3,
            lines: ["one six"],
            panes: [first, .init(id: "w1:p3", x: 4, width: 3, height: 1)]
        ))
        try await harness.waitUntil("the new pane's renderer wasn't being registered") {
            gate.heldRegistrationCount == 1
        }

        let stopped = Task { @MainActor in
            await model.stop()
            gate.record("stopped")
        }
        try await Task.sleep(for: .milliseconds(200))
        gate.releaseRegistrations()
        try await harness.waitUntil("the late renderer wasn't closed") { gate.heldCloseCount == 3 }
        // The stop's own close completes; the pane that left and the late renderer are still closing.
        gate.releaseCloses(of: "w1:p1")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(gate.log.contains("stopped"), "the stop returned with renderers still closing: \(gate.log)")
        gate.releaseCloses()
        await stopped.value
        XCTAssertEqual(gate.log.last, "stopped")
        XCTAssertEqual(Set(gate.log.dropLast()), ["closed w1:p1", "closed w1:p2", "closed w1:p3"])
    }

    /// A session ready on screen offers the keyboard: both of the screen's projections say input is
    /// available.
    func testAReadySessionOffersInput() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        let panes: [HerdrServerScript.Pane] = [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["one"], panes: panes))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 2, lines: ["one"], panes: panes))
        try await harness.waitUntil("the pane's renderer wasn't created") {
            harness.model.paneSurface("w1:p1") != nil
        }
        showInWindow(harness, panes: ["w1:p1"])

        try await harness.waitUntil("the session wasn't ready") { harness.states.last == .connected }
        try await harness.waitUntil("input wasn't offered") { harness.model.isInputAvailable }
        let adapter = harness.model.terminalScreenAdapter
        // The screen reads input availability from both projections.
        for interaction in [adapter.terminalInteractionProjection, adapter.terminalScreenPresentationProjection.interaction] {
            XCTAssertTrue(interaction.hasFocusedSurface)
            XCTAssertTrue(interaction.isInputAvailable)
        }
    }

    /// A pane's screen surface is made when its renderer is admitted, so the screen's lookups only read:
    /// it looks a surface up from inside that surface's own callbacks, such as a selection's.
    func testAPanesSurfaceIsMadeWhenItsRendererIsAdmittedSoLookupsOnlyRead() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["left 1"],
            panes: [.init(id: "w1:p1", x: 0, width: 6, height: 1, focused: true)]
        ))
        harness.setScreenSize()
        try await harness.waitUntil("the pane's renderer wasn't created") {
            harness.model.paneSurface("w1:p1") != nil
        }

        let adapter = harness.model.terminalScreenAdapter
        let managed = try XCTUnwrap(harness.model.paneSurface("w1:p1")?.renderer.managedSurface)
        let id = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)
        XCTAssertEqual(managed.id, id)
        let lookup = adapter.terminalManagedSurfaceLookup
        var callbacks = 0
        managed.onLocalSelectionGeometryChange = {
            callbacks += 1
            // Bounded, so a lookup that notifies fails here instead of overflowing the stack.
            if callbacks <= 3 { _ = lookup.managedSurface(for: id) }
        }
        managed.onScrollStateChange = { callbacks += 1 }

        XCTAssertTrue(lookup.managedSurface(for: id) === managed)
        XCTAssertEqual(callbacks, 0)
    }

    /// A session the root doesn't show draws nothing, so it reads as connected once its focused pane is
    /// live, without input. Showing it draws the pane and offers input.
    func testASessionThatIsNotShownIsConnectedBeforeItsPaneDraws() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["one"],
            panes: [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        ))
        harness.setScreenSize()
        try await harness.waitUntil("the pane's renderer wasn't created") {
            harness.model.paneSurface("w1:p1") != nil
        }
        showInWindow(harness, panes: ["w1:p1"])

        try await harness.waitUntil("the hidden session wasn't connected") { harness.states.last == .connected }
        XCTAssertEqual(harness.model.presentation(ofPane: "w1:p1"), .awaitingFrame)
        let adapter = harness.model.terminalScreenAdapter
        XCTAssertFalse(adapter.terminalInteractionProjection.isInputAvailable)

        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(
            projection: 1,
            revision: 2,
            lines: ["one"],
            panes: [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        ))
        try await harness.waitUntil("the shown pane didn't draw") {
            harness.model.presentation(ofPane: "w1:p1") == .ready
        }
        XCTAssertEqual(harness.states.last, .connected)
        try await harness.waitUntil("input wasn't offered once the show completed") {
            adapter.terminalInteractionProjection.isInputAvailable
        }
    }

    /// While shown, a new screen size goes to Herdr at once; a hidden session gets it with its show.
    func testAResizeIsSentWhileShown() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        index += 1

        harness.model.terminalScreenAdapter.prepareInitialViewport(size: CGSize(width: 390, height: 500), scale: 3)
        let measurement = try XCTUnwrap(harness.model.measurement)
        let resize = try await harness.writes(bridge, from: index, count: 1)
        XCTAssertEqual(resize, [.resize(
            cols: measurement.controlViewport.columns,
            rows: measurement.controlViewport.rows,
            cellWidth: measurement.cellMetrics.pixelWidth,
            cellHeight: measurement.cellMetrics.pixelHeight
        )])
    }

    /// Only the newest size goes out: sizes changing faster than the queue sends them replace the one
    /// waiting, while other calls keep their order.
    func testOnlyTheNewestOfSeveralQueuedSizesIsSent() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.setScreenSize()
        let model = harness.model
        model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        index += 1

        model.terminalScreenAdapter.prepareInitialViewport(size: CGSize(width: 390, height: 500), scale: 3)
        try model.applyTerminalSettings(TerminalSettings(fontSize: nil, theme: .remuxLight))
        model.terminalScreenAdapter.prepareInitialViewport(size: CGSize(width: 390, height: 600), scale: 3)
        model.terminalScreenAdapter.prepareInitialViewport(size: CGSize(width: 390, height: 700), scale: 3)
        let newest = try XCTUnwrap(model.measurement)

        let sent = try await harness.writes(bridge, from: index, count: 5)
        XCTAssertEqual(sent[0], .theme(.appearance(.light)))
        XCTAssertEqual(sent[4], .resize(
            cols: newest.controlViewport.columns,
            rows: newest.controlViewport.rows,
            cellWidth: newest.cellMetrics.pixelWidth,
            cellHeight: newest.cellMetrics.pixelHeight
        ))
        try await Task.sleep(for: .milliseconds(100))
        let written = await bridge.writtenCount
        XCTAssertEqual(written, index + 5, "the older sizes went out too")
    }

    // MARK: - Failures

    /// A grid Remux can't index ends the connection Remux-side; the model closes it, and a session that
    /// hasn't connected yet says why instead of reconnecting.
    func testAnUnindexableSurfaceClosesTheConnectionAndIsReported() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(50)
        let harness = await makeHarness(recovery: recovery)
        let bridge = try await harness.bridge()
        // Herdr's surfaces are checked before the snapshot they're drawn against.
        await bridge.serve(try HerdrServerScript.welcome())
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["abcd"],
            panes: [.init(id: "w1:p1", x: 2, width: 5, height: 1)]
        ))
        harness.setScreenSize()

        try await harness.waitUntil("the failure wasn't reported") {
            harness.states.last?.disconnectedReason != nil
        }
        let reason = try XCTUnwrap(harness.states.last?.disconnectedReason)
        XCTAssertEqual(reason.kind, .runtime)
        XCTAssertEqual(reason.message, HerdrWireError.invalidSurfaceUpdate("surface pane lies outside the frame").errorDescription)
        XCTAssertEqual(harness.stateLog.updates.last?.source, .runtime)
        try await harness.waitUntil("the connection wasn't closed") { await bridge.isClosed }
        try await Task.sleep(for: .milliseconds(300))
        let opened = await harness.bridges.opened.count
        XCTAssertEqual(opened, 1, "a session that never connected reconnected")
    }

    /// A connection that ends before its first snapshot is reported once, with its reason, also when it
    /// ends while `open` is still returning; the session doesn't reconnect by itself.
    func testAConnectionThatEndsIsReported() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(50)
        let harness = await makeHarness(recovery: recovery)
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome())
        await bridge.finishServing()
        harness.setScreenSize()

        try await harness.waitUntil("the end wasn't reported") {
            harness.states.last?.disconnectedReason != nil
        }
        XCTAssertEqual(
            harness.states.last,
            .disconnected(HerdrConnectionError.closed.terminalDisconnectReason(on: SavedServer(displayName: "Herdr Host", host: "herdr.example.test", username: "builder")))
        )
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.states.filter { $0.disconnectedReason != nil }.count, 1)
        let opened = await harness.bridges.opened.count
        XCTAssertEqual(opened, 1, "a session that never connected reconnected")
    }

    func testABridgeThatCannotStartIsReported() async throws {
        let harness = await makeHarness(failingOpenWith: HerdrBridgeError.program(.notFound))
        try await harness.waitUntil("the failure wasn't reported") {
            harness.states.last?.disconnectedReason != nil
        }
        XCTAssertEqual(
            harness.states.last,
            .disconnected(TerminalDisconnectReason(
                kind: .backendUnavailable(.herdr),
                message: "Remux couldn't find Herdr on this server. Install it, or set its path in Edit Server."
            ))
        )
    }

    /// The live bridge opens, then its first read reports Herdr missing: the session shows Herdr Unavailable,
    /// which doesn't reconnect on its own, not a lost connection.
    func testABridgeThatReportsHerdrMissingOnItsFirstReadIsHerdrUnavailable() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        harness.setScreenSize()
        await bridge.finishServing(throwing: HerdrBridgeError.program(.notFound))
        try await harness.waitUntil("the failure wasn't reported") {
            harness.states.last?.disconnectedReason != nil
        }
        let reason = try XCTUnwrap(harness.states.last?.disconnectedReason)
        XCTAssertEqual(reason, TerminalDisconnectReason(
            kind: .backendUnavailable(.herdr),
            message: "Remux couldn't find Herdr on this server. Install it, or set its path in Edit Server."
        ))
        XCTAssertFalse(reason.allowsAutomaticReconnect)
    }

    // MARK: - Stop and reconnect

    /// Stopped before the screen has a size: the bridge closes, no hello goes out, and nothing more is
    /// reported.
    func testStopBeforeTheScreenHasASizeClosesTheBridge() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        let reportsBeforeStop = harness.states.count
        await harness.model.stop()
        // The opening may still be returning the bridge when the stop comes; the stop waits for it.
        let closed = await bridge.isClosed
        let reusable = await bridge.closedReusable
        let written = await bridge.writtenCount
        XCTAssertTrue(closed)
        XCTAssertEqual(reusable, true)
        XCTAssertEqual(written, 0)
        harness.setScreenSize()
        XCTAssertEqual(harness.states.count, reportsBeforeStop)
    }

    /// Stopped while renderers are still being created: they're drained, every renderer is closed,
    /// and nothing is reported after the stop.
    func testStopWithRendererCreationsInFlight() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["abcd efgh"],
            panes: [.init(id: "w1:p1", x: 0, width: 4, height: 1), .init(id: "w1:p2", x: 5, width: 4, height: 1)]
        ))
        // Renderers are created as the panes are laid out and admitted later, through the engine: the
        // screen sees the panes before their renderers. Stop right then.
        let model = harness.model
        let adapter = model.terminalScreenAdapter
        var stopping: Task<Void, Never>?
        let watch = adapter.objectWillChange.sink { _ in
            MainActor.assumeIsolated {
                guard stopping == nil else { return }
                let panes = adapter.terminalScreenPresentationProjection.viewport.panes
                guard panes.count == 2,
                      panes.allSatisfy({ adapter.terminalManagedSurfaceLookup.managedSurface(for: $0.id) == nil })
                else { return }
                stopping = Task { await model.stop() }
            }
        }
        defer { watch.cancel() }
        harness.setScreenSize()
        try await harness.waitUntil("the panes weren't laid out") { stopping != nil }
        let reportsBeforeStop = harness.states.count
        await stopping?.value

        XCTAssertNil(harness.model.paneSurface("w1:p1"))
        XCTAssertNil(harness.model.paneSurface("w1:p2"))
        let closed = await bridge.isClosed
        XCTAssertTrue(closed)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(harness.states.count, reportsBeforeStop)
    }

    /// Pane failures say to reconnect, and a reconnect brings both kinds back: a pane Ghostty couldn't
    /// paint gets a new terminal and renderer from the new connection, and a failed renderer is
    /// replaced over its terminal.
    func testAReconnectPaintsAFailedPaneAgainAndReplacesAFailedRenderer() async throws {
        let producerFailure = ProducerFailure()
        let harness = await makeHarness(producerFailure: producerFailure)
        let model = harness.model
        let first = try await harness.bridge(0)
        let panes: [HerdrServerScript.Pane] = [
            .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
            .init(id: "w1:p2", x: 4, width: 3, height: 1),
        ]
        await first.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await first.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["one two"], panes: panes))
        harness.setScreenSize()
        try await harness.waitUntil("the first frame wasn't shown") {
            harness.shownRows() == ["w1:p1": ["one"], "w1:p2": ["two"]]
        }
        let failedTerminal = try XCTUnwrap(model.paneSurface("w1:p1")?.terminal)
        let failedRenderer = try XCTUnwrap(model.paneSurface("w1:p2")?.renderer)

        // Ghostty can't apply the first pane's next paint; the second pane's renderer fails.
        producerFailure.isOn = true
        await first.serve(HerdrServerScript.surface(projection: 1, revision: 2, lines: ["uno two"], panes: panes))
        try await harness.waitUntil("the first pane's paint didn't fail") {
            model.presentation(ofPane: "w1:p1") != .pending
        }
        producerFailure.isOn = false
        failedRenderer.reportRendererFailure()
        try await harness.waitUntil("the failures weren't shown") {
            model.presentation(ofPane: "w1:p1") != .pending && model.presentation(ofPane: "w1:p2") != .pending
        }
        guard case .failed = model.presentation(ofPane: "w1:p1"), case .failed = model.presentation(ofPane: "w1:p2") else {
            return XCTFail("expected both panes to fail")
        }

        model.reconnect()
        try await harness.waitUntil("the failed renderer wasn't replaced") {
            model.paneSurface("w1:p2").map { $0.renderer !== failedRenderer } == true
        }
        XCTAssertEqual(harness.shownRows()["w1:p2"], ["two"])
        XCTAssertEqual(model.presentation(ofPane: "w1:p2"), .pending)

        let second = try await harness.bridge(1)
        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await second.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["ONE TWO"], panes: panes))
        try await harness.waitUntil("the panes weren't painted again") {
            harness.shownRows() == ["w1:p1": ["ONE"], "w1:p2": ["TWO"]]
        }
        XCTAssertFalse(model.paneSurface("w1:p1")?.terminal === failedTerminal)
        XCTAssertEqual(model.presentation(ofPane: "w1:p1"), .pending)
    }

    // MARK: - Reconnecting by itself

    /// A session that has connected reconnects by itself when its connection drops, shown or hidden, as
    /// Herdr's client retries every endpoint: it reads as reconnecting with its last frame, each failure
    /// in a row doubles the delay up to the longest, and the next connection brings it back.
    func testADroppedConnectionReconnectsByItselfWithGrowingDelays() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(200)
        recovery.longestRetry = .milliseconds(400)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])

        var droppedAt = ContinuousClock.now
        await first.finishServing()
        try await harness.waitUntil("the drop didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }
        XCTAssertEqual(harness.shownRows(), ["w1:p1": ["one"]])
        var delays: [Duration] = []
        for index in 1...3 {
            let bridge = try await harness.bridge(index)
            let starts = await harness.bridges.openingsStartedAt
            delays.append(starts[index] - droppedAt)
            droppedAt = ContinuousClock.now
            await bridge.finishServing()
        }
        XCTAssertGreaterThanOrEqual(delays[0], .milliseconds(200))
        XCTAssertGreaterThanOrEqual(delays[1], .milliseconds(400))
        XCTAssertGreaterThanOrEqual(delays[2], .milliseconds(400))
        XCTAssertLessThan(delays[2], .milliseconds(800), "the delay grew past the longest")

        let last = try await harness.bridge(4)
        await last.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await last.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["two"], panes: Self.onePane))
        try await harness.waitUntil("the session didn't come back") {
            harness.shownRows() == ["w1:p1": ["two"]] && harness.model.stateTraceLabel == "hidden"
        }
        XCTAssertFalse(harness.states.contains { $0.disconnectedReason != nil }, "\(harness.states)")
    }

    /// Delays start over once a connection has stayed up a while, as in Herdr's client: a drop after
    /// that waits the first delay again, not the one the earlier failures had reached.
    func testDelaysStartOverOnceAConnectionStaysUp() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(300)
        recovery.stable = .milliseconds(300)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])
        await first.finishServing()
        let second = try await harness.bridge(1)
        await second.finishServing()

        let third = try await harness.bridge(2)
        await third.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        try await harness.waitUntil("the session didn't come back") { harness.model.stateTraceLabel == "hidden" }
        try await Task.sleep(for: .milliseconds(600))
        let droppedAt = ContinuousClock.now
        await third.finishServing()

        _ = try await harness.bridge(3)
        let starts = await harness.bridges.openingsStartedAt
        XCTAssertGreaterThanOrEqual(starts[3] - droppedAt, .milliseconds(300))
        XCTAssertLessThan(starts[3] - droppedAt, .milliseconds(1000), "the delays didn't start over")
    }

    /// Herdr's bridge exits by itself after a minute with nothing to carry, as it does while the app is
    /// in the background, with status 1 and nothing after the ready marker. Once the connection is open
    /// that is a drop: the session reconnects by itself, as Herdr's client does.
    func testABridgeThatExitsAfterTheConnectionOpenedReconnects() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(50)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])

        await first.finishServing(throwing: HerdrBridgeError.program(.failed("")))
        try await harness.waitUntil("the bridge's exit didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }
        _ = try await harness.bridge(1)
        XCTAssertFalse(harness.states.contains { $0.disconnectedReason != nil }, "\(harness.states)")
    }

    /// A server whose snapshot Remux can't read needs attention: the session says why, keeps saying it
    /// while the server is checked again every so often, and is back once a connection works.
    func testAServerThatNeedsAttentionSaysWhyAndIsCheckedAgain() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.recheck = .milliseconds(300)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])

        await first.serve(Self.unreadableSnapshot())
        try await harness.waitUntil("the reason wasn't shown") { harness.states.last?.disconnectedReason != nil }
        let reason = try XCTUnwrap(harness.states.last?.disconnectedReason)
        XCTAssertEqual(
            reason,
            HerdrConnectionError.wire(.invalidControl(kind: HerdrControlKind.snapshot)).terminalDisconnectReason(on: SavedServer(displayName: "Herdr Host", host: "herdr.example.test", username: "builder"))
        )

        let second = try await harness.bridge(1)
        XCTAssertEqual(harness.states.last?.disconnectedReason, reason, "the reason went away before the server was back")
        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        try await harness.waitUntil("the session didn't come back") {
            harness.model.stateTraceLabel == "hidden" && harness.states.last?.disconnectedReason == nil
        }
    }

    /// In the background a waiting reconnect stops, keeping its time; back in the foreground, one that
    /// came due meanwhile runs at once.
    func testTheBackgroundHoldsAReconnectAndTheForegroundRunsItAtOnce() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(500)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])
        await first.finishServing()
        try await harness.waitUntil("the drop didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }

        harness.model.handleAppLifecyclePhase(.background)
        try await Task.sleep(for: .milliseconds(800))
        let openedInTheBackground = await harness.bridges.opened.count
        XCTAssertEqual(openedInTheBackground, 1)

        let foregroundAt = ContinuousClock.now
        harness.model.handleAppLifecyclePhase(.active)
        _ = try await harness.bridge(1)
        let starts = await harness.bridges.openingsStartedAt
        XCTAssertLessThan(starts[1] - foregroundAt, .milliseconds(400), "the due reconnect waited")
    }

    /// Back in the foreground a waiting reconnect runs at once even before it is due, as Herdr's client
    /// does after a resume.
    func testTheForegroundRunsAWaitingReconnectBeforeItIsDue() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .seconds(30)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])
        await first.finishServing()
        try await harness.waitUntil("the drop didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }

        harness.model.handleAppLifecyclePhase(.background)
        try await Task.sleep(for: .milliseconds(100))
        let foregroundAt = ContinuousClock.now
        harness.model.handleAppLifecyclePhase(.active)
        _ = try await harness.bridge(1)
        let starts = await harness.bridges.openingsStartedAt
        XCTAssertLessThan(starts[1] - foregroundAt, .milliseconds(400), "the reconnect waited for its delay")
    }

    /// Time in the background doesn't count as a connection staying up, as in Herdr's client: a drop
    /// soon after coming back keeps the delay the failures before had reached.
    func testTimeInTheBackgroundDoesNotCountAsStayingUp() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(200)
        recovery.stable = .milliseconds(300)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])
        await first.finishServing()
        let second = try await harness.bridge(1)
        await second.finishServing()

        let third = try await harness.bridge(2)
        await third.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        try await harness.waitUntil("the session didn't come back") { harness.model.stateTraceLabel == "hidden" }
        harness.model.handleAppLifecyclePhase(.background)
        try await Task.sleep(for: .milliseconds(600))
        harness.model.handleAppLifecyclePhase(.active)
        let droppedAt = ContinuousClock.now
        await third.finishServing()

        _ = try await harness.bridge(3)
        let starts = await harness.bridges.openingsStartedAt
        XCTAssertGreaterThanOrEqual(starts[3] - droppedAt, .milliseconds(700), "the background counted as staying up")
    }

    /// Going to the background gives up a reconnect still opening, as Herdr's client does; the
    /// foreground opens it again at once.
    func testTheBackgroundGivesUpAReconnectStillOpening() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(50)
        let harness = await makeHarness(recovery: recovery, bridgeOpeningTakes: .milliseconds(500))
        let first = try await connectedSession(harness, lines: ["one"])
        await first.finishServing()
        try await harness.waitUntil("the reconnect didn't start opening") {
            await harness.bridges.openingsStartedAt.count == 2
        }

        harness.model.handleAppLifecyclePhase(.background)
        try await Task.sleep(for: .milliseconds(800))
        let openedInTheBackground = await harness.bridges.opened.count
        let openingsInTheBackground = await harness.bridges.openingsStartedAt.count
        XCTAssertEqual(openedInTheBackground, 1, "the opening wasn't given up")
        XCTAssertEqual(openingsInTheBackground, 2)

        let foregroundAt = ContinuousClock.now
        harness.model.handleAppLifecyclePhase(.active)
        try await harness.waitUntil("the foreground didn't open it again") {
            await harness.bridges.openingsStartedAt.count == 3
        }
        let starts = await harness.bridges.openingsStartedAt
        XCTAssertLessThan(starts[2] - foregroundAt, .milliseconds(400), "the reconnect waited")
        XCTAssertFalse(harness.states.contains { $0.disconnectedReason != nil }, "\(harness.states)")
    }

    /// Going to the background while a connection waits for Herdr's welcome gives it up without offering
    /// its SSH connection to the next one: whether that path still works is unknown.
    func testTheBackgroundGivesUpAnOpeningWithoutReusingItsConnection() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge(0)
        harness.setScreenSize()
        _ = try await harness.writes(bridge, count: 1)

        harness.model.handleAppLifecyclePhase(.background)
        try await harness.waitUntil("the opening wasn't given up") { await bridge.isClosed }
        let reusable = await bridge.closedReusable
        XCTAssertEqual(reusable, false)
    }

    /// Back from the background, a connection that stayed open is shown again at once and checks itself
    /// with a ping meanwhile, as Herdr's client does after a resume: neither waits for the other.
    func testComingBackShowsTheSessionAtOnceAndPingsTheConnection() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        harness.model.handleAppLifecyclePhase(.background)
        let hide = try await harness.nextSurfaceSet(session.bridge, from: &index)
        XCTAssertFalse(hide.active)

        harness.model.handleAppLifecyclePhase(.active)
        var pinged = false
        var shown = false
        while !(pinged && shown) {
            let write = try ClientWrite.decode(try await session.bridge.written(index))
            index += 1
            if ping(write) != nil { pinged = true }
            if write.isSurfaceSet { shown = true }
        }
    }

    /// A connection that doesn't answer on the way back is gone: the session reconnects.
    func testComingBackReconnectsWhenTheConnectionDoesNotAnswer() async throws {
        var timing = HerdrConnection.Timing()
        timing.unansweredPing = .milliseconds(300)
        let harness = await makeHarness(timing: timing)
        let session = try await shownSession(harness)
        var index = session.next
        harness.model.handleAppLifecyclePhase(.background)
        _ = try await harness.nextSurfaceSet(session.bridge, from: &index)

        harness.model.handleAppLifecyclePhase(.active)
        try await harness.waitUntil("the silent connection didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }
        _ = try await harness.bridge(1)
    }

    /// A shown session that reconnects reads as reconnecting, and takes no input, until the new
    /// connection completes its show: until then the panes show the last connection's frame.
    func testAReconnectReadsAsReconnectingUntilTheNewConnectionIsShown() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(50)
        let harness = await makeHarness(recovery: recovery)
        let session = try await shownSession(harness)
        await session.bridge.finishServing()
        try await harness.waitUntil("the drop didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }

        let second = try await harness.bridge(1)
        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        var index = 0
        let show = try await harness.nextSurfaceSet(second, from: &index)
        XCTAssertTrue(show.active)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(harness.states.last, .reconnecting(.transportLoss), "\(harness.states)")
        XCTAssertFalse(harness.model.isInputAvailable)

        let panes: [HerdrServerScript.Pane] = [
            .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
            .init(id: "w1:p2", x: 4, width: 3, height: 1),
        ]
        await second.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await second.serve(try harness.shownSurface(projection: 1, revision: 2, lines: ["one two"], panes: panes))
        try await harness.waitUntil("the session didn't come back") { harness.states.last == .connected }
        XCTAssertTrue(harness.model.isInputAvailable)
    }

    /// A reconnect the user asks for also starts the delays over, as in Herdr's client: when it fails,
    /// the next try waits the first delay, not the one the failures before had reached.
    func testAReconnectTheUserAsksForStartsTheDelaysOver() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(100)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])
        await first.finishServing()
        for index in 1...3 {
            try await harness.bridge(index).finishServing()
        }
        // Four failures in a row: the next try would wait 0.8 s.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(harness.model.reconnect())
        let asked = try await harness.bridge(4)
        let failedAt = ContinuousClock.now
        await asked.finishServing()
        _ = try await harness.bridge(5)
        let starts = await harness.bridges.openingsStartedAt
        XCTAssertLessThan(starts[5] - failedAt, .milliseconds(500), "the delays didn't start over")
    }

    /// A reconnect the user asks for runs at once instead of waiting out the delay.
    func testAReconnectTheUserAsksForSkipsTheWait() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .seconds(30)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])
        await first.finishServing()
        try await harness.waitUntil("the drop didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }

        XCTAssertTrue(harness.model.reconnect())
        let second = try await harness.bridge(1)
        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        try await harness.waitUntil("the session didn't come back") { harness.model.stateTraceLabel == "hidden" }
    }

    private static let onePane: [HerdrServerScript.Pane] = [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]

    /// A hidden session on its first bridge, connected, its one pane painted with `lines`.
    private func connectedSession(_ harness: HerdrModelHarness, lines: [String]) async throws -> FakeBridgeTransport {
        let bridge = try await harness.bridge(0)
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: lines, panes: Self.onePane))
        harness.setScreenSize()
        try await harness.waitUntil("the session didn't connect") {
            harness.shownRows() == ["w1:p1": lines] && harness.model.stateTraceLabel == "hidden"
        }
        return bridge
    }

    /// A snapshot whose data Remux can't read.
    private static func unreadableSnapshot() -> [UInt8] {
        var writer = HerdrWireWriter()
        writer.variant(20)
        writer.string(HerdrControlKind.snapshot)
        writer.string("{}")
        return HerdrWire.frame(writer.bytes)
    }

    // MARK: - Input

    /// Typing, keys and a paste go to the snapshot's focused pane in the order they were typed. A key's
    /// release isn't sent.
    func testInputGoesToTheFocusedPaneInOrder() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        XCTAssertTrue(adapter.terminalInteractionProjection.isInputAvailable)

        XCTAssertEqual(adapter.sendInputToFocusedSurface("l\u{03}"), .accepted)
        XCTAssertEqual(adapter.sendKeyEventToFocusedSurface(GhosttySurfaceKeyEvent(keyCode: .enter)), .accepted)
        XCTAssertEqual(
            adapter.sendKeyEventToFocusedSurface(GhosttySurfaceKeyEvent(action: .release, keyCode: .enter)),
            .accepted
        )
        XCTAssertEqual(adapter.sendPasteToFocusedSurface("a\nb"), .accepted)

        var sent: [[UInt8]] = []
        for _ in 0..<3 {
            sent.append(try await nextWrite(session.bridge, from: &index, paneInput))
        }
        XCTAssertEqual(sent, [
            frame("w1:p1", [typed("l"), .key(HerdrKeyEvent(code: .character("c"), modifiers: .control, tracksRelease: true))]),
            frame("w1:p1", [.key(HerdrKeyEvent(code: .enter, tracksRelease: true))]),
            frame("w1:p1", [.paste("a\nb")]),
        ])
        try await Task.sleep(for: .milliseconds(100))
        let written = await session.bridge.writtenCount
        XCTAssertEqual(written, index, "the release was sent")
    }

    /// Input is offered only while the session is shown; typed while hidden, nothing is sent.
    func testInputIsOfferedOnlyWhileShown() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["one"],
            panes: [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        ))
        harness.setScreenSize()
        let adapter = harness.model.terminalScreenAdapter
        try await harness.waitUntil("the pane's renderer wasn't created") { harness.model.paneSurface("w1:p1") != nil }
        showInWindow(harness, panes: ["w1:p1"])
        XCTAssertFalse(adapter.terminalInteractionProjection.isInputAvailable)
        XCTAssertEqual(adapter.sendInputToFocusedSurface("x"), .transportUnavailable)

        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(
            projection: 1,
            revision: 2,
            lines: ["one"],
            panes: [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        ))
        try await harness.waitUntil("input wasn't offered once shown") {
            adapter.terminalInteractionProjection.isInputAvailable
        }

        harness.model.setSelected(false)
        XCTAssertFalse(adapter.terminalInteractionProjection.isInputAvailable)
        XCTAssertEqual(adapter.sendInputToFocusedSurface("x"), .transportUnavailable)
        let hide = try await harness.nextSurfaceSet(bridge, from: &index)
        XCTAssertFalse(hide.active)
        try await Task.sleep(for: .milliseconds(100))
        let written = await bridge.writtenCount
        XCTAssertEqual(written, index, "input typed while hidden was sent")
    }

    /// The snapshot's focused pane takes the keys and the highlight, as in Herdr's client, also while a
    /// frame still marks another pane; both follow the next snapshot.
    func testTheSnapshotsFocusedPaneTakesKeysAndTheHighlight() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness, focusedPane: "w1:p2")
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let panes = adapter.terminalScreenPresentationProjection.viewport.panes
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes.filter(\.isFocused).map(\.id), [panes[1].id])
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID, panes[1].id)

        XCTAssertEqual(adapter.sendInputToFocusedSurface("x"), .accepted)
        let first = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(first, frame("w1:p2", [typed("x")]))

        await session.bridge.serve(HerdrServerScript.snapshot(revision: 2, focusedPane: "w1:p1"))
        try await harness.waitUntil("the highlight didn't follow the snapshot") {
            adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID == panes[0].id
        }
        XCTAssertEqual(adapter.sendInputToFocusedSurface("y"), .accepted)
        let second = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(second, frame("w1:p1", [typed("y")]))
    }

    /// A tap on another pane asks Herdr to focus it, as Herdr's client does. Taps made before Herdr
    /// answers wait, and only the newest is sent; a tap on the focused pane sends nothing.
    func testATapAsksHerdrToFocusThePane() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let ids = adapter.terminalScreenPresentationProjection.viewport.panes.map(\.id)
        XCTAssertEqual(ids.count, 2)

        XCTAssertEqual(adapter.focusPane(ids[0]), .queued)
        XCTAssertEqual(adapter.focusPane(ids[1]), .queued)
        let first = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(first.paneID, "w1:p2")

        XCTAssertEqual(adapter.focusPane(ids[1]), .queued)
        XCTAssertEqual(adapter.focusPane(ids[0]), .queued)
        try await Task.sleep(for: .milliseconds(100))
        let waiting = await session.bridge.writtenCount
        XCTAssertEqual(waiting, index, "a tap was sent before Herdr answered the last one")

        await session.bridge.serve(HerdrConnectionTests.reply(id: first.id, json: #"{"type":"ok"}"#))
        let second = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(second.paneID, "w1:p1")
        await session.bridge.serve(HerdrConnectionTests.reply(id: second.id, json: #"{"type":"ok"}"#))
        try await Task.sleep(for: .milliseconds(100))
        let answered = await session.bridge.writtenCount
        XCTAssertEqual(answered, index, "an older waiting tap was sent")
    }

    /// As in Herdr's client, a tap Herdr answers as no longer applying, because the pane changed
    /// meanwhile, shows no notice. A refused tap does, but not again while the same refusal is on screen.
    /// Each tap goes out only once the one before it is answered, so a sent tap means its predecessor's
    /// answer was handled.
    func testAFocusFailureShowsANoticeOnlyWhenItMeansSomething() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let other = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.panes.map(\.id).last)

        XCTAssertEqual(adapter.focusPane(other), .queued)
        let stale = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(adapter.focusPane(other), .queued)
        await session.bridge.serve(HerdrConnectionTests.reply(id: stale.id, error: ("stale_target", "the pane moved")))
        let refused = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertNil(adapter.commandFailureEvent, "a tap on a pane that changed was reported")

        XCTAssertEqual(adapter.focusPane(other), .queued)
        await session.bridge.serve(HerdrConnectionTests.reply(id: refused.id, error: ("pane_not_found", "pane not found")))
        let repeated = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(adapter.commandFailureEvent?.message, "Herdr: select pane failed")
        let shown = adapter.commandFailureEvent?.token

        XCTAssertEqual(adapter.focusPane(other), .queued)
        await session.bridge.serve(HerdrConnectionTests.reply(id: repeated.id, error: ("pane_not_found", "pane not found")))
        let last = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(adapter.commandFailureEvent?.token, shown, "the same refusal was shown again while on screen")
        await session.bridge.serve(HerdrConnectionTests.reply(id: last.id, json: #"{"type":"ok"}"#))
    }

    /// A tap Herdr doesn't answer in time says so once; another timeout is shown only after a tap has
    /// worked, as Herdr's client clears its timeout notice on success.
    func testAFocusTimeoutIsShownOnceUntilAFocusWorks() async throws {
        var timing = HerdrConnection.Timing()
        timing.command = .milliseconds(200)
        let harness = await makeHarness(timing: timing)
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let other = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.panes.map(\.id).last)

        XCTAssertEqual(adapter.focusPane(other), .queued)
        _ = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(adapter.focusPane(other), .queued)
        _ = try await nextWrite(session.bridge, from: &index, paneFocus)
        let first = adapter.commandFailureEvent?.token
        XCTAssertNotNil(first, "the timeout wasn't shown")

        XCTAssertEqual(adapter.focusPane(other), .queued)
        let worked = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(adapter.commandFailureEvent?.token, first, "a second timeout was shown")
        XCTAssertEqual(adapter.focusPane(other), .queued)
        await session.bridge.serve(HerdrConnectionTests.reply(id: worked.id, json: #"{"type":"ok"}"#))
        _ = try await nextWrite(session.bridge, from: &index, paneFocus)
        try await harness.waitUntil("a timeout after a tap that worked wasn't shown") {
            adapter.commandFailureEvent?.token != first
        }
    }

    /// Once Herdr reports that the focused pane asks for every key, non-ASCII text goes to it as a commit.
    func testAReportAllPaneGetsNonASCIITextAsACommit() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter

        // The model takes events in wire order, so once it has the snapshot it has the keyboard mode.
        await session.bridge.serve(
            HerdrServerScript.keyboardReportAll(true) + HerdrServerScript.snapshot(revision: 2, focusedPane: "w1:p2")
        )
        try await harness.waitUntil("the snapshot wasn't taken") { harness.model.focusedPaneID == "w1:p2" }
        XCTAssertEqual(adapter.sendInputToFocusedSurface("日a"), .accepted)
        let sent = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(sent, frame("w1:p2", [.text("日"), typed("a")]))
    }

    /// A paste over Herdr's byte limit isn't sent, and input Herdr refuses shows Herdr's failure
    /// notice.
    func testInputThatCantGoThroughShowsAFailureNotice() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter

        let tooLarge = String(repeating: "a", count: HerdrConnection.maxInputBytes + 1)
        XCTAssertEqual(adapter.sendPasteToFocusedSurface(tooLarge), .surfaceRejected)
        XCTAssertEqual(adapter.commandFailureEvent?.message, "Herdr: input failed")
        let firstToken = adapter.commandFailureEvent?.token
        XCTAssertEqual(adapter.sendInputToFocusedSurface("x"), .accepted)
        let sent = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(sent, frame("w1:p1", [typed("x")]), "the oversized paste was sent")

        await session.bridge.serve(HerdrServerScript.inputRefused("Paste rejected"))
        try await harness.waitUntil("the refusal wasn't shown") { adapter.commandFailureEvent?.token != firstToken }
        XCTAssertEqual(adapter.commandFailureEvent?.message, "Herdr: input failed")
    }

    /// Herdr's refusal of input is shown for each new reason, but not again while the same refusal is on
    /// screen, as Herdr's client repeats a notice only once the last one is gone.
    func testARepeatedInputRefusalIsNotShownAgainWhileOnScreen() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let adapter = harness.model.terminalScreenAdapter

        await session.bridge.serve(HerdrServerScript.inputRefused("paste too large"))
        try await harness.waitUntil("the refusal wasn't shown") { adapter.commandFailureEvent != nil }
        let first = try XCTUnwrap(adapter.commandFailureEvent?.token)
        await session.bridge.serve(HerdrServerScript.inputRefused("paste too large"))
        await session.bridge.serve(HerdrServerScript.inputRefused("pane closed"))
        try await harness.waitUntil("the new reason wasn't shown") { adapter.commandFailureEvent?.token != first }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(adapter.commandFailureEvent?.token, first &+ 1, "the same refusal was shown again")
    }

    // MARK: - Zoom

    /// With "Zoom multipane windows" on, showing the session zooms the tab on screen on its focused pane,
    /// behind the show. Herdr says it made the zoom, so leaving the screen undoes it, while Herdr still
    /// takes commands from the phone: the unzoom, then focus off, then the hide.
    func testATabIsZoomedWhenShownAndUnzoomedWhenTheSessionLeaves() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness)
        var index = session.next
        let show = try await harness.writes(session.bridge, from: index - 2, count: 3)
        guard case .surfaceSet(_, true) = show[0], show[1] == .focus(true), case .paneZoom(let zoomID, "w1:p1", "on") = show[2]
        else { return XCTFail("the zoom didn't follow the show: \(show)") }
        index += 1
        let zoom = (id: zoomID, paneID: "w1:p1")
        try await zoomTab(harness, session.bridge, answering: zoom.id, changed: true)

        harness.model.setSelected(false)
        let leave = try await harness.writes(session.bridge, from: index, count: 3)
        guard case .paneZoom(_, "w1:p1", "off") = leave[0], case .surfaceSet(_, false) = leave[2] else {
            return XCTFail("the zoom wasn't undone before the hide: \(leave)")
        }
        XCTAssertEqual(leave[1], .focus(false))
    }

    /// The setting zooms only a tab with more than one pane, and only while it's on.
    func testOnlyAMultiPaneTabIsZoomedAndOnlyWithTheSetting() async throws {
        for (settings, panes) in [(TerminalSettings.default, ["w1:p1", "w1:p2"]), (Self.zooming, ["w1:p1"])] {
            let harness = await makeHarness(settings: settings)
            let session = try await shownTab(harness, panes: panes)
            try await Task.sleep(for: .milliseconds(150))
            let written = await session.bridge.writtenCount
            XCTAssertEqual(written, session.next, "\(panes.count) pane(s), setting \(settings.zoomMultipaneWindowsByDefault)")
        }
    }

    /// A tab zoomed already, by another client, stays zoomed when the session leaves: Herdr answers the
    /// show's zoom as no change, so the zoom isn't Remux's.
    func testAZoomRemuxDidNotMakeStaysWhenTheSessionLeaves() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomed: true)
        var index = session.next
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: zoom.id, changed: false, zoomed: true, panes: Self.zoomedPlaces)
        )
        try await waitForMap(harness)

        harness.model.setSelected(false)
        let leave = try await harness.writes(session.bridge, from: index, count: 2)
        XCTAssertEqual(leave[0], .focus(false), "\(leave)")
        guard case .surfaceSet(_, false) = leave[1] else { return XCTFail("expected the hide, got \(leave)") }
    }

    /// Leaving while a command is in flight hides at once and leaves the zoom: Herdr would refuse an
    /// unzoom while the command runs, and one that waited would hold the hide back.
    func testLeavingWhileACommandIsInFlightHidesAtOnceAndLeavesTheZoom() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness)
        var index = session.next
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        try await zoomTab(harness, session.bridge, answering: zoom.id, changed: true)
        let adapter = harness.model.terminalScreenAdapter
        let other = try XCTUnwrap(adapter.paneSelectionSheetRenderProjection(topLevelID: try topLevel(harness)).panes.last)
        XCTAssertEqual(adapter.focusPane(other.id), .queued)
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p2")

        harness.model.setSelected(false)
        let leave = try await harness.writes(session.bridge, from: index, count: 2)
        XCTAssertEqual(leave[0], .focus(false), "\(leave)")
        guard case .surfaceSet(_, false) = leave[1] else { return XCTFail("expected the hide, got \(leave)") }
        try await Task.sleep(for: .milliseconds(100))
        let written = await session.bridge.writtenCount
        XCTAssertEqual(written, index + 2, "an unzoom went out behind the hide")
    }

    /// A zoom that ended without Remux, as when someone unzooms the tab or splits a pane, isn't undone.
    func testAZoomThatEndedElsewhereIsNotUndone() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness)
        var index = session.next
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        try await zoomTab(harness, session.bridge, answering: zoom.id, changed: true)

        await session.bridge.serve(HerdrServerScript.snapshot(revision: 3, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["one two"], panes: Self.twoPanes))
        try await harness.waitUntil("the tab didn't read as unzoomed") { (try? isZoomed(harness)) == false }

        harness.model.setSelected(false)
        let leave = try await harness.writes(session.bridge, from: index, count: 1)
        XCTAssertEqual(leave[0], .focus(false), "the zoom was undone")
    }

    /// While the tab is zoomed, a tap moves the focus to another pane, which Herdr then shows zoomed; the
    /// unzoom goes on the pane focused then, since an unzoom focuses its target.
    func testTheUnzoomGoesOnThePaneFocusedWhenTheSessionLeaves() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness)
        var index = session.next
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        try await zoomTab(harness, session.bridge, answering: zoom.id, changed: true)
        let adapter = harness.model.terminalScreenAdapter
        let sheet = adapter.paneSelectionSheetRenderProjection(topLevelID: try topLevel(harness))
        XCTAssertEqual(adapter.focusPane(try XCTUnwrap(sheet.panes.last).id), .queued)
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p2")
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 3, zoomed: true, focusedPane: "w1:p2", panes: Self.tabPanes(["w1:p1", "w1:p2"])
        ))
        await session.bridge.serve(try harness.shownSurface(
            projection: 3, revision: 3, lines: ["two"], panes: [.init(id: "w1:p2", x: 0, width: 3, height: 1, focused: true)]
        ))
        try await harness.waitUntil("the focused pane wasn't drawn") { harness.model.paneSurface("w1:p2") != nil }
        XCTAssertEqual(
            adapter.paneSelectionSheetRenderProjection(topLevelID: try topLevel(harness)).selectedPaneID,
            sheet.panes.last?.id
        )

        harness.model.setSelected(false)
        let unzoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([unzoom.paneID, unzoom.mode], ["w1:p2", "off"])
    }

    /// The pane sheet's zoom button zooms the focused pane's tab, also with the setting off, and the zoom
    /// it makes is Remux's: leaving the screen undoes it.
    func testTheZoomButtonsZoomIsUndoneWhenTheSessionLeaves() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness)
        var index = session.next

        XCTAssertEqual(harness.model.terminalScreenAdapter.setFocusedPaneZoomed(true), .queued)
        let on = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([on.paneID, on.mode], ["w1:p1", "on"])
        try await zoomTab(harness, session.bridge, answering: on.id, changed: true)

        harness.model.setSelected(false)
        let undo = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([undo.paneID, undo.mode], ["w1:p1", "off"])
    }

    /// The zoom button unzooms the tab the setting zoomed; leaving then doesn't take it off again.
    func testAZoomTheUserTookOffIsNotTakenOffAgain() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness)
        var index = session.next
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        try await zoomTab(harness, session.bridge, answering: zoom.id, changed: true)

        XCTAssertEqual(harness.model.terminalScreenAdapter.setFocusedPaneZoomed(false), .queued)
        let off = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([off.paneID, off.mode], ["w1:p1", "off"])
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 3, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["one two"], panes: Self.twoPanes))
        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: off.id, changed: true, zoomed: false, panes: Self.zoomedPlaces)
        )
        try await harness.waitUntil("the tab didn't read as unzoomed") { (try? isZoomed(harness)) == false }
        try await Task.sleep(for: .milliseconds(100))

        harness.model.setSelected(false)
        let leave = try await harness.writes(session.bridge, from: index, count: 1)
        XCTAssertEqual(leave[0], .focus(false), "the zoom the user took off was taken off again")
    }

    /// While the tab is zoomed, the screen draws the zoomed pane alone, and the pane sheet maps every
    /// pane of the tab from Herdr's answer to the zoom, the focused one selected, with the zoom on.
    func testThePaneSheetMapsEveryPaneOfAZoomedTab() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, panes: ["w1:p1", "w1:p2", "w1:p3"])
        var index = session.next
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        let places: [(id: String, x: UInt16, y: UInt16, width: UInt16, height: UInt16)] = [
            ("w1:p1", 0, 0, 40, 24), ("w1:p2", 40, 0, 40, 12), ("w1:p3", 40, 12, 40, 12),
        ]
        try await zoomTab(harness, session.bridge, answering: zoom.id, changed: true, panes: ["w1:p1", "w1:p2", "w1:p3"], places: places)

        let adapter = harness.model.terminalScreenAdapter
        let sheet = adapter.paneSelectionSheetRenderProjection(topLevelID: try topLevel(harness))
        XCTAssertTrue(sheet.isServerZoomed)
        XCTAssertEqual(sheet.panes.map(\.frame), places.map {
            Optional(GhosttyTerminalGridRect(x: UInt32($0.x), y: UInt32($0.y), columns: UInt32($0.width), rows: UInt32($0.height)))
        })
        XCTAssertEqual(sheet.selectedPaneID, sheet.panes.first?.id)
        // The sheet lays the map out by its splits, each pane an equal share.
        let map = try XCTUnwrap(PaneTopologyLayout.frames(
            panes: try sheet.panes.map { PaneTopologyLayout.Pane(id: $0.id, frame: try XCTUnwrap($0.frame)) },
            size: CGSize(width: 300, height: 200)
        ), "the map couldn't lay the panes out")
        XCTAssertEqual(map.frame(for: sheet.panes[0].id), CGRect(x: 0, y: 0, width: 100, height: 200))
        XCTAssertEqual(map.frame(for: sheet.panes[2].id), CGRect(x: 100, y: 100, width: 200, height: 100))

        let viewport = adapter.terminalScreenPresentationProjection.viewport
        XCTAssertEqual(viewport.panes.filter { $0.visibleFrame != nil }.map(\.id), [sheet.panes[0].id])
        XCTAssertEqual(viewport.focusedSurfaceID, sheet.panes[0].id)
        XCTAssertEqual(adapter.terminalInteractionProjection.paneCount, 3)
        // Leaving undoes the zoom without waiting, so the test's stop doesn't wait for Herdr's answer.
        harness.model.setSelected(false)
        _ = try await nextWrite(session.bridge, from: &index, paneZoom)
    }

    /// Ending the session on screen undoes the zoom Remux made first, and closes the connection once
    /// Herdr has answered, so the unzoom isn't lost with it.
    func testEndingTheSessionUndoesTheZoomBeforeClosing() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness)
        var index = session.next
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        try await zoomTab(harness, session.bridge, answering: zoom.id, changed: true)

        let stopping = Task { await harness.model.stop() }
        let unzoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([unzoom.paneID, unzoom.mode], ["w1:p1", "off"])
        try await Task.sleep(for: .milliseconds(100))
        let closedEarly = await session.bridge.isClosed
        XCTAssertFalse(closedEarly, "the connection closed before Herdr answered the unzoom")
        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: unzoom.id, changed: true, zoomed: false, panes: Self.zoomedPlaces)
        )
        await stopping.value
        let closed = await session.bridge.isClosed
        XCTAssertTrue(closed)
    }

    /// A reconnect to the same server boot keeps the zoom Remux made, and undoes it on leaving; a new
    /// boot forgets it, since its tabs aren't the ones Remux zoomed.
    func testAReconnectKeepsTheZoomOfTheSameBootOnly() async throws {
        for (boot, undone) in [("boot", true), ("boot-2", false)] {
            var recovery = HerdrScreenModel.RecoveryTiming()
            recovery.firstRetry = .milliseconds(50)
            let harness = await makeHarness(settings: Self.zooming, recovery: recovery)
            let session = try await shownTab(harness)
            var index = session.next
            let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
            try await zoomTab(harness, session.bridge, answering: zoom.id, changed: true)
            await session.bridge.finishServing()

            let second = try await harness.bridge(1)
            await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(
                revision: 1, boot: boot, zoomed: true, panes: Self.tabPanes(["w1:p1", "w1:p2"])
            ))
            var next = 0
            let show = try await harness.nextSurfaceSet(second, from: &next)
            let again = try await nextWrite(second, from: &next, paneZoom)
            XCTAssertEqual([again.paneID, again.mode], ["w1:p1", "on"])
            // Herdr's answers come before the frame that completes the show, so they are read once the
            // show completes.
            await second.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
            await second.serve(HerdrServerScript.zoomReply(id: again.id, changed: false, zoomed: true, panes: Self.zoomedPlaces))
            await second.serve(try harness.shownSurface(
                boot: boot, projection: 1, revision: 1, lines: ["one"], panes: [Self.zoomedPane]
            ))
            try await harness.waitUntil("the session wasn't shown again") { harness.model.stateTraceLabel == "shown" }

            harness.model.setSelected(false)
            let leave = try await harness.writes(second, from: next, count: 1)
            if undone {
                guard case .paneZoom(_, "w1:p1", "off") = leave[0] else { return XCTFail("\(boot): \(leave)") }
            } else {
                XCTAssertEqual(leave[0], .focus(false), "\(boot): a zoom of another boot was undone")
            }
        }
    }

    private static var zooming: TerminalSettings {
        var settings = TerminalSettings.default
        settings.zoomMultipaneWindowsByDefault = true
        return settings
    }

    private static func tabPanes(_ ids: [String]) -> [String] {
        ids.map { HerdrServerScript.snapshotPane($0) }
    }

    private static let twoPanes: [HerdrServerScript.Pane] = [
        .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
        .init(id: "w1:p2", x: 4, width: 3, height: 1),
    ]

    /// `w1:p1` drawn alone across the tab, as a zoomed tab draws its focused pane.
    private static let zoomedPane = HerdrServerScript.Pane(id: "w1:p1", x: 0, width: 7, height: 1, focused: true)

    /// Where Herdr's zoom answer puts `w1:p1` and `w1:p2`: side by side, touching, as its layout does.
    private static let zoomedPlaces: [(id: String, x: UInt16, y: UInt16, width: UInt16, height: UInt16)] = [
        ("w1:p1", 0, 0, 40, 24), ("w1:p2", 40, 0, 40, 24),
    ]

    /// A session on tab `t1` with `panes`, the first focused, shown and taking input, its snapshot saying
    /// whether the tab is `zoomed`, and its frame drawing every pane, or only the first while zoomed.
    /// Returns its bridge and the index of the first write after the show's.
    private func shownTab(
        _ harness: HerdrModelHarness,
        panes: [String] = ["w1:p1", "w1:p2"],
        zoomed: Bool = false
    ) async throws -> (bridge: FakeBridgeTransport, next: Int) {
        let bridge = try await harness.bridge()
        await bridge.serve(
            try HerdrServerScript.welcome()
                + HerdrServerScript.snapshot(revision: 1, zoomed: zoomed, panes: Self.tabPanes(panes))
        )
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        let drawn = zoomed || panes.count == 1
            ? [Self.zoomedPane]
            : panes.enumerated().map { HerdrServerScript.Pane(id: $1, x: UInt16($0 * 4), width: 3, height: 1, focused: $0 == 0) }
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 1, lines: ["one two"], panes: drawn))
        let drawnIDs = drawn.map(\.id)
        try await harness.waitUntil("the panes' renderers weren't created") {
            drawnIDs.allSatisfy { harness.model.paneSurface($0) != nil }
        }
        showInWindow(harness, panes: drawnIDs)
        try await harness.waitUntil("input wasn't offered") { harness.model.isInputAvailable }
        return (bridge, index + 1)
    }

    /// Herdr zooms the tab on `w1:p1`, as it does: the snapshot and the frame drawing `w1:p1` alone, then
    /// its answer to the zoom `id`, which the model has taken once the pane sheet maps every pane.
    private func zoomTab(
        _ harness: HerdrModelHarness,
        _ bridge: FakeBridgeTransport,
        answering id: String,
        changed: Bool,
        panes: [String] = ["w1:p1", "w1:p2"],
        places: [(id: String, x: UInt16, y: UInt16, width: UInt16, height: UInt16)] = zoomedPlaces
    ) async throws {
        await bridge.serve(HerdrServerScript.snapshot(revision: 2, zoomed: true, panes: Self.tabPanes(panes)))
        await bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["one"], panes: [Self.zoomedPane]))
        await bridge.serve(HerdrServerScript.zoomReply(id: id, changed: changed, zoomed: true, panes: places))
        try await waitForMap(harness, panes: panes.count)
    }

    /// Waits until the pane sheet maps `panes` panes of the zoomed tab.
    private func waitForMap(_ harness: HerdrModelHarness, panes: Int = 2) async throws {
        try await harness.waitUntil("the pane sheet didn't map the zoomed tab") {
            guard let topLevel = try? topLevel(harness) else { return false }
            let sheet = harness.model.terminalScreenAdapter.paneSelectionSheetRenderProjection(topLevelID: topLevel)
            return sheet.isServerZoomed && sheet.panes.count == panes && sheet.panes.allSatisfy { $0.frame != nil }
        }
    }

    private func topLevel(_ harness: HerdrModelHarness) throws -> UUID {
        try XCTUnwrap(harness.model.terminalScreenAdapter.selectedPaneSheetPresentationProjection()).topLevelID
    }

    private func isZoomed(_ harness: HerdrModelHarness) throws -> Bool {
        harness.model.terminalScreenAdapter.paneSelectionSheetRenderProjection(topLevelID: try topLevel(harness)).isServerZoomed
    }

    private func paneZoom(_ write: ClientWrite) -> (id: String, paneID: String, mode: String)? {
        if case .paneZoom(let id, let paneID, let mode) = write { (id, paneID, mode) } else { nil }
    }

    // MARK: - Composer

    /// The composer's paste and its Enter each count as sent once Herdr has them, so the composer's pause
    /// before Enter runs from there: Herdr acknowledges no input, but answers a ping only after reading
    /// what came before it.
    func testAComposedMessageCountsAsSentOnceHerdrHasIt() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let pane = adapter.terminalScreenPresentationProjection.viewport.panes[0].id
        let message = "fix it\n'/tmp/a b.png'"

        let pasted = AnswerBox()
        let paste = Task { await pasted.set(await adapter.sendPasteAwaitingCommandCompletion(message, to: pane)) }
        let pasteInput = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(pasteInput, frame("w1:p1", [.paste(message)]))
        let pastePing = try await nextWrite(session.bridge, from: &index, ping)
        try await Task.sleep(for: .milliseconds(100))
        let early = await pasted.value
        XCTAssertNil(early, "the paste counted as sent before Herdr had it")
        await session.bridge.serve(HerdrConnectionTests.pong(pastePing))
        await paste.value
        let pasteAnswer = await pasted.value
        XCTAssertEqual(pasteAnswer, true)

        let enter = Task {
            await adapter.sendKeyEventAwaitingCommandCompletion(GhosttySurfaceKeyEvent(keyCode: .enter), to: pane)
        }
        let enterInput = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(enterInput, frame("w1:p1", [.key(HerdrKeyEvent(code: .enter, tracksRelease: true))]))
        let enterPing = try await nextWrite(session.bridge, from: &index, ping)
        await session.bridge.serve(HerdrConnectionTests.pong(enterPing))
        let entered = await enter.value
        XCTAssertTrue(entered)
    }

    /// A composed message goes to the pane it was written in after another pane takes the focus: Herdr
    /// takes input for every pane on the shown tab.
    func testAComposedMessageGoesToItsPaneAfterTheFocusMoves() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let pane = adapter.terminalScreenPresentationProjection.viewport.panes[0].id
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 2, focusedPane: "w1:p2"))
        try await harness.waitUntil("the focus didn't move") { harness.model.focusedPaneID == "w1:p2" }

        let enter = Task {
            await adapter.sendKeyEventAwaitingCommandCompletion(GhosttySurfaceKeyEvent(keyCode: .enter), to: pane)
        }
        let sent = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(sent, frame("w1:p1", [.key(HerdrKeyEvent(code: .enter, tracksRelease: true))]))
        let enterPing = try await nextWrite(session.bridge, from: &index, ping)
        await session.bridge.serve(HerdrConnectionTests.pong(enterPing))
        let entered = await enter.value
        XCTAssertTrue(entered)
    }

    /// A composed message that can't go isn't sent, and the composer says so itself: over Herdr's byte
    /// limit, to a pane no longer on the tab, while a popup is open over the tab, or while the session is
    /// hidden. Herdr would refuse the first and drop the others without a word, still answering pings.
    func testAComposedMessageThatCantGoIsNotSent() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let adapter = harness.model.terminalScreenAdapter
        let pane = adapter.terminalScreenPresentationProjection.viewport.panes[0].id

        let tooLarge = String(repeating: "a", count: HerdrConnection.maxInputBytes + 1)
        let oversized = await adapter.sendPasteAwaitingCommandCompletion(tooLarge, to: pane)
        XCTAssertFalse(oversized)
        let elsewhere = await adapter.sendPasteAwaitingCommandCompletion("x", to: UUID())
        XCTAssertFalse(elsewhere)
        await session.bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 3,
            lines: ["one two"],
            panes: [
                .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
                .init(id: "w1:p2", x: 4, width: 3, height: 1),
            ],
            popup: "popup-terminal"
        ))
        try await harness.waitUntil("the popup wasn't seen") { harness.model.layout?.hasPopup == true }
        let underPopup = await adapter.sendPasteAwaitingCommandCompletion("x", to: pane)
        XCTAssertFalse(underPopup)
        harness.model.setSelected(false)
        let hidden = await adapter.sendPasteAwaitingCommandCompletion("x", to: pane)
        XCTAssertFalse(hidden)

        XCTAssertNil(adapter.commandFailureEvent)
        try await Task.sleep(for: .milliseconds(100))
        let written = await session.bridge.writtenCount
        for index in session.next..<written {
            let write = try ClientWrite.decode(try await session.bridge.written(index))
            XCTAssertNil(paneInput(write), "input that can't go was sent")
        }
    }

    /// A paste whose connection ends before Herdr has it isn't sent, so the composer keeps the message.
    func testAComposedMessageIsNotSentWhenTheConnectionEndsFirst() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let adapter = harness.model.terminalScreenAdapter
        let pane = adapter.terminalScreenPresentationProjection.viewport.panes[0].id

        await session.bridge.stallWrites()
        let paste = Task { await adapter.sendPasteAwaitingCommandCompletion("fix it", to: pane) }
        await session.bridge.waitForStalledWrites(1)
        await session.bridge.finishServing()
        let pasted = await paste.value
        XCTAssertFalse(pasted)
    }

    // MARK: - Scrolling

    /// Herdr scrolls a pane's history and says where it is with each frame, so the pane's scroll view
    /// takes the position and where a scroll goes from Herdr, not from the painted terminal: history to
    /// Herdr with the indicator showing, a program that reads the mouse gets the wheel. Neither redraws
    /// the screen, since the history grows with every line a program prints.
    func testAPanesScrollingComesFromHerdrWithoutRedrawingTheScreen() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let adapter = harness.model.terminalScreenAdapter
        let ids = adapter.terminalScreenPresentationProjection.viewport.panes.map(\.id)
        let lookup = adapter.terminalManagedSurfaceLookup
        func serve(_ revision: UInt64, history: UInt64) async {
            await session.bridge.serve(HerdrServerScript.surface(
                projection: 1,
                revision: revision,
                lines: ["one two"],
                panes: [
                    .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true, scroll: (6, history, 1)),
                    .init(id: "w1:p2", x: 4, width: 3, height: 1, mouseReporting: true, alternateScreen: true),
                ]
            ))
        }
        await serve(3, history: 40)
        try await harness.waitUntil("the scrolling didn't reach the panes") {
            lookup.managedSurface(for: ids[0])?.scrollRoute == .remoteHistory
                && lookup.managedSurface(for: ids[1])?.scrollRoute == .mouseReport
        }
        let history = try XCTUnwrap(lookup.managedSurface(for: ids[0]))
        XCTAssertEqual(history.scrollState, GhosttySurfaceScrollState(total: 41, offset: 34, len: 1, cellOffset: 0))

        var screenChanges = 0
        let watch = adapter.objectWillChange.sink { screenChanges += 1 }
        await serve(4, history: 41)
        try await harness.waitUntil("the grown history didn't reach the pane") {
            history.scrollState.total == 42
        }
        watch.cancel()
        XCTAssertEqual(screenChanges, 0, "a change of scrolling alone redrew the screen")

        let container = GhosttyPaneScrollContainerView(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        _ = container.update(
            surface: history,
            displayScale: 3,
            submitRouteForwardedMouseScroll: { _, _ in .sent },
            submitRouteForwardedMousePosition: { _, _, _ in .sent }
        )
        container.layoutIfNeeded()
        let scrollView = try XCTUnwrap(
            container.subviews.compactMap { $0 as? UIScrollView }.first { !($0 is GhosttyScrollPhysicsView) }
        )
        XCTAssertFalse(scrollView.isScrollEnabled, "history scrolled locally instead of on Herdr")
        XCTAssertTrue(scrollView.showsVerticalScrollIndicator)
        XCTAssertGreaterThan(scrollView.contentSize.height, container.bounds.height)
    }

    /// A server reporting a history at the top of the range gets a capped total, not a crash.
    func testAnOversizedHistoryCapsTheScrollTotal() {
        let scroll = HerdrPaneScroll(
            linesFromBottom: 0,
            maxLinesFromBottom: .max,
            rows: 40,
            mouseReporting: false,
            alternateScreenActive: false
        )
        XCTAssertEqual(scroll.scrollState, GhosttySurfaceScrollState(total: .max, offset: .max, len: 40, cellOffset: 0))
    }

    /// A scroll gesture's travel becomes Herdr wheel steps as Ghostty makes lines of it for tmux: one
    /// per cell height, the rest kept for the next, up or down with the travel, at the cell where the
    /// gesture is, each carrying Herdr's three history lines.
    func testAScrollGestureSendsWheelStepsToItsPane() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let pane = adapter.terminalScreenPresentationProjection.viewport.panes[0].id
        let cellHeight = Double(try XCTUnwrap(harness.model.measurement).cellMetrics.pixelHeight)
        func travel(
            _ cells: Double,
            _ momentum: GhosttySurfaceMouseScrollMods.Momentum = .changed
        ) -> GhosttyMouseInputSubmissionOutcome {
            adapter.sendMouseScroll(to: pane, GhosttySurfaceMouseScrollEvent(
                deltaX: 0,
                deltaY: cells * cellHeight,
                mods: .init(precision: true, momentum: momentum)
            ))
        }

        XCTAssertEqual(adapter.sendMousePosition(to: pane, CGPoint(x: 1, y: 1), mods: []), .sent)
        XCTAssertEqual(travel(2.5, .began), .sent)
        XCTAssertEqual(travel(0.6), .sent)
        XCTAssertEqual(travel(-3.2), .sent)
        XCTAssertEqual(travel(0, .ended), .sent)

        let up = HerdrInputEvent.mouse(HerdrMouseEvent(kind: .scrollUp, column: 0, row: 0, lines: 3))
        let down = HerdrInputEvent.mouse(HerdrMouseEvent(kind: .scrollDown, column: 0, row: 0, lines: 3))
        var sent: [[UInt8]] = []
        for _ in 0..<3 {
            sent.append(try await nextWrite(session.bridge, from: &index, paneInput))
        }
        XCTAssertEqual(sent, [
            frame("w1:p1", [up, up]),
            frame("w1:p1", [up]),
            frame("w1:p1", [down, down, down]),
        ])

        // A cancelled gesture, as when the program's mouse mode changes, sends none of its travel.
        XCTAssertEqual(travel(0.9, .began), .sent)
        XCTAssertEqual(travel(0.5, .cancelled), .sent)
        try await Task.sleep(for: .milliseconds(100))
        let written = await session.bridge.writtenCount
        for position in index..<written {
            let write = try ClientWrite.decode(try await session.bridge.written(position))
            XCTAssertNil(paneInput(write), "a cancelled gesture's travel was sent")
        }
    }

    /// As in Herdr's client, scrolling another pane focuses it, and its steps go to it. A hidden session
    /// takes no scrolling.
    func testScrollingAnotherPaneFocusesItAndAHiddenSessionTakesNone() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let ids = adapter.terminalScreenPresentationProjection.viewport.panes.map(\.id)
        let cellHeight = Double(try XCTUnwrap(harness.model.measurement).cellMetrics.pixelHeight)
        let began = GhosttySurfaceMouseScrollEvent(
            deltaX: 0,
            deltaY: 1.2 * cellHeight,
            mods: .init(precision: true, momentum: .began)
        )

        _ = adapter.sendMousePosition(to: ids[1], .zero, mods: [])
        XCTAssertEqual(adapter.sendMouseScroll(to: ids[1], began), .sent)
        var focused: String?
        var input: [UInt8]?
        while focused == nil || input == nil {
            let write = try ClientWrite.decode(try await session.bridge.written(index))
            index += 1
            if let focus = paneFocus(write) { focused = focus.paneID }
            if let sent = paneInput(write) { input = sent }
        }
        XCTAssertEqual(focused, "w1:p2")
        XCTAssertEqual(input, frame("w1:p2", [.mouse(HerdrMouseEvent(kind: .scrollUp, column: 0, row: 0, lines: 3))]))

        harness.model.setSelected(false)
        XCTAssertEqual(adapter.sendMouseScroll(to: ids[0], began), .surfaceRejected)
        try await Task.sleep(for: .milliseconds(100))
        let written = await session.bridge.writtenCount
        for position in index..<written {
            let write = try ClientWrite.decode(try await session.bridge.written(position))
            XCTAssertNil(paneInput(write), "a hidden session scrolled")
        }
    }

    /// A session shown with panes `w1:p1` and `w1:p2`, both drawn, its snapshot focusing `focusedPane`;
    /// returns its bridge and the index of the first write after the show. A test that moves the focus
    /// types into the other pane, which takes input only once it has drawn.
    private func shownSession(
        _ harness: HerdrModelHarness,
        focusedPane: String = "w1:p1"
    ) async throws -> (bridge: FakeBridgeTransport, next: Int) {
        let bridge = try await harness.bridge()
        await bridge.serve(
            try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, focusedPane: focusedPane)
        )
        let panes: [HerdrServerScript.Pane] = [
            .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
            .init(id: "w1:p2", x: 4, width: 3, height: 1),
        ]
        await bridge.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["one two"], panes: panes))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 2, lines: ["one two"], panes: panes))
        try await harness.waitUntil("the panes' renderers weren't created") {
            harness.model.paneSurface("w1:p1") != nil && harness.model.paneSurface("w1:p2") != nil
        }
        let paneIDs = panes.map(\.id)
        showInWindow(harness, panes: paneIDs)
        try await harness.waitUntil("the panes didn't draw") {
            paneIDs.allSatisfy { harness.model.presentation(ofPane: $0) == .ready }
        }
        try await harness.waitUntil("input wasn't offered") { harness.model.isInputAvailable }
        return (bridge, index)
    }

    /// A pane is ready once its renderer has drawn into a window, as on the screen.
    private func showInWindow(_ harness: HerdrModelHarness, panes: [String]) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let viewController = UIViewController()
        window.rootViewController = viewController
        for paneID in panes {
            if let view = harness.model.paneSurface(paneID)?.renderer.view {
                viewController.view.addSubview(view)
            }
        }
        window.isHidden = false
        windows.append(window)
    }

    /// The next write from `index` on that `match` takes, skipping others; `index` moves past it.
    private func nextWrite<Value>(
        _ bridge: FakeBridgeTransport,
        from index: inout Int,
        _ match: (ClientWrite) -> Value?
    ) async throws -> Value {
        while true {
            let write = try ClientWrite.decode(try await bridge.written(index))
            index += 1
            if let value = match(write) { return value }
        }
    }

    private func paneInput(_ write: ClientWrite) -> [UInt8]? {
        if case .paneInput(let frame) = write { frame } else { nil }
    }

    private func ping(_ write: ClientWrite) -> String? {
        if case .ping(let data) = write { data } else { nil }
    }

    private func paneFocus(_ write: ClientWrite) -> (id: String, paneID: String)? {
        if case .paneFocus(let id, let paneID) = write { (id, paneID) } else { nil }
    }

    private func frame(_ paneID: String, _ events: [HerdrInputEvent]) -> [UInt8] {
        HerdrClientMessage.paneInput(paneID: paneID, events: events).frame
    }

    private func typed(_ character: Unicode.Scalar) -> HerdrInputEvent {
        .key(HerdrKeyEvent(code: .character(character), generatedText: String(character)))
    }

    /// A reconnect replaces the connection, not the panes: the last frame stays until the new
    /// connection's first, which the same server boot paints into the same terminals.
    func testAReconnectKeepsTheLastFrameUntilTheNewConnectionsFirst() async throws {
        let harness = await makeHarness()
        let first = try await harness.bridge(0)
        let panes: [HerdrServerScript.Pane] = [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        await first.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await first.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["one"], panes: panes))
        harness.setScreenSize()
        try await harness.waitUntil("the first frame wasn't shown") {
            harness.shownRows() == ["w1:p1": ["one"]]
        }
        let renderer = try XCTUnwrap(harness.model.paneSurface("w1:p1")?.renderer)

        harness.model.reconnect()
        let second = try await harness.bridge(1)
        try await harness.waitUntil("the first connection wasn't closed") { await first.isClosed }
        XCTAssertEqual(harness.shownRows(), ["w1:p1": ["one"]])
        XCTAssertTrue(harness.model.paneSurface("w1:p1")?.renderer === renderer)

        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await second.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["two"], panes: panes))
        try await harness.waitUntil("the new connection's frame wasn't shown") {
            harness.shownRows() == ["w1:p1": ["two"]]
        }
        XCTAssertTrue(harness.model.paneSurface("w1:p1")?.renderer === renderer)
        XCTAssertFalse(harness.model.isDisconnected)
    }

    /// A restarted server paints its panes into new terminals. A pane it names as before stays the same
    /// leaf, as when a pane's terminal is replaced: its old surface leaves the screen when its renderer
    /// closes, and the leaf finds the new renderer's surface once that is admitted, here after the new
    /// boot's layout.
    func testAPaneOfARestartedServerStaysTheSameLeafWithANewSurface() async throws {
        let gate = RendererFenceGate()
        let harness = await makeHarness(rendererFenceGate: gate)
        let first = try await harness.bridge(0)
        let panes: [HerdrServerScript.Pane] = [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        await first.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, boot: "boot-1"))
        await first.serve(HerdrServerScript.surface(
            boot: "boot-1", projection: 1, revision: 1, lines: ["one"], panes: panes
        ))
        harness.setScreenSize()
        try await harness.waitUntil("the first frame wasn't shown") {
            harness.shownRows() == ["w1:p1": ["one"]]
        }
        let adapter = harness.model.terminalScreenAdapter
        let lookup = adapter.terminalManagedSurfaceLookup
        let id = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)
        let firstSurface = try XCTUnwrap(lookup.managedSurface(for: id))
        let container = GhosttyPaneScrollContainerView()
        _ = container.update(
            surface: firstSurface,
            displayScale: 2,
            submitRouteForwardedMouseScroll: nil,
            submitRouteForwardedMousePosition: nil
        )
        XCTAssertNotNil(firstSurface.view.superview)

        gate.holdsRegistrations = true
        harness.model.reconnect()
        let second = try await harness.bridge(1)
        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, boot: "boot-2"))
        await second.serve(HerdrServerScript.surface(
            boot: "boot-2", projection: 1, revision: 1, lines: ["two"], panes: panes
        ))
        try await harness.waitUntil("the new boot's renderer wasn't waiting on its registration") {
            harness.model.layout?.bootID == "boot-2" && gate.heldRegistrationCount == 1
        }
        XCTAssertNil(lookup.managedSurface(for: id))
        XCTAssertNil(firstSurface.view.superview)
        XCTAssertNil(firstSurface.onScrollStateChange)

        gate.releaseRegistrations()
        try await harness.waitUntil("the restarted server's frame wasn't shown") {
            harness.shownRows() == ["w1:p1": ["two"]]
        }
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID, id)
        let secondSurface = try XCTUnwrap(lookup.managedSurface(for: id))
        XCTAssertFalse(secondSurface === firstSurface)
        XCTAssertEqual(secondSurface.id, id)
        _ = container.update(
            surface: secondSurface,
            displayScale: 2,
            submitRouteForwardedMouseScroll: nil,
            submitRouteForwardedMousePosition: nil
        )
        XCTAssertNotNil(secondSurface.view.superview)
        XCTAssertNotNil(secondSurface.onScrollStateChange)
    }

    /// When Ghostty can't paint a restarted server's pane into its new terminal, the pane keeps its old
    /// surface, failed: the screen still finds it under the pane's leaf, and nothing can be typed.
    func testAPaneOfARestartedServerWhoseNewTerminalFailsKeepsItsOldSurfaceFailed() async throws {
        let producerFailure = ProducerFailure()
        let harness = await makeHarness(producerFailure: producerFailure)
        let first = try await harness.bridge(0)
        let panes: [HerdrServerScript.Pane] = [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        await first.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, boot: "boot-1"))
        await first.serve(HerdrServerScript.surface(
            boot: "boot-1", projection: 1, revision: 1, lines: ["one"], panes: panes
        ))
        harness.setScreenSize()
        try await harness.waitUntil("the first frame wasn't shown") {
            harness.shownRows() == ["w1:p1": ["one"]]
        }
        let model = harness.model
        let adapter = model.terminalScreenAdapter
        let id = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)
        let oldSurface = try XCTUnwrap(adapter.terminalManagedSurfaceLookup.managedSurface(for: id))

        producerFailure.isOn = true
        model.reconnect()
        let second = try await harness.bridge(1)
        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, boot: "boot-2"))
        await second.serve(HerdrServerScript.surface(
            boot: "boot-2", projection: 1, revision: 1, lines: ["two"], panes: panes
        ))
        try await harness.waitUntil("the new boot's pane didn't fail") {
            guard model.layout?.bootID == "boot-2", case .failed = model.presentation(ofPane: "w1:p1") else {
                return false
            }
            return true
        }

        let shownID = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)
        XCTAssertEqual(shownID, id)
        XCTAssertTrue(adapter.terminalManagedSurfaceLookup.managedSurface(for: shownID) === oldSurface)
        XCTAssertFalse(model.isInputAvailable)
    }

    /// A hidden session's renderer gets its screen surface when admitted, hidden and unfocused, and its
    /// pane stays pending: being made early neither shows the pane nor takes input.
    func testAHiddenSessionsPaneGetsItsSurfaceHiddenAndStaysPending() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["left 1"],
            panes: [.init(id: "w1:p1", x: 0, width: 6, height: 1, focused: true)]
        ))
        harness.setScreenSize()
        try await harness.waitUntil("the pane's renderer wasn't created") {
            harness.model.paneSurface("w1:p1") != nil
        }

        let managed = try XCTUnwrap(harness.model.paneSurface("w1:p1")?.renderer.managedSurface)
        XCTAssertFalse(managed.isVisible)
        XCTAssertFalse(managed.isFocused)
        XCTAssertFalse(managed.rendererIsAvailable)
        XCTAssertEqual(harness.model.presentation(ofPane: "w1:p1"), .pending)
        XCTAssertFalse(harness.model.isInputAvailable)
    }
}
