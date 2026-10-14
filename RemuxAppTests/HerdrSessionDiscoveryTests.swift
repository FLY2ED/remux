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

    func testListsRunningAndStoppedSessions() throws {
        let sessions = try HerdrSessionDiscovery.sessions(
            from: result(stdout: "herdr 0.9.3\n\(sessionListJSON)\n")
        )

        XCTAssertEqual(sessions, [
            HerdrDiscoveredSession(name: "default", isRunning: false),
            HerdrDiscoveredSession(name: "probe", isRunning: true),
        ])
    }

    func testMissingHerdrHasNoSessions() throws {
        let sessions = try HerdrSessionDiscovery.sessions(
            from: result(
                exitStatus: 127,
                stderr: "\(HerdrSessionDiscovery.herdrNotFoundMarker): herdr\n"
            )
        )

        XCTAssertEqual(sessions, [])
    }

    func testHerdrThatCannotRunIsAnError() {
        let stderr = "\(HerdrSessionDiscovery.herdrNotExecutableMarker): /opt/herdr\n"

        XCTAssertThrowsError(
            try HerdrSessionDiscovery.sessions(from: result(exitStatus: 126, stderr: stderr))
        ) { error in
            XCTAssertEqual(
                error as? HerdrSessionDiscoveryError,
                .remoteExit(status: 126, stderr: stderr)
            )
        }
    }

    func testExit127WithoutTheMarkerIsAnError() {
        XCTAssertThrowsError(
            try HerdrSessionDiscovery.sessions(
                from: result(exitStatus: 127, stderr: "sh: something else failed\n")
            )
        )
    }

    func testHerdrOlderThanTheMinimumIsRefused() {
        XCTAssertThrowsError(
            try HerdrSessionDiscovery.sessions(
                from: result(stdout: "herdr 0.9.0\n\(sessionListJSON)\n")
            )
        ) { error in
            XCTAssertEqual(
                error as? HerdrSessionDiscoveryError,
                .unsupportedVersion(HerdrVersion(major: 0, minor: 9, patch: 0))
            )
        }
    }

    func testNewerHerdrIsAccepted() throws {
        let sessions = try HerdrSessionDiscovery.sessions(
            from: result(stdout: "herdr 1.0.0\n\(sessionListJSON)\n")
        )

        XCTAssertEqual(sessions.map(\.name), ["default", "probe"])
    }

    func testUnreadableVersionIsAnError() {
        XCTAssertThrowsError(
            try HerdrSessionDiscovery.sessions(from: result(stdout: "herdr\n\(sessionListJSON)\n"))
        ) { error in
            XCTAssertEqual(error as? HerdrSessionDiscoveryError, .unreadableVersion("herdr"))
        }
    }

    func testInvalidSessionListIsAnError() {
        XCTAssertThrowsError(
            try HerdrSessionDiscovery.sessions(from: result(stdout: "herdr 0.9.3\nnot json\n"))
        ) { error in
            XCTAssertEqual(error as? HerdrSessionDiscoveryError, .invalidSessionList)
        }
    }

    private func result(
        exitStatus: Int = 0,
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
