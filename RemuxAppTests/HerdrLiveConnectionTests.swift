import Foundation
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

    /// A shown connection to a fresh isolated server for Herdr `version`, and its first pane.
    private func openLive(version: String) async throws -> Live {
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
            transport: bridge,
            hello: HerdrHello(cellWidthPx: 9, cellHeightPx: 18, cols: 80, rows: 24, surfaceActive: true),
            appActive: true,
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
