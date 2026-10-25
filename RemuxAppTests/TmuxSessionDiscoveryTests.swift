import Foundation
import XCTest
@testable import Remux

/// The runs below were captured from the app's command on Debian (dash), with a fake tmux and with tmux 3.3a;
/// the version mismatch is tmux's own message (client.c).
final class TmuxSessionDiscoveryTests: XCTestCase {
    func testListCommandKeepsConfiguredExecutableOutOfLoginShellSyntax() {
        let executable = "/home/owner's tools/tmux; touch pwned"

        let command = SSHTmuxControlCommandBuilder.listSessionsCommand(
            tmuxExecutable: executable
        )

        XCTAssertTrue(command.hasPrefix("exec /bin/sh -c '"))
        XCTAssertTrue(command.contains("LC_ALL=C; export LC_ALL"))
        XCTAssertTrue(command.contains(##"printf "%s\n" "$resolved"; exec "$resolved" list-sessions -F "#{session_name}""##))
        XCTAssertFalse(command.contains(executable))
        XCTAssertFalse(command.contains("touch pwned"))
    }

    func testListsTheSessionsAndWhereTmuxIs() throws {
        let listing = try TmuxSessionDiscovery.listing(from: result(
            exitStatus: 0,
            stdout: "\nremux-ready:1\n/usr/local/bin/tmux\nmain\nwork\n",
            stderr: "\nremux-ready:1\n"
        ))

        XCTAssertEqual(listing, SessionListing(
            executablePath: "/usr/local/bin/tmux",
            sessions: [DiscoveredSession(name: "main", isRunning: true), DiscoveredSession(name: "work", isRunning: true)]
        ))
    }

    /// What the server's startup files print before the ready marker is not a session.
    func testStartupOutputIsNotASession() throws {
        let listing = try TmuxSessionDiscovery.listing(from: result(
            exitStatus: 0,
            stdout: "Welcome to Ubuntu\nlast login yesterday\n\nremux-ready:1\n/usr/bin/tmux\nmain\n"
        ))

        XCTAssertEqual(listing.sessions.map(\.name), ["main"])
    }

    func testNamesKeepTheirWhitespaceOnceEachAndAcceptCRLF() throws {
        let listing = try TmuxSessionDiscovery.listing(from: result(
            exitStatus: 0,
            stdout: "\nremux-ready:1\n/usr/bin/tmux\nmain\r\n  spaced  \nmain\n\nops\r\n"
        ))

        XCTAssertEqual(listing.sessions.map(\.name), ["main", "  spaced  ", "ops"])
    }

    func testInvalidUTF8IsAnError() {
        XCTAssertThrowsError(try TmuxSessionDiscovery.listing(from: RemuxSSHExecResult(
            exitStatus: 0,
            stdout: Data("\nremux-ready:1\n".utf8) + Data([0xFF]),
            stderr: Data()
        ))) {
            XCTAssertEqual($0 as? TmuxSessionDiscoveryError, .invalidUTF8)
        }
    }

    func testOutputWithoutTheReadyMarkerIsAnError() {
        XCTAssertThrowsError(
            try TmuxSessionDiscovery.listing(from: result(exitStatus: 0, stdout: "/usr/bin/tmux\nmain\n"))
        ) {
            XCTAssertEqual($0 as? TmuxSessionDiscoveryError, .incompleteOutput)
        }
    }

    /// tmux runs, with no server: no sessions.
    func testATmuxWithoutAServerHasNoSessions() throws {
        let messages = [
            "error connecting to /tmp/tmux-1000/default (No such file or directory)\n",
            "no server running on /private/tmp/tmux-501/default\n",
        ]
        for message in messages {
            let listing = try TmuxSessionDiscovery.listing(from: result(
                exitStatus: 1,
                stdout: "\nremux-ready:1\n/usr/local/bin/tmux\n",
                stderr: "\nremux-ready:1\n" + message
            ))
            XCTAssertEqual(listing, SessionListing(executablePath: "/usr/local/bin/tmux", sessions: []))
        }
    }

    func testMissingTmuxIsNotFound() {
        XCTAssertThrowsError(
            try TmuxSessionDiscovery.listing(from: result(exitStatus: 127, stderr: "remux: not found: tmux\n"))
        ) {
            XCTAssertEqual($0 as? RemoteProgramFailure, .notFound)
        }
    }

    func testATmuxTheServerCannotStartSaysWhy() {
        XCTAssertThrowsError(try TmuxSessionDiscovery.listing(from: result(
            exitStatus: 126,
            stdout: "\nremux-ready:1\n/opt/tools/tmux\n",
            stderr: "\nremux-ready:1\nsh: 1: exec: /opt/tools/tmux: Exec format error\n"
        ))) {
            XCTAssertEqual($0 as? RemoteProgramFailure, .couldNotStart("sh: 1: exec: /opt/tools/tmux: Exec format error"))
        }
    }

    func testATmuxThatFailsSaysWhy() {
        XCTAssertThrowsError(try TmuxSessionDiscovery.listing(from: result(
            exitStatus: 1,
            stdout: "\nremux-ready:1\n/usr/bin/tmux\n",
            stderr: "\nremux-ready:1\nprotocol version mismatch (client 8, server 7)\n"
        ))) {
            XCTAssertEqual($0 as? RemoteProgramFailure, .failed("protocol version mismatch (client 8, server 7)"))
        }
    }

    /// Without the marker the run never got to tmux: the login shell failed.
    func testALoginShellThatFailsIsNotTmuxs() {
        let stderr = "This account is currently not available.\n"
        XCTAssertThrowsError(try TmuxSessionDiscovery.listing(from: result(exitStatus: 1, stderr: stderr))) {
            XCTAssertEqual($0 as? TmuxSessionDiscoveryError, .remoteExit(status: 1, stderr: stderr))
        }
    }

    private func result(
        exitStatus: Int,
        stdout: String = "",
        stderr: String = ""
    ) -> RemuxSSHExecResult {
        RemuxSSHExecResult(
            exitStatus: exitStatus,
            stdout: Data(stdout.utf8),
            stderr: Data(stderr.utf8)
        )
    }
}
