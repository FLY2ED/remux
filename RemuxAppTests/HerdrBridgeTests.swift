import Foundation
import NIOCore
import XCTest
@testable import Remux

/// The launch command, the ready marker, and the bridge transport on a real SSH channel (an in-process
/// SSH server).
final class HerdrBridgeTests: XCTestCase {
    // MARK: - Launch command

    func testCommandKeepsTheExecutableAndSessionOutOfTheLoginShell() {
        let executable = "/home/owner's tools/herdr; touch pwned"
        let session = "work'; rm -rf ~"

        let command = HerdrSSHBridge.command(herdrExecutable: executable, session: session)

        XCTAssertTrue(command.hasPrefix("exec /bin/sh -c '"))
        XCTAssertFalse(command.contains(executable))
        XCTAssertFalse(command.contains(session))
        XCTAssertTrue(command.hasSuffix(
            " remux \(RemoteShellArgument.octalEncoded(executable)) \(RemoteShellArgument.octalEncoded(session))"
        ))
    }

    /// The script sits inside single quotes, so a single quote in it would end the quoting early: only
    /// the script's two and each argument's two may appear.
    func testScriptContainsNoSingleQuote() {
        let command = HerdrSSHBridge.command(herdrExecutable: "herdr", session: "default")
        XCTAssertEqual(command.filter { $0 == "'" }.count, 6)
        let discovery = HerdrSessionDiscovery.listSessionsCommand(herdrExecutable: "herdr")
        XCTAssertEqual(discovery.filter { $0 == "'" }.count, 4)
    }

    /// Herdr's ready marker comes first, then the search with the places Herdr's client looks.
    func testScriptPrintsTheReadyMarkerThenFindsHerdrWhereHerdrsClientLooks() {
        let command = HerdrSSHBridge.command(herdrExecutable: "herdr", session: "default")
        XCTAssertTrue(command.hasPrefix(#"exec /bin/sh -c 'printf "\n%s\n" "herdr-remote-output-ready:1"; "#))
        for directory in [
            "$HOME/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/home/linuxbrew/.linuxbrew/bin",
            "$HOME/.nix-profile/bin", "/etc/profiles/per-user/${USER:-}/bin",
            "/nix/var/nix/profiles/default/bin", "/run/current-system/sw/bin",
        ] {
            XCTAssertTrue(command.contains(directory), directory)
        }
    }

    func testCommandAsksForTheIdleTimeoutOnlyWhereHerdrReportsIt() {
        let command = HerdrSSHBridge.command(herdrExecutable: "herdr", session: "default")
        XCTAssertTrue(command.contains(#""$resolved" status client --json"#))
        XCTAssertTrue(command.contains(#"remote_bridge_idle_timeout\": *true"#))
        XCTAssertTrue(command.contains(#"--session "$session" remote-client-bridge --idle-timeout-v1"#))
        XCTAssertTrue(command.contains(#"exec "$resolved" --session "$session" remote-client-bridge' remux"#))
    }

    // MARK: - Ready marker

    /// As Herdr's client: output starts after the line that is exactly the marker (a trailing carriage
    /// return allowed), however the stream is split.
    func testOutputStartsAfterTheReadyMarkersLine() {
        let stream = Array("motd herdr-remote-output-ready:1 not alone\nherdr-remote-output-ready:10\n\nherdr-remote-output-ready:1\r\npayload".utf8)
        for split in [1, 3, 7, stream.count] {
            var line = HerdrRemoteCommand.ReadyLine()
            var output: [UInt8] = []
            for start in stride(from: 0, to: stream.count, by: split) {
                output += line.output(from: stream[start..<min(start + split, stream.count)])
            }
            XCTAssertTrue(line.isFound, "split \(split)")
            XCTAssertEqual(String(decoding: output, as: UTF8.self), "payload", "split \(split)")
        }
        var missing = HerdrRemoteCommand.ReadyLine()
        XCTAssertEqual(missing.output(from: Array("no marker here\n".utf8)), [])
        XCTAssertFalse(missing.isFound)
    }

    // MARK: - On an SSH channel

    /// Stderr, here from the server's startup files, takes a read of its own; the bridge asks again,
    /// so the stdout behind it still arrives.
    func testStderrDoesNotStallTheStream() async throws {
        let bridge = try await openBridge(steps: [
            SSHPublicKeyLiveExecStep(type: .stdErr, data: Data("stty: not a tty\n".utf8)),
            SSHPublicKeyLiveExecStep(type: .channel, data: Self.readyLine + Data("payload".utf8), delay: .milliseconds(100)),
        ])
        let bytes = try await Self.read(from: bridge, count: 7)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "payload")
        await bridge.close(reusable: true)
    }

    /// What the server's startup files print before the marker never reaches the protocol.
    func testStartupOutputIsSkipped() async throws {
        let bridge = try await openBridge(steps: [
            SSHPublicKeyLiveExecStep(type: .channel, data: Data("Welcome to the server\n".utf8)),
            SSHPublicKeyLiveExecStep(type: .channel, data: Self.readyLine, delay: .milliseconds(50)),
            SSHPublicKeyLiveExecStep(type: .channel, data: Data("payload".utf8), delay: .milliseconds(50)),
        ])
        let bytes = try await Self.read(from: bridge, count: 7)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "payload")
        await bridge.close(reusable: true)
    }

    /// More than one SSH window (2 MiB) arrives over several reads, from a single server write that the
    /// server splits into packets and sends as the window refills.
    func testMoreThanOneWindowArrivesOverReads() async throws {
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0) })
        let bridge = try await openBridge(steps: [
            SSHPublicKeyLiveExecStep(type: .channel, data: Self.readyLine + payload),
        ])
        let bytes = try await Self.read(from: bridge, count: payload.count)
        XCTAssertEqual(Data(bytes), payload)
        await bridge.close(reusable: true)
    }

    /// On a dead path the server never answers the channel close; closing still ends the waiting read
    /// at once.
    func testCloseEndsAWaitingReadWithoutTheServersAnswer() async throws {
        let server = try await SSHPublicKeyLiveTestServer.start(username: "remux")
        defer { server.stop() }
        let bridge = try await openBridge(on: server)
        let reading = Task { try await bridge.read() }
        try await Task.sleep(for: .milliseconds(50))
        try await server.stopReadingFromClients()
        let started = ContinuousClock.now
        await bridge.close(reusable: false)
        let result = try await reading.value
        XCTAssertNil(result)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        do {
            try await bridge.write([1])
            XCTFail("wrote after the end")
        } catch let error as HerdrBridgeError {
            XCTAssertEqual(error, .channel("the bridge has ended"))
        }
    }

    /// A write the server never takes (it stopped reading, so the SSH window never refills) fails at once
    /// when the bridge closes, also on a reusable close, where the SSH connection stays open for others.
    func testCloseFailsAWriteTheServerNeverTakes() async throws {
        let server = try await SSHPublicKeyLiveTestServer.start(username: "remux")
        defer { server.stop() }
        let (bridge, _) = try await openBridgeAndRoot(on: server)
        try await server.stopReadingFromClients()
        let outcome = WriteOutcome()
        // Four times the 2 MiB window.
        let bytes = [UInt8](repeating: 0x61, count: 8 * 1024 * 1024)
        Task {
            do {
                try await bridge.write(bytes)
                outcome.record(.success(()))
            } catch {
                outcome.record(.failure(error))
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(outcome.result, "the write finished although the server stopped reading")

        let started = ContinuousClock.now
        await bridge.close(reusable: true)
        while outcome.result == nil, ContinuousClock.now - started < .seconds(2) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .failure(let error)? = outcome.result else {
            XCTFail("the write didn't fail when the bridge closed: \(String(describing: outcome.result))")
            return
        }
        XCTAssertEqual(error as? HerdrBridgeError, .channel("the bridge has ended"))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
    }

    /// A close for a path that went silent gives the SSH connection back without the server's answer,
    /// so a connection nobody else uses (here a dedicated one) closes at once.
    func testAnUnreusableCloseReleasesTheSSHConnectionWithoutTheServersAnswer() async throws {
        let server = try await SSHPublicKeyLiveTestServer.start(username: "remux")
        defer { server.stop() }
        let (bridge, root) = try await openBridgeAndRoot(on: server)
        try await server.stopReadingFromClients()

        let started = ContinuousClock.now
        await bridge.close(reusable: false)
        while root.sshRoot.rootChannel.isActive, ContinuousClock.now - started < .seconds(2) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(root.sshRoot.rootChannel.isActive, "the SSH connection is still open")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
    }

    // MARK: - Helpers

    private static let readyLine = Data("\nherdr-remote-output-ready:1\n".utf8)

    private func openBridge(steps: [SSHPublicKeyLiveExecStep]) async throws -> HerdrSSHBridge {
        let server = try await SSHPublicKeyLiveTestServer.start(username: "remux", execSteps: steps)
        addTeardownBlock { server.stop() }
        return try await openBridge(on: server)
    }

    private func openBridge(on server: SSHPublicKeyLiveTestServer) async throws -> HerdrSSHBridge {
        try await openBridgeAndRoot(on: server).bridge
    }

    /// The bridge on a dedicated SSH connection, which the test closes afterwards whatever the bridge
    /// left open.
    private func openBridgeAndRoot(
        on server: SSHPublicKeyLiveTestServer
    ) async throws -> (bridge: HerdrSSHBridge, root: RemuxSSHClaimedRoot) {
        let trace = RemuxTransportStartupTrace(flowID: "herdr-bridge-test")
        let root = try await claimedLoopbackRoot(server: server, trace: trace)
        addTeardownBlock { await root.sshRoot.close() }
        let bridge = try await HerdrSSHBridge.open(
            using: root,
            herdrExecutable: "herdr",
            session: "default",
            trace: trace
        )
        return (bridge, root)
    }

    /// Reads until `count` bytes arrived, failing after five seconds.
    private static func read(from bridge: HerdrSSHBridge, count: Int) async throws -> [UInt8] {
        try await withThrowingTaskGroup(of: [UInt8].self) { group in
            group.addTask {
                var bytes: [UInt8] = []
                while bytes.count < count, let chunk = try await bridge.read() {
                    bytes += chunk
                }
                return bytes
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                await bridge.close(reusable: true)
                return []
            }
            let first = try await group.next() ?? []
            group.cancelAll()
            return first
        }
    }
}

/// How a write ended, for a test that can't await a write that may never return.
private final class WriteOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Void, Error>?

    var result: Result<Void, Error>? {
        lock.withLock { stored }
    }

    func record(_ result: Result<Void, Error>) {
        lock.withLock { stored = result }
    }
}

