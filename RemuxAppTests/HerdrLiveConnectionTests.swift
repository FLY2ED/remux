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
}

/// Records a live connection's events for the test to wait on.
actor HerdrLiveEventLog {
    private var snapshots: [HerdrSnapshot] = []
    private(set) var surfaceCount = 0
    private(set) var endReason: HerdrConnectionError?

    func append(_ event: HerdrConnectionEvent) {
        switch event {
        case .snapshot(let snapshot):
            snapshots.append(snapshot)
        case .surface:
            surfaceCount += 1
        case .ended(let reason):
            endReason = reason
        case .bell, .notification, .clipboard, .inputRefused:
            break
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
