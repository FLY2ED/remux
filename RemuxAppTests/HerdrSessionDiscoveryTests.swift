import Foundation
import XCTest
@testable import Remux

final class HerdrSessionDiscoveryTests: XCTestCase {
    // `herdr session list --json` output from a real run; v0.9.3 serializes
    // the same `SessionInfo` fields.
    private let sessionListJSON = #"{"sessions":[{"default":true,"name":"default","running":false,"session_dir":"/private/tmp/rpp-herdr/h/.config/herdr","socket_path":"/private/tmp/rpp-herdr/h/.config/herdr/herdr.sock"},{"default":false,"name":"probe","running":true,"session_dir":"/private/tmp/rpp-herdr/h/.config/herdr/sessions/probe","socket_path":"/private/tmp/rpp-herdr/h/.config/herdr/sessions/probe/herdr.sock"}]}"#

    func testListCommandKeepsConfiguredExecutableOutOfLoginShellSyntax() {
        let executable = "/home/owner's tools/herdr; touch pwned"

        let command = HerdrSessionDiscovery.listSessionsCommand(herdrExecutable: executable)

        XCTAssertTrue(command.hasPrefix("exec /bin/sh -c '"))
        XCTAssertTrue(command.contains(#"exec "$resolved" session list --json"#))
        XCTAssertFalse(command.contains(executable))
        XCTAssertFalse(command.contains("touch pwned"))
    }

    func testListsRunningAndStoppedSessionsAndWhereHerdrIs() throws {
        let listing = try HerdrSessionDiscovery.listing(
            from: result(stdout: "/usr/local/bin/herdr\nherdr 0.9.3\n\(sessionListJSON)\n")
        )

        XCTAssertEqual(listing, SessionListing(executablePath: "/usr/local/bin/herdr", sessions: [
            DiscoveredSession(name: "default", isRunning: false),
            DiscoveredSession(name: "probe", isRunning: true),
        ]))
    }

    /// From v0.9.4, a session Herdr can't reach carries its reason, as Herdr's own list marks it
    /// unavailable (`session.rs`, `cli.rs`).
    func testASessionHerdrCannotReachCarriesItsReason() throws {
        let json = #"{"sessions":[{"connection_error":"Permission denied (os error 13)","default":false,"name":"locked","running":false,"session_dir":"/h/.config/herdr/sessions/locked","socket_path":"/h/.config/herdr/sessions/locked/herdr.sock"},{"default":false,"name":"open","running":true,"session_dir":"/h/.config/herdr/sessions/open","socket_path":"/h/.config/herdr/sessions/open/herdr.sock"}]}"#
        let listing = try HerdrSessionDiscovery.listing(from: result(stdout: "/usr/local/bin/herdr\nherdr 0.9.5\n\(json)\n"))

        XCTAssertEqual(listing.sessions, [
            DiscoveredSession(name: "locked", isRunning: false, unavailableReason: "Permission denied (os error 13)"),
            DiscoveredSession(name: "open", isRunning: true),
        ])
    }

    /// A missing Herdr is an error, not an empty list, so the app can tell it apart from a Herdr without
    /// sessions. Captured on Debian.
    func testMissingHerdrIsNotFound() {
        XCTAssertThrowsError(
            try HerdrSessionDiscovery.listing(from: RemuxSSHExecResult(
                exitStatus: 127,
                stdout: Data(),
                stderr: Data("remux: not found: herdr\n".utf8)
            ))
        ) { error in
            XCTAssertEqual(error as? RemoteProgramFailure, .notFound)
        }
    }

    /// Captured on Debian: Herdr's version prints, then its session list fails.
    func testAHerdrThatFailsSaysWhy() {
        XCTAssertThrowsError(
            try HerdrSessionDiscovery.listing(from: result(
                exitStatus: 1,
                stdout: "/usr/local/bin/herdr\nherdr 0.9.5\n",
                stderr: "\n\(RemoteProgramCommand.readyMarker)\nherdr: something went wrong\n"
            ))
        ) { error in
            XCTAssertEqual(error as? RemoteProgramFailure, .failed("herdr: something went wrong"))
        }
    }

    /// Without the marker the run never got to Herdr: the login shell failed.
    func testALoginShellThatFailsIsNotHerdrs() {
        let stderr = "This account is currently not available.\n"
        XCTAssertThrowsError(
            try HerdrSessionDiscovery.listing(from: RemuxSSHExecResult(
                exitStatus: 1,
                stdout: Data(),
                stderr: Data(stderr.utf8)
            ))
        ) { error in
            XCTAssertEqual(error as? HerdrSessionDiscoveryError, .remoteExit(status: 1, stderr: stderr))
        }
    }

    func testHerdrOlderThanTheMinimumIsRefused() {
        XCTAssertThrowsError(
            try HerdrSessionDiscovery.listing(
                from: result(stdout: "/usr/local/bin/herdr\nherdr 0.9.0\n\(sessionListJSON)\n")
            )
        ) { error in
            XCTAssertEqual(
                error as? HerdrSessionDiscoveryError,
                .unsupportedVersion(HerdrVersion(major: 0, minor: 9, patch: 0))
            )
        }
    }

    func testNewerHerdrIsAccepted() throws {
        let listing = try HerdrSessionDiscovery.listing(
            from: result(stdout: "/usr/local/bin/herdr\nherdr 1.0.0\n\(sessionListJSON)\n")
        )

        XCTAssertEqual(listing.sessions.map(\.name), ["default", "probe"])
    }

    func testUnreadableVersionIsAnError() {
        XCTAssertThrowsError(
            try HerdrSessionDiscovery.listing(from: result(stdout: "/usr/local/bin/herdr\nherdr\n\(sessionListJSON)\n"))
        ) { error in
            XCTAssertEqual(error as? HerdrSessionDiscoveryError, .unreadableVersion("herdr"))
        }
    }

    /// What the server's startup files print before the ready marker is not the command's output.
    func testStartupOutputBeforeTheReadyMarkerIsSkipped() throws {
        let listing = try HerdrSessionDiscovery.listing(
            from: result(
                stdout: "Welcome, last login yesterday\nherdr 0.1.0\n",
                readyThen: "/usr/local/bin/herdr\nherdr 0.9.3\n\(sessionListJSON)\n"
            )
        )
        XCTAssertEqual(listing.sessions.map(\.name), ["default", "probe"])
    }

    func testOutputWithoutTheReadyMarkerIsAnError() {
        XCTAssertThrowsError(
            try HerdrSessionDiscovery.listing(
                from: RemuxSSHExecResult(
                    exitStatus: 0,
                    stdout: Data("/usr/local/bin/herdr\nherdr 0.9.3\n\(sessionListJSON)\n".utf8),
                    stderr: Data()
                )
            )
        ) { error in
            XCTAssertEqual(error as? HerdrSessionDiscoveryError, .incompleteOutput)
        }
    }

    func testInvalidSessionListIsAnError() {
        XCTAssertThrowsError(
            try HerdrSessionDiscovery.listing(from: result(stdout: "/usr/local/bin/herdr\nherdr 0.9.3\nnot json\n"))
        ) { error in
            XCTAssertEqual(error as? HerdrSessionDiscoveryError, .invalidSessionList)
        }
    }

    /// A run whose stdout is `stdout` (startup output), the ready marker line, then `readyThen`, or
    /// with `stdout` alone after the marker.
    private func result(
        exitStatus: Int = 0,
        stdout: String = "",
        readyThen: String? = nil,
        stderr: String = ""
    ) -> RemuxSSHExecResult {
        let marker = "\n\(RemoteProgramCommand.readyMarker)\n"
        let output = readyThen.map { stdout + marker + $0 } ?? marker + stdout
        return RemuxSSHExecResult(
            exitStatus: exitStatus,
            stdout: Data(output.utf8),
            stderr: Data(stderr.utf8)
        )
    }
}
