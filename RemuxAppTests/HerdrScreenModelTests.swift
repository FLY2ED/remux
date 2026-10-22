import Combine
import GhosttyKit
import UIKit
import XCTest
@testable import Remux

/// `HerdrScreenModel` over scripted bridges, with a real connection, engine and Ghostty renderers.
@MainActor
final class HerdrScreenModelTests: XCTestCase {
    private var harnesses: [HerdrModelHarness] = []

    override func tearDown() async throws {
        for harness in harnesses {
            await harness.model.stop()
        }
        harnesses.removeAll()
    }

    private func makeHarness(
        settings: TerminalSettings = .default,
        timing: HerdrConnection.Timing = HerdrConnection.Timing(),
        failingOpenWith error: Error? = nil,
        bridgeOpeningTakes: Duration = .zero,
        producerFailure: ProducerFailure? = nil,
        rendererFenceGate: RendererFenceGate? = nil
    ) async -> HerdrModelHarness {
        let harness = await HerdrModelHarness(
            settings: settings,
            timing: timing,
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

    /// A show Herdr doesn't answer ends the connection, and the failure is reported.
    func testAShowHerdrDoesNotAnswerEndsTheConnection() async throws {
        var timing = HerdrConnection.Timing()
        timing.activation = .milliseconds(200)
        let harness = await makeHarness(timing: timing)
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.setScreenSize()
        harness.model.setSelected(true)

        try await harness.waitUntil("the failed show wasn't reported") {
            harness.states.last?.disconnectedReason != nil
        }
        XCTAssertEqual(harness.states.last?.disconnectedReason?.kind, .transportIO)
        XCTAssertTrue(harness.model.isDisconnected)
        // The failure is reported at once; the close follows it.
        try await harness.waitUntil("the connection wasn't closed") { await bridge.isClosed }
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
    /// while the connection is down, as Herdr's client hides its cursor while its session is offline,
    /// and focused again once a new connection is open.
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
        try await harness.waitUntil("the lost connection wasn't reported") {
            harness.states.last?.disconnectedReason != nil
        }
        XCTAssertFalse(managed.isFocused)

        harness.model.reconnect()
        XCTAssertFalse(managed.isFocused, "nothing is live before the new connection opens")
        let second = try await harness.bridge(1)
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

    /// The panes take no input yet, so a session ready on screen still offers no keyboard: the screen is
    /// told input is unavailable, as for a session whose input is down, and keys aren't typed into a
    /// sink that drops them.
    func testAReadySessionOffersNoInput() async throws {
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
        try await harness.waitUntil("the pane's renderer wasn't created") {
            harness.model.paneSurface("w1:p1") != nil
        }
        let renderer = try XCTUnwrap(harness.model.paneSurface("w1:p1")).renderer
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let viewController = UIViewController()
        window.rootViewController = viewController
        viewController.view.addSubview(renderer.view)
        window.isHidden = false
        defer { window.isHidden = true }

        try await harness.waitUntil("the session wasn't ready") { harness.states.last == .connected }
        let interaction = harness.model.terminalScreenAdapter.terminalInteractionProjection
        XCTAssertTrue(interaction.hasFocusedSurface)
        XCTAssertFalse(interaction.isInputAvailable)
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

    /// A grid Remux can't index ends the connection Remux-side; the model closes it and reports it.
    func testAnUnindexableSurfaceClosesTheConnectionAndIsReported() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
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
    }

    /// The connection's own end is reported once, with its reason, also when it ends while `open` is
    /// still returning.
    func testAConnectionThatEndsIsReported() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.finishServing()
        harness.setScreenSize()

        try await harness.waitUntil("the end wasn't reported") {
            harness.states.last?.disconnectedReason != nil
        }
        XCTAssertEqual(harness.states.last, .disconnected(HerdrConnectionError.closed.terminalDisconnectReason))
        XCTAssertEqual(harness.states.filter { $0.disconnectedReason != nil }.count, 1)
    }

    func testABridgeThatCannotStartIsReported() async throws {
        let harness = await makeHarness(failingOpenWith: HerdrBridgeError.herdrNotFound)
        try await harness.waitUntil("the failure wasn't reported") {
            harness.states.last?.disconnectedReason != nil
        }
        XCTAssertEqual(
            harness.states.last,
            .disconnected(TerminalDisconnectReason(kind: .profile, message: HerdrBridgeError.herdrNotFound.errorDescription!))
        )
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
}
