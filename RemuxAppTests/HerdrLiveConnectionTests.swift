import Foundation
import GhosttyKit
import UIKit
import XCTest
@testable import Remux

/// Remux's Herdr connection against a real Herdr server over a real SSH server: Remux's SSH stack,
/// `HerdrSSHBridge`'s launch script and `HerdrConnection`. The bridge starts the server inside
/// `HerdrLiveFixture`'s isolated folder. Opt-in through `REMUX_LIVE_HERDR_CONFIG`.
final class HerdrLiveConnectionTests: XCTestCase {
    func testConnectionShowsAPaneAndDeliversInput() async throws {
        let fixture = try await HerdrLiveFixture.start(try HerdrLiveConfiguration.load())
        addTeardownBlock {
            for problem in await fixture.tearDown() {
                XCTFail(problem)
            }
        }
        let trace = RemuxTransportStartupTrace(flowID: "herdr-live-connection")
        let log = HerdrLiveEventLog()

        let bridge = try await HerdrSSHBridge.open(
            using: try await fixture.claimRoot(trace: trace),
            herdrExecutable: fixture.executable,
            session: fixture.session,
            trace: trace
        )
        let connection = try await HerdrConnection.open(
            transport: bridge,
            hello: HerdrHello(cellWidthPx: 9, cellHeightPx: 18, cols: 80, rows: 24, surfaceActive: true),
            appActive: true,
            onEvent: { await log.append($0) }
        )
        // Teardown blocks run last first, so the connection closes before the fixture stops Herdr.
        addTeardownBlock { await connection.close(.finished) }
        let negotiated = await connection.negotiated
        XCTAssertEqual(negotiated?.delta, true)
        XCTAssertEqual(negotiated?.scroll, true)

        // The server opens its first workspace when the bridge starts it.
        let paneID = try await log.snapshot(timeout: .seconds(15)) { !$0.panes.isEmpty }.panes[0].paneID

        // The typed line holds the token's halves apart; only the shell's output joins them.
        let token = UUID().uuidString.prefix(8).lowercased()
        let surfacesBeforeInput = await log.surfaceCount
        try await connection.send([.text("printf 'live-%s\\n' \(token)\r")], toPane: paneID)

        let deadline = ContinuousClock.now + .seconds(15)
        var visible = ""
        while ContinuousClock.now < deadline {
            let read = try await fixture.herdr(["pane", "read", paneID, "--source", "visible"], trace: trace)
            visible = String(decoding: read.stdout, as: UTF8.self)
            if visible.contains("live-\(token)") { break }
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertTrue(visible.contains("live-\(token)"), "the pane never showed the command's output:\n\(visible)")
        // Herdr sends surfaces over the bridge and answers the CLI over its own connection, in no set order.
        let surfaceDeadline = ContinuousClock.now + .seconds(15)
        while await log.surfaceCount <= surfacesBeforeInput, ContinuousClock.now < surfaceDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let surfacesAfterInput = await log.surfaceCount
        XCTAssertGreaterThan(surfacesAfterInput, surfacesBeforeInput, "no surface update reached Remux after the input")
        let ended = await log.endReason
        XCTAssertNil(ended, "the connection ended early: \(String(describing: ended))")
    }

    // MARK: - Typing

    /// Text and keys, translated as Remux translates them, reach a raw-mode program as the bytes a plain
    /// terminal sends for them, on the oldest release Remux supports and the current one. Herdr v0.9.4
    /// changed Herdr's key encoder.
    func testTypedInputReachesTheProgramAsATerminalSendsItOnHerdr093() async throws {
        try await checkTypedInputReachesTheProgram(version: "0.9.3")
    }

    func testTypedInputReachesTheProgramAsATerminalSendsItOnHerdr095() async throws {
        try await checkTypedInputReachesTheProgram(version: "0.9.5")
    }

    /// A program that asks for every key as an escape code makes Herdr report it, and non-ASCII text
    /// then reaches the program as typed. A letter comes as its key code from v0.9.4 on; v0.9.3 writes a
    /// key's text as it is.
    func testAReportAllProgramGetsCommittedTextOnHerdr093() async throws {
        try await checkReportAllProgramGetsCommittedText(version: "0.9.3")
    }

    func testAReportAllProgramGetsCommittedTextOnHerdr095() async throws {
        try await checkReportAllProgramGetsCommittedText(version: "0.9.5")
    }

    /// `pane.focus`, as a tap sends it, moves the focus, and the next snapshot reports it.
    func testPaneFocusMovesTheFocus() async throws {
        let live = try await openLive(version: "0.9.3")
        let split = try await live.fixture.herdr(
            ["pane", "split", live.paneID, "--direction", "right", "--no-focus"],
            trace: live.trace
        )
        XCTAssertEqual(split.exitStatus, 0, String(decoding: split.stderr, as: UTF8.self))
        let snapshot = try await live.log.snapshot(timeout: .seconds(15)) { $0.panes.count == 2 }
        XCTAssertEqual(snapshot.focusedPaneID, live.paneID)
        let other = try XCTUnwrap(snapshot.panes.first { $0.paneID != live.paneID }).paneID

        let request = try HerdrClientMessage.endpointRequest(
            bootID: snapshot.bootID,
            id: "focus",
            method: HerdrScreenModel.paneFocusMethod,
            params: ["pane_id": other]
        )
        live.connection.outbox.send([request])
        let reply = try await live.log.reply(to: "focus", timeout: .seconds(15))
        if case .failure(let failure) = HerdrCommandLane.result(of: reply) { XCTFail("\(failure)") }
        _ = try await live.log.snapshot(timeout: .seconds(15)) { $0.focusedPaneID == other }
    }

    // MARK: - Showing

    /// Hidden and shown again, the session takes no input until Herdr's show completes, then takes it
    /// again: Herdr answers the show and sends a frame at the phone's size.
    @MainActor
    func testAShownAgainSessionTakesInputOnceTheShowCompletesOnHerdr093() async throws {
        try await checkShownAgainSessionTakesInput(version: "0.9.3")
    }

    @MainActor
    func testAShownAgainSessionTakesInputOnceTheShowCompletesOnHerdr095() async throws {
        try await checkShownAgainSessionTakesInput(version: "0.9.5")
    }

    @MainActor
    private func checkShownAgainSessionTakesInput(version: String) async throws {
        let session = try await openShownSession(version: version, through: { $0 })
        session.model.setSelected(false)
        XCTAssertFalse(session.model.isInputAvailable)
        session.model.setSelected(true)
        XCTAssertFalse(session.model.isInputAvailable, "input was offered before Herdr completed the show")
        try await waitUntil("the session shown again didn't take input", timeout: .seconds(10)) {
            session.model.isInputAvailable
        }
        XCTAssertEqual(session.model.sendText("true\r"), .accepted)
    }

    // MARK: - Zoom

    /// With "Zoom multipane windows" on, Herdr zooms the two-pane tab on screen as the session is shown,
    /// the pane sheet maps both panes from Herdr's answer, and leaving the screen, or ending the session,
    /// unzooms it, as Herdr itself reports.
    @MainActor
    func testATabIsZoomedWhileShownOnHerdr093() async throws {
        try await checkTabIsZoomedWhileShown(version: "0.9.3")
    }

    @MainActor
    func testATabIsZoomedWhileShownOnHerdr095() async throws {
        try await checkTabIsZoomedWhileShown(version: "0.9.5")
    }

    /// A zoom another client made stays when the session leaves the screen.
    @MainActor
    func testAZoomMadeElsewhereStaysOnHerdr093() async throws {
        let session = try await openShownSession(version: "0.9.3", settings: Self.zooming, through: { $0 })
        let panes = try await split(session)
        try await herdrZoom(session, pane: panes.focused, on: true)
        try await zoomState(session, pane: panes.focused, is: true)
        session.model.setSelected(false)
        session.model.setSelected(true)
        try await waitUntil("the session wasn't shown again", timeout: .seconds(10)) { session.model.isInputAvailable }
        session.model.setSelected(false)
        try await Task.sleep(for: .seconds(1))
        try await zoomState(session, pane: panes.focused, is: true)
    }

    @MainActor
    private func checkTabIsZoomedWhileShown(version: String) async throws {
        let session = try await openShownSession(version: version, settings: Self.zooming, through: { $0 })
        let panes = try await split(session)
        // The split happened while shown; the setting zooms the tab on screen as it is shown.
        try await zoomState(session, pane: panes.focused, is: false)
        session.model.setSelected(false)
        session.model.setSelected(true)
        try await zoomState(session, pane: panes.focused, is: true)
        let adapter = session.model.terminalScreenAdapter
        try await waitUntil("the pane sheet didn't map both panes", timeout: .seconds(10)) {
            guard let topLevel = adapter.selectedPaneSheetPresentationProjection()?.topLevelID else { return false }
            let sheet = adapter.paneSelectionSheetRenderProjection(topLevelID: topLevel)
            return sheet.isServerZoomed && sheet.panes.count == 2 && sheet.panes.allSatisfy { $0.frame != nil }
        }

        session.model.setSelected(false)
        try await zoomState(session, pane: panes.focused, is: false)

        session.model.setSelected(true)
        try await zoomState(session, pane: panes.focused, is: true)
        try await waitUntil("the session wasn't shown again", timeout: .seconds(10)) { session.model.isInputAvailable }
        await session.model.stop()
        try await zoomState(session, pane: panes.focused, is: false)
    }

    private static var zooming: TerminalSettings {
        var settings = TerminalSettings.default
        settings.zoomMultipaneWindowsByDefault = true
        return settings
    }

    /// Splits the session's first pane from another client, keeping the focus, and returns the panes once
    /// the session's frame draws both.
    @MainActor
    private func split(_ session: ShownSession) async throws -> (focused: String, other: String) {
        let focused = try XCTUnwrap(session.model.focusedPaneID)
        let split = try await session.fixture.herdr(
            ["pane", "split", focused, "--direction", "right", "--no-focus"],
            trace: RemuxTransportStartupTrace(flowID: "herdr-live-zoom")
        )
        XCTAssertEqual(split.exitStatus, 0, String(decoding: split.stderr, as: UTF8.self))
        try await waitUntil("the split pane wasn't drawn", timeout: .seconds(10)) {
            (session.model.layout?.panes.filter(\.hasTextArea).count ?? 0) == 2
        }
        let other = try XCTUnwrap(session.model.layout?.panes.first { $0.paneID != focused }?.paneID)
        return (focused, other)
    }

    @MainActor
    private func herdrZoom(_ session: ShownSession, pane: String, on: Bool) async throws {
        let result = try await session.fixture.herdr(
            ["pane", "zoom", pane, on ? "--on" : "--off"],
            trace: RemuxTransportStartupTrace(flowID: "herdr-live-zoom")
        )
        XCTAssertEqual(result.exitStatus, 0, String(decoding: result.stderr, as: UTF8.self))
    }

    /// Waits until Herdr reports `pane`'s tab zoomed or not, as its own `pane layout` tells it.
    @MainActor
    private func zoomState(_ session: ShownSession, pane: String, is zoomed: Bool) async throws {
        struct Reply: Decodable {
            struct Result: Decodable {
                struct Layout: Decodable { let zoomed: Bool }
                let layout: Layout
            }

            let result: Result
        }
        let deadline = ContinuousClock.now + .seconds(10)
        var last: Bool?
        while ContinuousClock.now < deadline {
            let result = try await session.fixture.herdr(
                ["pane", "layout", "--pane", pane],
                trace: RemuxTransportStartupTrace(flowID: "herdr-live-zoom")
            )
            last = try? JSONDecoder().decode(Reply.self, from: result.stdout).result.layout.zoomed
            if last == zoomed { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw HerdrLiveError(description: "Herdr reported the tab zoomed \(String(describing: last)), not \(zoomed)")
    }

    // MARK: - Agents

    /// Herdr's agent states reach the sheets as the phone shows them: an agent in another tab working, then
    /// blocked, in its own word once its labels give one, then done, which it stays until its pane is on
    /// screen, and the tab shows its state throughout.
    @MainActor
    func testAgentsReachTheSheetsAsThePhoneShowsThemOnHerdr093() async throws {
        try await checkAgentsReachTheSheets(version: "0.9.3")
    }

    @MainActor
    func testAgentsReachTheSheetsAsThePhoneShowsThemOnHerdr095() async throws {
        try await checkAgentsReachTheSheets(version: "0.9.5")
    }

    @MainActor
    private func checkAgentsReachTheSheets(version: String) async throws {
        struct CreatedTab: Decodable {
            struct Result: Decodable {
                struct Pane: Decodable {
                    let paneID: String

                    private enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
                }

                let rootPane: Pane

                private enum CodingKeys: String, CodingKey { case rootPane = "root_pane" }
            }

            let result: Result
        }
        let session = try await openShownSession(version: version, through: { $0 })
        let trace = RemuxTransportStartupTrace(flowID: "herdr-live-agents")
        func herdr(_ arguments: [String]) async throws -> Data {
            let result = try await session.fixture.herdr(arguments, trace: trace)
            XCTAssertEqual(result.exitStatus, 0, String(decoding: result.stderr, as: UTF8.self))
            return result.stdout
        }
        let created = try await herdr(["tab", "create", "--label", "build", "--no-focus"])
        let agent = try JSONDecoder().decode(CreatedTab.self, from: created).result.rootPane.paneID
        func report(_ state: String) async throws {
            _ = try await herdr(["pane", "report-agent", agent, "--source", "remux-live", "--agent", "claude", "--state", state])
        }
        func state(is expected: TerminalAgentState, _ failure: String) async throws {
            try await waitUntil(failure, timeout: .seconds(15)) {
                session.model.agents.state(ofPane: agent) == expected
            }
        }

        try await report("working")
        try await state(is: TerminalAgentState(.working), "the agent didn't show working")
        let tab = try XCTUnwrap(session.model.agents.agents.first { $0.paneID == agent }?.tabID)
        XCTAssertEqual(session.model.agents.status(ofTab: tab), .working)

        try await report("blocked")
        try await state(is: TerminalAgentState(.blocked), "the agent didn't show blocked")
        _ = try await herdr([
            "pane", "report-metadata", agent, "--source", "remux-live", "--agent", "claude",
            "--state-label", "blocked=needs review",
        ])
        try await state(is: TerminalAgentState(.blocked, word: "needs review"), "the agent's own word didn't show")
        XCTAssertEqual(session.model.agents.status(ofTab: tab), .blocked)

        try await report("working")
        try await state(is: TerminalAgentState(.working), "the agent didn't show working again")
        try await report("idle")
        try await state(is: TerminalAgentState(.done), "the agent that finished off screen didn't show done")
        XCTAssertEqual(session.model.agents.status(ofTab: tab), .done)

        XCTAssertTrue(session.model.focusPane(agent))
        try await state(is: TerminalAgentState(.idle), "the agent's pane on screen didn't count as seen")
        XCTAssertEqual(session.model.agents.status(ofTab: tab), .idle)
    }

    // MARK: - Health

    /// Herdr's health rule against a real server, with short limits: a quiet connection is pinged after
    /// each silence, Herdr answers every ping, and the connection stays up.
    func testAQuietConnectionIsPingedAndStaysUp() async throws {
        var timing = HerdrConnection.Timing()
        timing.pingAfterSilence = .milliseconds(500)
        timing.unansweredPing = .seconds(2)
        var counter: HerdrLivePingCounter?
        let live = try await openLive(version: "0.9.3", timing: timing) { bridge in
            let wrapped = HerdrLivePingCounter(bridge)
            counter = wrapped
            return wrapped
        }
        let pings = try XCTUnwrap(counter)
        let before = await pings.count
        try await Task.sleep(for: .seconds(6))
        let sent = await pings.count - before
        XCTAssertGreaterThanOrEqual(sent, 5, "too few health pings for six seconds of a quiet connection")
        let ended = await live.log.endReason
        XCTAssertNil(ended, "the connection ended: \(String(describing: ended))")
    }

    // MARK: - Composer

    /// Remux's composer sends a message to a Herdr pane as one paste, then Enter at least the composer's
    /// pause after Herdr has the paste, and the program reads Enter on its own after the whole paste. The
    /// program asks for bracketed paste, as agents' prompts do; the message starts with a slash, which
    /// opens a command menu in some agents.
    @MainActor
    func testAComposedMessageArrivesAsAPasteThenEnterAfterThePauseOnHerdr093() async throws {
        try await checkComposedMessage(version: "0.9.3", message: Self.composedMessage)
    }

    @MainActor
    func testAComposedMessageArrivesAsAPasteThenEnterAfterThePauseOnHerdr095() async throws {
        try await checkComposedMessage(version: "0.9.5", message: Self.composedMessage)
    }

    /// Over a slow uplink a long paste is still arriving well after the phone wrote it. The pause before
    /// Enter runs once Herdr has the whole paste, so Enter still comes on its own, after the paste.
    @MainActor
    func testAComposedMessageKeepsItsPauseOverASlowUplink() async throws {
        // The program's log of a longer message is more than a command's output may be.
        let message = "/review " + String(repeating: "0123456789abcdef", count: 1024)
        try await checkComposedMessage(version: "0.9.5", message: message) {
            HerdrLiveSlowUplink($0, bytesPerSecond: 32_000)
        }
    }

    private static let composedMessage = "/review the composer\nsecond line '/tmp/a b.png'"

    @MainActor
    private func checkComposedMessage(
        version: String,
        message: String,
        through wrap: @escaping @Sendable (any HerdrBridgeTransport) -> any HerdrBridgeTransport = { $0 }
    ) async throws {
        let session = try await openShownSession(version: version, through: wrap)
        let adapter = session.model.terminalScreenAdapter
        let log = try await startReadLog(in: session, modes: #"\033[?2004h"#)

        let composer = GhosttyComposerModel()
        composer.draft = message
        let surfaceID = try XCTUnwrap(adapter.terminalInteractionProjection.selectedActiveLeafID)
        let times = ComposerTimes()
        // As the screen sends a composed message.
        composer.submit(to: GhosttyComposerSubmissionDestination(
            workspaceID: session.model.target.workspace.id,
            surfaceID: surfaceID,
            destinationLabel: nil,
            makeAttachmentTransferService: { FailingComposerAttachmentTransferService() },
            prepareTerminalInput: {},
            sendPaste: {
                let delivered = await adapter.sendPasteAwaitingCommandCompletion($0, to: surfaceID)
                times.pasteDelivered = .now
                return delivered
            },
            sendEnter: {
                times.enterSent = .now
                let enter = GhosttySurfaceKeyEvent(action: .press, keyCode: .enter)
                guard await adapter.sendKeyEventAwaitingCommandCompletion(enter, to: surfaceID) else { return false }
                _ = adapter.sendKeyEvent(GhosttySurfaceKeyEvent(action: .release, keyCode: .enter), to: surfaceID)
                return true
            }
        ))
        try await waitUntil("the message wasn't sent", timeout: .seconds(30)) { !composer.isSubmitting }
        XCTAssertNil(composer.statusMessage)
        XCTAssertEqual(composer.draft, "")

        let paste = Array("\u{1b}[200~\(message)\u{1b}[201~".utf8)
        let reads = try await log.reads(until: { $0.flatMap(\.bytes).count >= paste.count + 1 })
        XCTAssertEqual(reads.flatMap(\.bytes), paste + [0x0d], "Herdr \(version)")
        guard let enter = reads.last, enter.bytes == [0x0d], reads.count >= 2 else {
            return XCTFail("Enter came in the paste's read on Herdr \(version): \(reads.map(\.bytes.count))")
        }
        // The pause runs from Herdr's answer that it has the paste; Herdr can still be writing the paste to
        // the program then, so the gap the program sees isn't Remux's to keep.
        let pause = try XCTUnwrap(times.enterSent) - (try XCTUnwrap(times.pasteDelivered))
        XCTAssertGreaterThanOrEqual(pause, .milliseconds(150), "Enter went \(pause) after Herdr had the paste on Herdr \(version)")
    }

    // MARK: - Pane borders

    /// Herdr's default palette: the focused pane's border in `accent`, the others' in `overlay0`
    /// (`app/state.rs` `Palette::catppuccin`).
    private static let accent = GhosttyPaneLine.Ink.color(red: 0x89, green: 0xB4, blue: 0xFA)
    private static let grey = GhosttyPaneLine.Ink.color(red: 0x6C, green: 0x70, blue: 0x86)

    /// With Herdr's defaults each pane has its own box (`pane_gaps`), around its text area and the
    /// scrollbar's column right of it, and the focused pane's box is Herdr's accent (`ui/panes.rs`).
    @MainActor
    func testEachPaneHasHerdrsBoxWithHerdrsDefaults() async throws {
        let viewport = try await threePaneViewport(ui: [], settled: { viewport in
            Set(viewport.paneLines.map(Self.describe)) == Set(viewport.panes.flatMap { pane in
                Self.box(around: pane.normalFrame, ink: pane.isFocused ? Self.accent : Self.grey)
            }.map(Self.describe))
        })
        XCTAssertEqual(viewport.paneLines.count, 12)
    }

    /// `pane_gaps = false`: neighbours share one line, Herdr's accent along the focused pane's side and
    /// its grey along the other's (`line_touches_pane`). The top line runs the window's width, under the
    /// labels too.
    @MainActor
    func testNeighboursShareOneLineWithHerdrsGapsOff() async throws {
        let viewport = try await threePaneViewport(ui: ["pane_gaps = false"], settled: Self.hasOneSharedDivider)
        XCTAssertTrue(Self.hasOneSharedDivider(viewport))
        let top = viewport.paneLines.filter { $0.orientation == .horizontal && $0.position == 0.5 }
            .sorted { $0.start < $1.start }
        XCTAssertEqual(top.first?.start, 0.5)
        XCTAssertEqual(top.last?.end, CGFloat(viewport.windowGrid?.columns ?? 0) - 0.5)
        XCTAssertTrue(zip(top, top.dropFirst()).allSatisfy { $0.end == $1.start }, "\(top)")
    }

    /// One line between the left pane and the two on the right, the window's height, in the accent
    /// beside a right pane where it is the focused pane's side: that pane's, or the left pane's along
    /// its whole height.
    private static func hasOneSharedDivider(_ viewport: GhosttyTerminalViewportPresentationProjection) -> Bool {
        guard case let (left, top, bottom)? = try? leftTopAndBottom(viewport),
              let focused = viewport.panes.first(where: \.isFocused),
              let rows = viewport.windowGrid?.rows
        else { return false }
        let divider = viewport.paneLines.filter {
            $0.orientation == .vertical && $0.position > CGFloat(left.normalFrame.x + left.normalFrame.columns)
                && $0.position < CGFloat(top.normalFrame.x)
        }
        guard Set(divider.map(\.position)).count == 1,
              divider.map(\.start).min() == 0.5,
              divider.map(\.end).max() == CGFloat(rows) - 0.5
        else { return false }
        return [top, bottom].allSatisfy { pane in
            let middle = CGFloat(pane.normalFrame.y) + CGFloat(pane.normalFrame.rows) / 2
            let ink = focused.id == pane.id || focused.id == left.id ? accent : grey
            return divider.first { $0.start <= middle && $0.end >= middle }?.ink == ink
        }
    }

    /// `pane_borders = "off"`: Herdr draws no lines and leaves a blank cell between panes; the picker
    /// maps every pane.
    @MainActor
    func testNoLinesWithHerdrsBordersOff() async throws {
        let viewport = try await threePaneViewport(ui: [#"pane_borders = "off""#], settled: { _ in true })
        XCTAssertEqual(viewport.paneLines, [])
        let (left, top, _) = try Self.leftTopAndBottom(viewport)
        XCTAssertEqual(left.normalFrame.x + left.normalFrame.columns + 2, top.normalFrame.x, "the scrollbar's column and the gap")
    }

    /// `pane_borders = "off"` and `pane_gaps = false`: the panes' rectangles touch, with only the
    /// scrollbar's column between the text areas, and no lines; the picker maps every pane.
    @MainActor
    func testTouchingPanesWithHerdrsBordersAndGapsOff() async throws {
        let viewport = try await threePaneViewport(
            ui: [#"pane_borders = "off""#, "pane_gaps = false"],
            settled: { _ in true }
        )
        XCTAssertEqual(viewport.paneLines, [])
        let (left, top, bottom) = try Self.leftTopAndBottom(viewport)
        XCTAssertEqual(left.normalFrame.x + left.normalFrame.columns + 1, top.normalFrame.x, "only the scrollbar's column")
        XCTAssertEqual(top.normalFrame.y + top.normalFrame.rows, bottom.normalFrame.y, "no row between")
    }

    /// A tab split into a pane on the left and two on the right on a fresh server with the `ui` settings,
    /// the left and the top right pane labelled, once `settled` holds for the screen's projection (or
    /// after 15 s). The pane picker's map has a tile for each pane.
    @MainActor
    private func threePaneViewport(
        ui: [String],
        settled: (GhosttyTerminalViewportPresentationProjection) -> Bool
    ) async throws -> GhosttyTerminalViewportPresentationProjection {
        let session = try await openShownSession(version: "0.9.3", ui: ui, through: { $0 })
        let model = session.model
        let adapter = model.terminalScreenAdapter
        let trace = RemuxTransportStartupTrace(flowID: "herdr-live-borders")
        let first = try XCTUnwrap(model.layout?.panes.first?.paneID)
        // The first pane is split right, then the new pane down.
        let splits: [(pane: String?, direction: String)] = [(first, "right"), (nil, "down")]
        for (pane, direction) in splits {
            let count = model.layout?.panes.count ?? 0
            let target = try pane ?? XCTUnwrap(model.layout?.panes.first { $0.paneID != first }?.paneID)
            let split = try await session.fixture.herdr(["pane", "split", target, "--direction", direction], trace: trace)
            XCTAssertEqual(split.exitStatus, 0, String(decoding: split.stderr, as: UTF8.self))
            try await waitUntil("the split didn't arrive", timeout: .seconds(15)) {
                adapter.terminalScreenPresentationProjection.viewport.panes.count == count + 1
            }
        }
        // Labels are written over the top borders of the left and the top right pane.
        let topRight = try XCTUnwrap(model.layout?.panes.first { $0.paneID != first }?.paneID)
        for (pane, label) in [(first, "editor"), (topRight, "notes")] {
            let rename = try await session.fixture.herdr(["pane", "rename", pane, label], trace: trace)
            XCTAssertEqual(rename.exitStatus, 0, String(decoding: rename.stderr, as: UTF8.self))
        }
        // The layout names its panes from the snapshot its frame was drawn against.
        try await waitUntil("the labels didn't arrive", timeout: .seconds(15)) {
            let names = model.layout?.panes.map(\.name) ?? []
            return names.contains { $0.hasPrefix("editor") } && names.contains { $0.hasPrefix("notes") }
        }
        let deadline = ContinuousClock.now + .seconds(15)
        var viewport = adapter.terminalScreenPresentationProjection.viewport
        while !settled(viewport), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            viewport = adapter.terminalScreenPresentationProjection.viewport
        }
        XCTAssertTrue(settled(viewport), "\(viewport.panes.map(\.normalFrame)) \(viewport.paneLines)")

        let tab = try XCTUnwrap(adapter.selectedPaneSheetPresentationProjection()).topLevelID
        let picker = adapter.paneSelectionSheetRenderProjection(topLevelID: tab)
        let map = PaneTopologyLayout.frames(
            panes: try picker.panes.map { PaneTopologyLayout.Pane(id: $0.id, frame: try XCTUnwrap($0.frame)) },
            size: CGSize(width: 300, height: 200)
        )
        XCTAssertEqual(picker.panes.compactMap { map?.frame(for: $0.id) }.count, 3, "the picker's map lacks tiles")
        return viewport
    }

    private static func leftTopAndBottom(
        _ viewport: GhosttyTerminalViewportPresentationProjection
    ) throws -> (left: GhosttyTerminalViewportPresentationProjection.Pane, top: GhosttyTerminalViewportPresentationProjection.Pane, bottom: GhosttyTerminalViewportPresentationProjection.Pane) {
        let panes = viewport.panes.sorted { ($0.normalFrame.x, $0.normalFrame.y) < ($1.normalFrame.x, $1.normalFrame.y) }
        guard panes.count == 3 else { throw HerdrLiveError(description: "not three panes: \(panes)") }
        return (panes[0], panes[1], panes[2])
    }

    /// The four sides of the box Herdr draws around a pane whose text area is `area`, with the
    /// scrollbar's column right of the text, through the middle of the border cells.
    private static func box(around area: GhosttyTerminalGridRect, ink: GhosttyPaneLine.Ink) -> [GhosttyPaneLine] {
        let left = CGFloat(area.x) - 0.5
        let right = CGFloat(area.x + area.columns) + 1.5
        let top = CGFloat(area.y) - 0.5
        let bottom = CGFloat(area.y + area.rows) + 0.5
        func line(_ orientation: GhosttyPaneLine.Orientation, _ position: CGFloat, _ start: CGFloat, _ end: CGFloat)
            -> GhosttyPaneLine
        {
            GhosttyPaneLine(orientation: orientation, position: position, start: start, end: end, ink: ink, width: 1, cap: .square)
        }
        return [
            line(.horizontal, top, left, right), line(.horizontal, bottom, left, right),
            line(.vertical, left, top, bottom), line(.vertical, right, top, bottom),
        ]
    }

    private static func describe(_ line: GhosttyPaneLine) -> String {
        "\(line.orientation) \(line.position) \(line.start)-\(line.end) \(line.ink) \(line.width) \(line.cap)"
    }

    // MARK: - Scrolling

    /// A scroll over a shell's output moves Herdr's history three lines a step, and the pane's scroll
    /// view follows Herdr's position.
    @MainActor
    func testScrollingAShellMovesItsHistoryOnHerdr093() async throws {
        try await checkScrollingMovesHistory(version: "0.9.3")
    }

    @MainActor
    func testScrollingAShellMovesItsHistoryOnHerdr095() async throws {
        try await checkScrollingMovesHistory(version: "0.9.5")
    }

    /// A full-screen program that doesn't read the mouse gets an arrow key for each step.
    @MainActor
    func testScrollingAFullScreenProgramSendsItArrowKeysOnHerdr093() async throws {
        try await checkScrollingReachesTheProgram(version: "0.9.3", modes: #"\033[?1049h"#, route: .altScreenCursor, step: "\u{1b}[A")
    }

    @MainActor
    func testScrollingAFullScreenProgramSendsItArrowKeysOnHerdr095() async throws {
        try await checkScrollingReachesTheProgram(version: "0.9.5", modes: #"\033[?1049h"#, route: .altScreenCursor, step: "\u{1b}[A")
    }

    /// A program that reads the mouse gets a wheel report for each step, at the cell under the finger.
    @MainActor
    func testScrollingAProgramThatReadsTheMouseSendsItWheelReportsOnHerdr093() async throws {
        try await checkScrollingReachesTheProgram(
            version: "0.9.3",
            modes: #"\033[?1049h\033[?1000h\033[?1006h"#,
            route: .mouseReport,
            step: "\u{1b}[<64;1;1M"
        )
    }

    @MainActor
    func testScrollingAProgramThatReadsTheMouseSendsItWheelReportsOnHerdr095() async throws {
        try await checkScrollingReachesTheProgram(
            version: "0.9.5",
            modes: #"\033[?1049h\033[?1000h\033[?1006h"#,
            route: .mouseReport,
            step: "\u{1b}[<64;1;1M"
        )
    }

    @MainActor
    private func checkScrollingMovesHistory(version: String) async throws {
        let session = try await openShownSession(version: version, through: { $0 })
        let adapter = session.model.terminalScreenAdapter
        let pane = try XCTUnwrap(adapter.terminalInteractionProjection.selectedActiveLeafID)
        let surface = try XCTUnwrap(adapter.terminalManagedSurfaceLookup.managedSurface(for: pane))
        XCTAssertEqual(session.model.sendText("seq 1 300\r"), .accepted)
        try await waitUntil("the shell's history didn't grow", timeout: .seconds(15)) {
            surface.scrollRoute == .remoteHistory && surface.scrollState.maxRow >= 100
        }

        try scroll(session, pane: pane, steps: 4)
        try await waitUntil("Herdr didn't scroll the history", timeout: .seconds(15)) {
            surface.scrollState.maxRow - surface.scrollState.offset == 12
        }
    }

    @MainActor
    private func checkScrollingReachesTheProgram(
        version: String,
        modes: String,
        route: GhosttySurfaceScrollRoute,
        step: String
    ) async throws {
        let session = try await openShownSession(version: version, through: { $0 })
        let adapter = session.model.terminalScreenAdapter
        let pane = try XCTUnwrap(adapter.terminalInteractionProjection.selectedActiveLeafID)
        let surface = try XCTUnwrap(adapter.terminalManagedSurfaceLookup.managedSurface(for: pane))
        let log = try await startReadLog(in: session, modes: modes)
        try await waitUntil("the pane's scrolling didn't follow the program's modes", timeout: .seconds(15)) {
            surface.scrollRoute == route
        }

        try scroll(session, pane: pane, steps: 2)
        let expected = Array((step + step).utf8)
        let reads = try await log.reads(until: { $0.flatMap(\.bytes).count >= expected.count })
        XCTAssertEqual(reads.flatMap(\.bytes), expected, "Herdr \(version)")
    }

    // MARK: - Mouse

    /// As the screen sends a tap and a drag, a program that reads the mouse gets them at the cells under the
    /// finger, relative to its pane: the pointer's move there, which it asked for with every motion, the
    /// press, the held button's drag and the release.
    @MainActor
    func testATapAndADragReachAProgramThatReadsTheMouseOnHerdr093() async throws {
        try await checkMouseReachesTheProgram(version: "0.9.3")
    }

    @MainActor
    func testATapAndADragReachAProgramThatReadsTheMouseOnHerdr095() async throws {
        try await checkMouseReachesTheProgram(version: "0.9.5")
    }

    /// A right-click reaches the program once Herdr is told to send the pane its right-clicks
    /// (`herdr pane input --right-click pane`); until then it's Herdr's.
    @MainActor
    func testARightClickReachesAProgramOnlyInAPaneThatTakesThemOnHerdr095() async throws {
        let session = try await openShownSession(version: "0.9.5", through: { $0 })
        let adapter = session.model.terminalScreenAdapter
        let pane = try XCTUnwrap(adapter.terminalInteractionProjection.selectedActiveLeafID)
        let paneID = try XCTUnwrap(session.model.focusedPaneID)
        let log = try await startReadLog(in: session, modes: #"\033[?1000h\033[?1006h"#)
        try await waitUntil("the pane didn't say its program reads the mouse", timeout: .seconds(15)) {
            adapter.isMouseCaptured(for: pane)
        }
        let rightPress = GhosttySurfaceMouseButtonEvent(state: .press, button: .right)
        XCTAssertEqual(adapter.sendMousePosition(to: pane, try cellCentre(session, column: 1, row: 0), mods: []), .sent)
        XCTAssertEqual(adapter.sendMouseButton(to: pane, rightPress), .surfaceRejected)

        let set = try await session.fixture.herdr(
            ["pane", "input", paneID, "--right-click", "pane"],
            trace: RemuxTransportStartupTrace(flowID: "herdr-live-mouse")
        )
        XCTAssertEqual(set.exitStatus, 0, String(decoding: set.stderr, as: UTF8.self))
        let deadline = ContinuousClock.now + .seconds(10)
        while adapter.sendMouseButton(to: pane, rightPress) != .sent {
            guard ContinuousClock.now < deadline else { throw HerdrLiveError(description: "the pane never took a right-click") }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(adapter.sendMouseButton(to: pane, .init(state: .release, button: .right)), .sent)
        let expected = Array("\u{1b}[<2;2;1M\u{1b}[<2;2;1m".utf8)
        let reads = try await log.reads(until: { $0.flatMap(\.bytes).count >= expected.count })
        XCTAssertEqual(reads.flatMap(\.bytes), expected)
    }

    @MainActor
    private func checkMouseReachesTheProgram(version: String) async throws {
        let session = try await openShownSession(version: version, through: { $0 })
        let adapter = session.model.terminalScreenAdapter
        let pane = try XCTUnwrap(adapter.terminalInteractionProjection.selectedActiveLeafID)
        let log = try await startReadLog(in: session, modes: #"\033[?1003h\033[?1006h"#)
        try await waitUntil("the pane didn't say its program reads the mouse", timeout: .seconds(15)) {
            adapter.isMouseCaptured(for: pane)
        }

        XCTAssertEqual(adapter.sendMousePosition(to: pane, try cellCentre(session, column: 2, row: 1), mods: []), .sent)
        XCTAssertEqual(adapter.sendMouseButton(to: pane, .init(state: .press, button: .left)), .sent)
        XCTAssertEqual(adapter.sendMousePosition(to: pane, try cellCentre(session, column: 4, row: 1), mods: []), .sent)
        XCTAssertEqual(adapter.sendMouseButton(to: pane, .init(state: .release, button: .left)), .sent)

        let expected = Array("\u{1b}[<35;3;2M\u{1b}[<0;3;2M\u{1b}[<32;5;2M\u{1b}[<0;5;2m".utf8)
        let reads = try await log.reads(until: { $0.flatMap(\.bytes).count >= expected.count })
        XCTAssertEqual(reads.flatMap(\.bytes), expected, "Herdr \(version)")
    }

    /// The middle of a cell of the pane, in the pane's points, as a tap there gives it.
    @MainActor
    private func cellCentre(_ session: ShownSession, column: Double, row: Double) throws -> CGPoint {
        let metrics = try XCTUnwrap(session.model.measurement).cellMetrics
        return CGPoint(
            x: (column + 0.5) * Double(metrics.pixelWidth) / metrics.contentScale,
            y: (row + 0.5) * Double(metrics.pixelHeight) / metrics.contentScale
        )
    }

    // MARK: - Clipboard

    /// A program's OSC 52 copy in the session on screen lands on the iPhone clipboard, and the screen says
    /// so.
    @MainActor
    func testAProgramsCopyReachesTheClipboardOnHerdr093() async throws {
        try await checkAProgramsCopyReachesTheClipboard(version: "0.9.3")
    }

    @MainActor
    func testAProgramsCopyReachesTheClipboardOnHerdr095() async throws {
        try await checkAProgramsCopyReachesTheClipboard(version: "0.9.5")
    }

    @MainActor
    private func checkAProgramsCopyReachesTheClipboard(version: String) async throws {
        let session = try await openShownSession(version: version, through: { $0 })
        let text = "copied on Herdr \(version) \(UUID().uuidString.prefix(8))"
        let before = UIPasteboard.general.changeCount
        XCTAssertEqual(
            session.model.sendText("printf '\\033]52;c;%s\\a' \"$(printf '%s' '\(text)' | base64)\"\r"),
            .accepted
        )
        // Reading what another process put on the clipboard makes iOS ask the user, so the test reads it
        // only once this process has written it.
        try await waitUntil("the copy didn't reach the clipboard", timeout: .seconds(15)) {
            UIPasteboard.general.changeCount != before
        }
        XCTAssertEqual(UIPasteboard.general.string, text)
        XCTAssertEqual(
            session.model.terminalScreenAdapter.terminalScreenPresentationProjection.statusOverlay,
            .notice(HerdrScreenModel.copiedNotice)
        )
    }

    // MARK: - Selection

    /// A line longer than the pane copies as one line, as Herdr keeps it: the pane's own terminal holds
    /// only the painted rows, and would break it where the pane wraps it.
    @MainActor
    func testAWrappedLineCopiesAsOneLineOnHerdr093() async throws {
        try await checkWrappedLineCopiesAsOneLine(version: "0.9.3")
    }

    @MainActor
    func testAWrappedLineCopiesAsOneLineOnHerdr095() async throws {
        try await checkWrappedLineCopiesAsOneLine(version: "0.9.5")
    }

    /// A selection keeps its lines while Herdr scrolls the history under it, and an endpoint moved into the
    /// history reaches lines the first frame never showed: scrolled back to the bottom, that endpoint is
    /// off screen without a handle, and the copy still starts there.
    @MainActor
    func testASelectionReachesHistoryOnHerdr093() async throws {
        try await checkASelectionReachesHistory(version: "0.9.3")
    }

    @MainActor
    func testASelectionReachesHistoryOnHerdr095() async throws {
        try await checkASelectionReachesHistory(version: "0.9.5")
    }

    /// A long-press on a link the pane wraps selects all of it, and its copy is the link on one line.
    @MainActor
    func testAWrappedLinkCopiesWholeOnHerdr093() async throws {
        let session = try await openShownSession(version: "0.9.3", through: { $0 })
        let pane = try selectionPane(of: session)
        let token = UUID().uuidString.prefix(8).lowercased()
        let url = "https://example.com/\(token)/" + String(repeating: "p", count: Int(pane.area.width))
        XCTAssertEqual(
            session.model.sendText(#"clear; printf '\033]8;;"# + url + #"\033\\"# + url + #"\033]8;;\033\\\n'"# + "\r"),
            .accepted
        )
        let row = try await waitForWrappedRows(of: url, in: session, pane: pane)

        guard case .match(_, let target) = pane.surface.selectLink(at: cellPoint(row: row, column: 2, in: session)) else {
            return XCTFail("the link wasn't selected")
        }
        XCTAssertEqual(target, url)
        let copied = await session.model.terminalScreenAdapter.selectedText(in: pane.id)
        XCTAssertEqual(copied, url)
    }

    /// A long-press on a plain-text link the pane wraps finds only a row's part of it in the pane's own
    /// terminal, on either row; Herdr finds the rest, the selection grows over both rows, and its copy is
    /// the link on one line.
    @MainActor
    func testAWrappedPlainLinkSelectsAndCopiesWholeOnHerdr093() async throws {
        try await checkWrappedPlainLinkSelectsWhole(version: "0.9.3")
    }

    @MainActor
    func testAWrappedPlainLinkSelectsAndCopiesWholeOnHerdr095() async throws {
        try await checkWrappedPlainLinkSelectsWhole(version: "0.9.5")
    }

    /// Scrolled wholly off screen and back, a selection is still there, drawn at its line, and copies it.
    @MainActor
    func testASelectionScrolledOffScreenStaysOnHerdr093() async throws {
        try await checkASelectionScrolledOffScreenStays(version: "0.9.3")
    }

    @MainActor
    func testASelectionScrolledOffScreenStaysOnHerdr095() async throws {
        try await checkASelectionScrolledOffScreenStays(version: "0.9.5")
    }

    /// How long a long-press's selection takes to grow over a wrapped link: from the pane's terminal's cut
    /// match to the grown selection, `pane.link.resolve`'s round trip through Remux's connection over SSH
    /// to the fixture included.
    @MainActor
    func testWrappedLinkGrowthTime() async throws {
        let session = try await openShownSession(version: "0.9.5", through: { $0 })
        let pane = try selectionPane(of: session)
        let url = "https://example.com/\(UUID().uuidString.prefix(8).lowercased())/" + String(repeating: "p", count: Int(pane.area.width))
        XCTAssertEqual(session.model.sendText("clear; printf '%s\\n' \(url)\r"), .accepted)
        let row = try await waitForWrappedRows(of: url, in: session, pane: pane)
        let press = cellPoint(row: row, column: 2, in: session)
        let adapter = session.model.terminalScreenAdapter

        var samples: [Duration] = []
        for _ in 0..<30 {
            _ = pane.surface.clearSelection()
            XCTAssertEqual(longPress(pane, at: press), .link)
            let started = ContinuousClock.now
            let grew = await adapter.completeLinkSelection(in: pane.id, at: press, selected: .link)
            samples.append(ContinuousClock.now - started)
            XCTAssertTrue(grew)
        }
        samples.sort()
        let summary = "a wrapped link's selection grows over \(samples.count) long-presses in: "
            + "median \(samples[samples.count / 2]), p95 \(samples[samples.count * 95 / 100]), max \(samples.last!)"
        print(summary)
        let attachment = XCTAttachment(string: summary)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// How long a copy waits for Herdr: `pane.selection.read`'s round trip through Remux's connection,
    /// over SSH to the fixture.
    @MainActor
    func testSelectionReadRoundTrip() async throws {
        let session = try await openShownSession(version: "0.9.5", through: { $0 })
        let pane = try selectionPane(of: session)
        let token = "copy-\(UUID().uuidString.prefix(8).lowercased())"
        XCTAssertEqual(session.model.sendText("clear; printf '%s\\n' \(token)\r"), .accepted)
        let rows = try await waitForRows(in: session, pane: pane, "the token wasn't shown") {
            $0.contains(token)
        }
        let row = try XCTUnwrap(rows.firstIndex(of: token))
        guard case .snapshot(let selected) = pane.surface.selectWord(at: cellPoint(row: row, column: 0, in: session)),
              selected.isActive
        else { return XCTFail("the token wasn't selected") }

        var samples: [Duration] = []
        for _ in 0..<30 {
            let started = ContinuousClock.now
            let copied = await session.model.terminalScreenAdapter.selectedText(in: pane.id)
            samples.append(ContinuousClock.now - started)
            XCTAssertEqual(copied, token)
        }
        samples.sort()
        let summary = "pane.selection.read round trip over \(samples.count) reads: "
            + "median \(samples[samples.count / 2]), p95 \(samples[samples.count * 95 / 100]), max \(samples.last!)"
        print(summary)
        let attachment = XCTAttachment(string: summary)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func checkWrappedLineCopiesAsOneLine(version: String) async throws {
        let session = try await openShownSession(version: version, through: { $0 })
        let pane = try selectionPane(of: session)
        let token = UUID().uuidString.prefix(8).lowercased()
        let line = "wrap-\(token)-" + String(repeating: "x", count: Int(pane.area.width))
        XCTAssertEqual(session.model.sendText("clear; printf '%s\\n' \(line)\r"), .accepted)
        let row = try await waitForWrappedRows(of: line, in: session, pane: pane)
        let rest = line.count - Int(pane.area.width)

        XCTAssertTrue(isActive(pane.surface.selectWord(at: cellPoint(row: row, column: 0, in: session))))
        XCTAssertTrue(isActive(pane.surface.setSelectionEndpoint(
            GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_END,
            at: cellPoint(row: row + 1, column: rest - 1, in: session)
        )))
        XCTAssertEqual(
            pane.surface.controlSurface.readSelection(),
            String(line.prefix(Int(pane.area.width))) + "\n" + String(line.suffix(rest)),
            "the pane's own terminal should break the line where it wraps"
        )
        let copied = await session.model.terminalScreenAdapter.selectedText(in: pane.id)
        XCTAssertEqual(copied, line, "Herdr \(version)")
    }

    @MainActor
    private func checkASelectionReachesHistory(version: String) async throws {
        let session = try await openShownSession(version: version, through: { $0 })
        let pane = try selectionPane(of: session)
        XCTAssertEqual(session.model.sendText("clear; seq -f 'history line %g' 1 300\r"), .accepted)
        let rows = try await waitForRows(in: session, pane: pane, "the history wasn't printed") {
            $0.contains("history line 300")
        }
        try await waitUntil("Herdr's history didn't reach the pane", timeout: .seconds(15)) {
            pane.surface.scrollRoute == .remoteHistory && pane.surface.scrollState.maxRow >= 200
                && pane.surface.scrollState.offset == pane.surface.scrollState.maxRow
        }
        // The line on the second row, and the seven lines above it, which the first frame doesn't show.
        let line = try XCTUnwrap(rows[1].split(separator: " ").last.flatMap { Int($0) }, "row 1: \(rows[1])")
        XCTAssertEqual(rows[0], "history line \(line - 1)")
        XCTAssertTrue(isActive(pane.surface.selectWord(at: cellPoint(row: 1, column: 0, in: session))))
        XCTAssertTrue(isActive(pane.surface.setSelectionEndpoint(
            GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_END,
            at: cellPoint(row: 1, column: rows[1].count - 1, in: session)
        )))

        try scroll(session, pane: pane.id, steps: 2)
        try await waitUntil("Herdr didn't scroll the history", timeout: .seconds(15)) {
            pane.surface.scrollState.maxRow - pane.surface.scrollState.offset == 6
        }
        guard case .snapshot(let scrolled) = pane.surface.selectionSnapshot(), let start = scrolled.start else {
            return XCTFail("the selection didn't stay on screen")
        }
        XCTAssertEqual(pane.surface.controlSurface.viewportCell(of: start)?.row, 7, "the highlight didn't follow its line")
        XCTAssertTrue(isActive(pane.surface.setSelectionEndpoint(
            GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_START,
            at: cellPoint(row: 0, column: 0, in: session)
        )))

        try scroll(session, pane: pane.id, steps: -2)
        try await waitUntil("Herdr didn't scroll back to the bottom", timeout: .seconds(15)) {
            pane.surface.scrollState.offset == pane.surface.scrollState.maxRow
        }
        guard case .snapshot(let back) = pane.surface.selectionSnapshot(), back.isActive else {
            return XCTFail("the selection ended")
        }
        XCTAssertNil(back.start, "the endpoint in the history kept its handle off screen")
        XCTAssertNotNil(back.end)
        let copied = await session.model.terminalScreenAdapter.selectedText(in: pane.id)
        XCTAssertEqual(
            copied,
            ((line - 7)...line).map { "history line \($0)" }.joined(separator: "\n"),
            "Herdr \(version)"
        )
    }

    @MainActor
    private func checkWrappedPlainLinkSelectsWhole(version: String) async throws {
        let session = try await openShownSession(version: version, through: { $0 })
        let pane = try selectionPane(of: session)
        let width = Int(pane.area.width)
        let token = UUID().uuidString.prefix(8).lowercased()
        let url = "https://example.com/\(token)/" + String(repeating: "p", count: width)
        XCTAssertEqual(session.model.sendText("clear; printf '%s\\n' \(url)\r"), .accepted)
        let row = try await waitForWrappedRows(of: url, in: session, pane: pane)
        let adapter = session.model.terminalScreenAdapter

        for pressed in [row, row + 1] {
            let press = cellPoint(row: pressed, column: 2, in: session)
            let selected = try XCTUnwrap(longPress(pane, at: press), "row \(pressed)")
            XCTAssertNotEqual(
                pane.surface.controlSurface.readSelection(),
                String(url.prefix(width)) + "\n" + String(url.dropFirst(width)),
                "the pane's own terminal found the whole link"
            )
            let grew = await adapter.completeLinkSelection(in: pane.id, at: press, selected: selected)
            XCTAssertTrue(grew, "Herdr \(version), row \(pressed)")
            XCTAssertEqual(
                pane.surface.controlSurface.readSelection(),
                String(url.prefix(width)) + "\n" + String(url.dropFirst(width)),
                "the selection didn't grow over both rows"
            )
            let copied = await adapter.selectedText(in: pane.id)
            XCTAssertEqual(copied, url, "Herdr \(version), row \(pressed)")
        }
    }

    @MainActor
    private func checkASelectionScrolledOffScreenStays(version: String) async throws {
        let session = try await openShownSession(version: version, through: { $0 })
        let pane = try selectionPane(of: session)
        XCTAssertEqual(session.model.sendText("clear; seq -f 'history line %g' 1 300\r"), .accepted)
        let rows = try await waitForRows(in: session, pane: pane, "the history wasn't printed") {
            $0.contains("history line 300")
        }
        try await waitUntil("Herdr's history didn't reach the pane", timeout: .seconds(15)) {
            pane.surface.scrollRoute == .remoteHistory && pane.surface.scrollState.maxRow >= 200
                && pane.surface.scrollState.offset == pane.surface.scrollState.maxRow
        }
        let line = rows[1]
        XCTAssertTrue(isActive(pane.surface.selectWord(at: cellPoint(row: 1, column: 0, in: session))))
        XCTAssertTrue(isActive(pane.surface.setSelectionEndpoint(
            GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_END,
            at: cellPoint(row: 1, column: line.count - 1, in: session)
        )))
        let selection = pane.surface.historySelection

        // Each step scrolls three lines, which takes the second row below the last.
        let steps = Int(pane.area.height) / 3 + 1
        try scroll(session, pane: pane.id, steps: steps)
        try await waitUntil("Herdr didn't scroll the history", timeout: .seconds(15)) {
            pane.surface.scrollState.maxRow - pane.surface.scrollState.offset == UInt64(3 * steps)
        }
        XCTAssertEqual(pane.surface.selectionSnapshot(), .snapshot(.offScreen), "Herdr \(version)")
        XCTAssertEqual(pane.surface.historySelection, selection)

        try scroll(session, pane: pane.id, steps: -steps)
        try await waitUntil("Herdr didn't scroll back to the bottom", timeout: .seconds(15)) {
            pane.surface.scrollState.offset == pane.surface.scrollState.maxRow
        }
        guard case .snapshot(let back) = pane.surface.selectionSnapshot(), let start = back.start, let end = back.end else {
            return XCTFail("the selection wasn't drawn back")
        }
        XCTAssertEqual(pane.surface.controlSurface.viewportCell(of: start), GhosttyTerminalCell(row: 1, column: 0))
        XCTAssertEqual(pane.surface.controlSurface.viewportCell(of: end)?.row, 1)
        let copied = await session.model.terminalScreenAdapter.selectedText(in: pane.id)
        XCTAssertEqual(copied, line, "Herdr \(version)")
    }

    /// What the screen does on a long-press: selects the link there, else the word.
    @MainActor
    private func longPress(_ pane: SelectionPane, at point: CGPoint) -> GhosttyLongPressSelection? {
        switch pane.surface.selectLink(at: point) {
        case .match(_, let explicitTarget):
            return explicitTarget == nil ? .link : .explicitLink
        case .noMatch:
            return isActive(pane.surface.selectWord(at: point)) ? .word : nil
        case .unavailable:
            return nil
        }
    }

    private struct SelectionPane {
        let id: UUID
        let surface: GhosttyManagedSurface
        let paneID: String
        let area: HerdrSurfaceRect
    }

    /// The session's selected pane, which has a text area.
    @MainActor
    private func selectionPane(of session: ShownSession) throws -> SelectionPane {
        let adapter = session.model.terminalScreenAdapter
        let id = try XCTUnwrap(adapter.terminalInteractionProjection.selectedActiveLeafID)
        let paneID = try XCTUnwrap(session.model.focusedPaneID)
        return SelectionPane(
            id: id,
            surface: try XCTUnwrap(adapter.terminalManagedSurfaceLookup.managedSurface(for: id)),
            paneID: paneID,
            area: try XCTUnwrap(session.model.layout?.panes.first { $0.paneID == paneID }?.innerRect)
        )
    }

    /// The middle of a cell of a pane, in the pane's points.
    @MainActor
    private func cellPoint(row: Int, column: Int, in session: ShownSession) -> CGPoint {
        let metrics = session.model.measurement!.cellMetrics
        return CGPoint(x: (CGFloat(column) + 0.5) * metrics.pointWidth, y: (CGFloat(row) + 0.5) * metrics.pointHeight)
    }

    /// The pane's rows as its renderer shows them, once `condition` holds. Reading them selects, so it
    /// comes before a test's own selection.
    @MainActor
    private func waitForRows(
        in session: ShownSession,
        pane: SelectionPane,
        _ failure: String,
        until condition: ([String]) -> Bool
    ) async throws -> [String] {
        var rows: [String] = []
        try await waitUntil(failure, timeout: .seconds(15)) {
            guard let renderer = session.model.paneSurface(pane.paneID)?.renderer else { return false }
            rows = RendererText.rows(of: renderer, columns: Int(pane.area.width), rows: Int(pane.area.height))
            return condition(rows)
        }
        return rows
    }

    /// The row where `text`, longer than the pane is wide, starts, once the pane shows it wrapped onto
    /// the next row.
    @MainActor
    private func waitForWrappedRows(of text: String, in session: ShownSession, pane: SelectionPane) async throws -> Int {
        let width = Int(pane.area.width)
        let rows = try await waitForRows(in: session, pane: pane, "the pane didn't wrap the text") { rows in
            rows.indices.dropLast().contains { rows[$0] == String(text.prefix(width)) && rows[$0 + 1] == String(text.dropFirst(width)) }
        }
        return rows.indices.dropLast().first { rows[$0] == String(text.prefix(width)) }!
    }

    @MainActor
    private func isActive(_ outcome: GhosttyLocalSelectionOutcome) -> Bool {
        if case .snapshot(let snapshot) = outcome { snapshot.isActive } else { false }
    }

    /// A gesture at the pane's top-left cell whose travel makes `steps` wheel steps, up, or down when
    /// negative.
    @MainActor
    private func scroll(_ session: ShownSession, pane: UUID, steps: Int) throws {
        let adapter = session.model.terminalScreenAdapter
        let cellHeight = Double(try XCTUnwrap(session.model.measurement).cellMetrics.pixelHeight)
        XCTAssertEqual(adapter.sendMousePosition(to: pane, CGPoint(x: 2, y: 2), mods: []), .sent)
        for momentum in [GhosttySurfaceMouseScrollMods.Momentum.began, .ended] {
            let travel = (Double(steps.magnitude) + 0.5) * cellHeight * (steps < 0 ? -1 : 1)
            let event = GhosttySurfaceMouseScrollEvent(
                deltaX: 0,
                deltaY: momentum == .began ? travel : 0,
                mods: .init(precision: true, momentum: momentum)
            )
            XCTAssertEqual(adapter.sendMouseScroll(to: pane, event), .sent)
        }
    }

    /// Starts a program in the session's pane that logs what it reads with the time (`HerdrLiveReadLog`),
    /// after writing `modes` to its terminal.
    @MainActor
    private func startReadLog(in session: ShownSession, modes: String) async throws -> HerdrLiveReadLog {
        let log = HerdrLiveReadLog(fixture: session.fixture, path: session.fixture.root + "/reads.log")
        let program = #"stty raw -echo; printf '"# + modes + #"'; exec perl -MTime::HiRes=time -e 'open(my $f, ">>", shift) or die; $f->autoflush(1); print $f "R\n"; while (sysread(STDIN, my $b, 65536)) { printf $f "%.1f %s\n", time * 1000, unpack("H*", $b) }' "#
        XCTAssertEqual(session.model.sendText(program + log.path + "\r"), .accepted)
        try await log.waitForStart()
        return log
    }

    private struct ShownSession {
        let fixture: HerdrLiveFixture
        let model: HerdrScreenModel
    }

    /// A Herdr session model with Remux's terminal `settings`, on a fresh isolated server for Herdr
    /// `version` with the `ui` settings, shown, with its first pane drawn in a window as on the screen.
    /// `through` can put a transport between the model's connection and the bridge.
    @MainActor
    private func openShownSession(
        version: String,
        settings: TerminalSettings = .default,
        ui: [String] = [],
        through wrap: @escaping @Sendable (any HerdrBridgeTransport) -> any HerdrBridgeTransport
    ) async throws -> ShownSession {
        let fixture = try await HerdrLiveFixture.start(try HerdrLiveConfiguration.load(), version: version, ui: ui)
        addTeardownBlock {
            for problem in await fixture.tearDown() {
                XCTFail(problem)
            }
        }
        let trace = RemuxTransportStartupTrace(flowID: "herdr-live-composer")
        let server = SavedServer(
            displayName: "herdr-live",
            host: fixture.configuration.host,
            port: fixture.configuration.port,
            username: fixture.configuration.username
        )
        let model = HerdrScreenModel(
            target: SessionTarget(
                server: server,
                workspace: SavedWorkspace(serverID: server.id, sessionName: fixture.session),
                sshAuth: .password(
                    username: server.username,
                    password: "",
                    identityID: server.identityID,
                    displayLabel: server.displayName
                ),
                terminalSettings: settings
            ),
            sessionInstanceID: UUID(),
            openBridge: {
                wrap(try await HerdrSSHBridge.open(
                    using: try await fixture.claimRoot(trace: trace),
                    herdrExecutable: fixture.executable,
                    session: fixture.session,
                    trace: trace
                ))
            },
            onRuntimeStateChange: { _ in },
            onNotification: { _ in }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = UIViewController()
        // Teardown blocks run last first, so the model closes its connection before the fixture stops Herdr.
        addTeardownBlock { @MainActor in
            window.isHidden = true
            await model.stop()
        }
        model.terminalScreenAdapter.prepareInitialViewport(size: CGSize(width: 390, height: 844), scale: 3)
        model.setSelected(true)
        try await waitUntil("the first pane wasn't drawn", timeout: .seconds(20)) {
            model.layout?.panes.first(where: \.hasTextArea).flatMap { model.paneSurface($0.paneID) } != nil
        }
        for pane in model.layout?.panes ?? [] {
            if let view = model.paneSurface(pane.paneID)?.renderer.view {
                window.rootViewController?.view.addSubview(view)
            }
        }
        window.isHidden = false
        try await waitUntil("the session didn't take input", timeout: .seconds(20)) { model.isInputAvailable }
        return ShownSession(fixture: fixture, model: model)
    }

    @MainActor
    private func waitUntil(_ failure: String, timeout: Duration, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw HerdrLiveError(description: failure) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func checkTypedInputReachesTheProgram(version: String) async throws {
        let live = try await openLive(version: version)
        let dump = try await startDump(in: live)
        func text(_ text: String) -> [HerdrInputEvent] {
            HerdrInputTranslator.events(forText: text, reportsAllKeys: false)
        }
        func key(_ code: GhosttySurfaceKeyEvent.KeyCode, _ mods: GhosttySurfaceKeyEvent.Mods = []) -> [HerdrInputEvent] {
            HerdrInputTranslator.event(for: GhosttySurfaceKeyEvent(keyCode: code, mods: mods)).map { [$0] } ?? []
        }
        let cases: [(name: String, input: [HerdrInputEvent], bytes: String)] = [
            ("letters", text("aZ"), "aZ"),
            ("non-ASCII", text("é日👍🏽"), "é日👍🏽"),
            ("Ctrl+C", text("\u{03}"), "\u{03}"),
            ("Ctrl+J", text("\n"), "\n"),
            ("Alt+x", text("\u{1b}x"), "\u{1b}x"),
            ("Return", text("\r"), "\r"),
            ("Tab", text("\t"), "\t"),
            ("Delete", text("\u{7f}"), "\u{7f}"),
            ("Escape", text("\u{1b}"), "\u{1b}"),
            ("Up", key(.arrowUp), "\u{1b}[A"),
            ("Alt+Up", key(.arrowUp, [.alt]), "\u{1b}[1;3A"),
            ("Ctrl+Left", key(.arrowLeft, [.ctrl]), "\u{1b}[1;5D"),
            ("Shift+Tab", key(.tab, [.shift]), "\u{1b}[Z"),
            ("Home", key(.home), "\u{1b}[H"),
            ("End", key(.end), "\u{1b}[F"),
            // Unmodified Page Up and Page Down scroll Herdr's own history in a pane that isn't
            // full-screen, so they never reach this program.
            ("Shift+Page Up", key(.pageUp, [.shift]), "\u{1b}[5;2~"),
            ("Forward Delete", key(.delete), "\u{1b}[3~"),
            ("Enter key", key(.enter), "\r"),
            ("Backspace key", key(.backspace), "\u{7f}"),
            ("Escape key", key(.escape), "\u{1b}"),
            ("paste", [.paste("p1\np2")], "p1\np2"),
        ]
        var offset = 1
        for (name, input, bytes) in cases {
            XCTAssertFalse(input.isEmpty, name)
            try await live.connection.send(input, toPane: live.paneID)
            let expected = Array(bytes.utf8)
            let received = try await dump.read(after: offset, count: expected.count)
            guard received == expected else {
                return XCTFail("\(name) on Herdr \(version): got \(hex(received)), want \(hex(expected))")
            }
            offset += expected.count
        }
    }

    private func checkReportAllProgramGetsCommittedText(version: String) async throws {
        let live = try await openLive(version: version)
        let dump = try await startDump(in: live, reportingAllKeys: true)
        try await live.log.waitForKeyboardReportAll(timeout: .seconds(15))

        try await live.connection.send(
            HerdrInputTranslator.events(forText: "日a", reportsAllKeys: true),
            toPane: live.paneID
        )
        let expected = Array((version == "0.9.3" ? "日a" : "日\u{1b}[97u").utf8)
        let received = try await dump.read(after: 1, count: expected.count)
        XCTAssertEqual(hex(received), hex(expected), "Herdr \(version)")
    }

    private struct Live {
        let fixture: HerdrLiveFixture
        let trace: RemuxTransportStartupTrace
        let log: HerdrLiveEventLog
        let connection: HerdrConnection
        let paneID: String
    }

    /// A shown connection to a fresh isolated server for Herdr `version`, and its first pane. `through`
    /// can put a transport between the connection and the bridge.
    private func openLive(
        version: String,
        timing: HerdrConnection.Timing = HerdrConnection.Timing(),
        through wrap: (any HerdrBridgeTransport) -> any HerdrBridgeTransport = { $0 }
    ) async throws -> Live {
        let fixture = try await HerdrLiveFixture.start(try HerdrLiveConfiguration.load(), version: version)
        addTeardownBlock {
            for problem in await fixture.tearDown() {
                XCTFail(problem)
            }
        }
        let trace = RemuxTransportStartupTrace(flowID: "herdr-live-input")
        let log = HerdrLiveEventLog()
        let bridge = try await HerdrSSHBridge.open(
            using: try await fixture.claimRoot(trace: trace),
            herdrExecutable: fixture.executable,
            session: fixture.session,
            trace: trace
        )
        let connection = try await HerdrConnection.open(
            transport: wrap(bridge),
            hello: HerdrHello(cellWidthPx: 9, cellHeightPx: 18, cols: 80, rows: 24, surfaceActive: true),
            appActive: true,
            timing: timing,
            onEvent: { await log.append($0) }
        )
        // Teardown blocks run last first, so the connection closes before the fixture stops Herdr.
        addTeardownBlock { await connection.close(.finished) }
        let paneID = try await log.snapshot(timeout: .seconds(15)) { !$0.panes.isEmpty }.panes[0].paneID
        return Live(fixture: fixture, trace: trace, log: log, connection: connection, paneID: paneID)
    }

    /// Runs a program in the pane that appends every byte it reads to a file. The terminal is in raw
    /// mode, so each byte reaches it unchanged. It writes "R" first, so the file says when it runs;
    /// `reportingAllKeys` makes it ask for every key as an escape code first.
    private func startDump(in live: Live, reportingAllKeys: Bool = false) async throws -> HerdrLiveDump {
        let dump = HerdrLiveDump(fixture: live.fixture, path: live.fixture.root + "/dump.bin")
        let keyboard = reportingAllKeys ? #"printf '\033[>11u'; "# : ""
        try await live.connection.send(
            [.text("stty raw -echo; \(keyboard)printf R > \(dump.path); exec cat >> \(dump.path)\r")],
            toPane: live.paneID
        )
        let started = try await dump.read(after: 0, count: 1, timeout: .seconds(15))
        XCTAssertEqual(started, Array("R".utf8), "the dump didn't start")
        return dump
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

/// A file on the live host that a pane's program writes what it reads to.
struct HerdrLiveDump {
    let fixture: HerdrLiveFixture
    let path: String

    /// The bytes after `offset`, once there are `count` of them or `timeout` passed, and after a short
    /// wait for any more, so a byte too many shows up here and not with the next input.
    func read(after offset: Int, count: Int, timeout: Duration = .seconds(10)) async throws -> [UInt8] {
        let deadline = ContinuousClock.now + timeout
        var bytes = try await contents()
        while bytes.count < offset + count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            bytes = try await contents()
        }
        try await Task.sleep(for: .milliseconds(200))
        return Array(try await contents().dropFirst(offset))
    }

    private func contents() async throws -> [UInt8] {
        let result = try await fixture.run(#"cat -- "$(printf %b "$1")" 2>/dev/null || true"#, arguments: [path])
        return Array(result.stdout)
    }
}

/// What a pane's program read, as the composer test's program logs it: "R" once it runs, then a line for
/// each read with the time it came, in milliseconds, and the bytes in hex.
struct HerdrLiveReadLog {
    struct Read: Sendable {
        let milliseconds: Double
        let bytes: [UInt8]
    }

    let fixture: HerdrLiveFixture
    let path: String

    func waitForStart(timeout: Duration = .seconds(15)) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await lines().first != "R" {
            guard ContinuousClock.now < deadline else { throw HerdrLiveError(description: "the program didn't start") }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// The reads so far, once `done` holds for them or `timeout` passed, and after a short wait for any
    /// more, so a read too many shows up here.
    func reads(timeout: Duration = .seconds(15), until done: @Sendable ([Read]) -> Bool) async throws -> [Read] {
        let deadline = ContinuousClock.now + timeout
        while !done(try await reads()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        try await Task.sleep(for: .milliseconds(500))
        return try await reads()
    }

    private func reads() async throws -> [Read] {
        try await lines().dropFirst().compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count == 2, let milliseconds = Double(fields[0]) else { return nil }
            func nibble(_ digit: UInt8) -> UInt8 {
                digit <= UInt8(ascii: "9") ? digit - UInt8(ascii: "0") : digit - UInt8(ascii: "a") + 10
            }
            let hex = Array(fields[1].utf8)
            let bytes = stride(from: 0, to: hex.count - 1, by: 2).map { nibble(hex[$0]) << 4 | nibble(hex[$0 + 1]) }
            return Read(milliseconds: milliseconds, bytes: bytes)
        }
    }

    private func lines() async throws -> [String] {
        let result = try await fixture.run(#"cat -- "$(printf %b "$1")" 2>/dev/null || true"#, arguments: [path])
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

/// Passes a bridge through as a slow uplink does: a write returns at once, and its bytes reach the bridge
/// at `bytesPerSecond`, in order.
actor HerdrLiveSlowUplink: HerdrBridgeTransport {
    private let bridge: any HerdrBridgeTransport
    private let bytesPerSecond: Int
    private var queued: [[UInt8]] = []
    private var isSending = false

    init(_ bridge: any HerdrBridgeTransport, bytesPerSecond: Int) {
        self.bridge = bridge
        self.bytesPerSecond = bytesPerSecond
    }

    func read() async throws -> [UInt8]? {
        try await bridge.read()
    }

    func write(_ bytes: [UInt8]) async throws {
        queued.append(bytes)
        guard !isSending else { return }
        isSending = true
        Task { await sendQueued() }
    }

    private func sendQueued() async {
        while !queued.isEmpty {
            let bytes = queued.removeFirst()
            try? await Task.sleep(for: .seconds(Double(bytes.count) / Double(bytesPerSecond)))
            try? await bridge.write(bytes)
        }
        isSending = false
    }

    func close(_ cause: HerdrBridgeCloseCause) async {
        await bridge.close(cause)
    }
}

/// Passes a bridge through and counts the health pings written to it.
actor HerdrLivePingCounter: HerdrBridgeTransport {
    private let bridge: any HerdrBridgeTransport
    private(set) var count = 0

    init(_ bridge: any HerdrBridgeTransport) {
        self.bridge = bridge
    }

    func read() async throws -> [UInt8]? {
        try await bridge.read()
    }

    func write(_ bytes: [UInt8]) async throws {
        var reader = HerdrWireReader(Array(bytes.dropFirst(4)))
        if (try? reader.variant()) == 20, (try? reader.string()) == HerdrControlKind.healthPing {
            count += 1
        }
        try await bridge.write(bytes)
    }

    func close(_ cause: HerdrBridgeCloseCause) async {
        await bridge.close(cause)
    }
}

/// Records a live connection's events for the test to wait on.
/// When the composer's paste was delivered and its Enter sent, as the test's own closures see them.
@MainActor
private final class ComposerTimes {
    var pasteDelivered: ContinuousClock.Instant?
    var enterSent: ContinuousClock.Instant?
}

actor HerdrLiveEventLog {
    private var snapshots: [HerdrSnapshot] = []
    private(set) var surfaceCount = 0
    private(set) var reportsAllKeys = false
    private(set) var endReason: HerdrConnectionError?
    /// Each request's reply, once its last chunk is in, and the chunks of those still coming.
    private var replies: [String: [UInt8]] = [:]
    private var partialReplies: [String: [UInt8]] = [:]

    func append(_ event: HerdrConnectionEvent) {
        switch event {
        case .snapshot(let snapshot, _):
            snapshots.append(snapshot)
        case .response(let chunk):
            partialReplies[chunk.requestID, default: []] += chunk.data
            if chunk.isFinal { replies[chunk.requestID] = partialReplies.removeValue(forKey: chunk.requestID) }
        case .surface:
            surfaceCount += 1
        case .ended(let reason):
            endReason = reason
        case .keyboardReportAll(let enabled):
            reportsAllKeys = enabled
        case .bell, .notification, .clipboard, .inputRefused:
            break
        }
    }

    /// Waits for Herdr to say the focused pane asks for every key.
    func waitForKeyboardReportAll(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while !reportsAllKeys, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard reportsAllKeys else {
            throw HerdrLiveError(description: "Herdr didn't report that the pane asks for every key")
        }
    }

    /// Herdr's whole reply to the request `id`, waiting up to `timeout` for it.
    func reply(to id: String, timeout: Duration) async throws -> [UInt8] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let reply = replies[id] { return reply }
            if let endReason { throw endReason }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HerdrLiveError(description: "Herdr didn't answer \(id) within \(timeout)")
    }

    /// The newest snapshot that satisfies `condition`, waiting up to `timeout` for one.
    func snapshot(
        timeout: Duration,
        where condition: @Sendable (HerdrSnapshot) -> Bool
    ) async throws -> HerdrSnapshot {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let match = snapshots.last(where: condition) { return match }
            if let endReason { throw endReason }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HerdrLiveError(description: "no matching Herdr snapshot within \(timeout)")
    }
}
