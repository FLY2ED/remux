import Foundation
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
        addTeardownBlock { await connection.close() }
        XCTAssertTrue(connection.negotiated.delta)
        XCTAssertTrue(connection.negotiated.scroll)

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

        _ = try await live.connection.command(HerdrScreenModel.paneFocusMethod, params: ["pane_id": other])
        _ = try await live.log.snapshot(timeout: .seconds(15)) { $0.focusedPaneID == other }
    }

    // MARK: - Showing

    /// Hidden and shown again, the session takes no input until Herdr's show completes, then takes it
    /// again: Herdr answers the show and sends a frame at the phone's size.
    func testAShownAgainSessionTakesInputOnceTheShowCompletesOnHerdr093() async throws {
        try await checkShownAgainSessionTakesInput(version: "0.9.3")
    }

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

    /// Remux's composer sends a message to a Herdr pane as one paste, then Enter in a read of its own at
    /// least the composer's pause later, so a program sees the paste settle before Enter. The program
    /// asks for bracketed paste, as agents' prompts do; the message starts with a slash, which opens a
    /// command menu in some agents.
    @MainActor
    func testAComposedMessageArrivesAsAPasteThenEnterAfterThePauseOnHerdr093() async throws {
        try await checkComposedMessage(version: "0.9.3", message: Self.composedMessage)
    }

    @MainActor
    func testAComposedMessageArrivesAsAPasteThenEnterAfterThePauseOnHerdr095() async throws {
        try await checkComposedMessage(version: "0.9.5", message: Self.composedMessage)
    }

    /// Over a slow uplink a long paste is still arriving well after the phone wrote it. The pause before
    /// Enter runs once Herdr has the paste, so Enter still comes on its own, the pause after the paste.
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
        // As the screen sends a composed message.
        composer.submit(to: GhosttyComposerSubmissionDestination(
            workspaceID: session.model.target.workspace.id,
            surfaceID: surfaceID,
            destinationLabel: nil,
            makeAttachmentTransferService: { FailingComposerAttachmentTransferService() },
            prepareTerminalInput: {},
            sendPaste: { await adapter.sendPasteAwaitingCommandCompletion($0, to: surfaceID) },
            sendEnter: {
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
        let gap = enter.milliseconds - reads[reads.count - 2].milliseconds
        XCTAssertGreaterThanOrEqual(gap, 150, "Enter came \(gap) ms after the paste on Herdr \(version)")
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

    /// A gesture at the pane's top-left cell whose travel makes `steps` wheel steps up.
    @MainActor
    private func scroll(_ session: ShownSession, pane: UUID, steps: Int) throws {
        let adapter = session.model.terminalScreenAdapter
        let cellHeight = Double(try XCTUnwrap(session.model.measurement).cellMetrics.pixelHeight)
        XCTAssertEqual(adapter.sendMousePosition(to: pane, CGPoint(x: 2, y: 2), mods: []), .sent)
        for momentum in [GhosttySurfaceMouseScrollMods.Momentum.began, .ended] {
            let event = GhosttySurfaceMouseScrollEvent(
                deltaX: 0,
                deltaY: momentum == .began ? (Double(steps) + 0.5) * cellHeight : 0,
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

    /// A Herdr session model on a fresh isolated server for Herdr `version`, shown, with its first pane
    /// drawn in a window as on the screen. `through` can put a transport between the model's connection
    /// and the bridge.
    @MainActor
    private func openShownSession(
        version: String,
        through wrap: @escaping @Sendable (any HerdrBridgeTransport) -> any HerdrBridgeTransport
    ) async throws -> ShownSession {
        let fixture = try await HerdrLiveFixture.start(try HerdrLiveConfiguration.load(), version: version)
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
                terminalSettings: .default
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
            onRuntimeStateChange: { _ in }
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
        addTeardownBlock { await connection.close() }
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

    func close(reusable: Bool) async {
        await bridge.close(reusable: reusable)
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

    func close(reusable: Bool) async {
        await bridge.close(reusable: reusable)
    }
}

/// Records a live connection's events for the test to wait on.
actor HerdrLiveEventLog {
    private var snapshots: [HerdrSnapshot] = []
    private(set) var surfaceCount = 0
    private(set) var reportsAllKeys = false
    private(set) var endReason: HerdrConnectionError?

    func append(_ event: HerdrConnectionEvent) {
        switch event {
        case .snapshot(let snapshot):
            snapshots.append(snapshot)
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
