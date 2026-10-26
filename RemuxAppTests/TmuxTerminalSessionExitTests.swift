import Foundation
import XCTest

@testable import Remux

/// tmux ends the client the same bare way (`%exit`, then the channel closes) whether the session ended or another
/// client detached it, and refuses an attach to a session it doesn't have before the session ever shows (bytes as
/// tmux 3.5a sends them).
@MainActor
final class TmuxTerminalSessionExitTests: XCTestCase {
    func testAnAttachTmuxRefusesIsSessionEnded() async throws {
        for refusal in ["can't find session: main", "no sessions"] {
            let (session, _, runtime) = try await connectedSession(
                greeting: "%begin 1 1 0\n\(refusal)\n%error 1 1 0\n%exit\n"
            )

            try await waitUntil { session.state == .detached(.sessionEnded) }
            await session.shutdown()
            withExtendedLifetime(runtime) {}
        }
    }

    /// The session's state keeps tmux's exit; its reason reconnects, which finds out whether the session is still
    /// there.
    func testAnExitKeepsTmuxsExit() async throws {
        let (session, transport, runtime) = try await connectedSession()

        await transport.receive("%sessions-changed\n%exit\n")
        await transport.finishInput()

        try await waitUntil { session.state == .detached(.serverExited(nil)) }
        await session.shutdown()
        withExtendedLifetime(runtime) {}
    }

    // MARK: - Support

    private func connectedSession(
        greeting: String = "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n"
    ) async throws -> (TmuxTerminalSession, ExitTestTransport, GhosttyKitRuntime) {
        let runtime = try GhosttyKitRuntime()
        let transport = ExitTestTransport(greeting: greeting)
        let session = TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            transport: transport,
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { .remuxDark }
        )
        session.connect(viewport: .default)
        try await waitUntil { await transport.hasStarted }
        return (session, transport, runtime)
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let met = await condition()
        XCTAssertTrue(met, "condition not met in time")
    }
}

private actor ExitTestTransport: TmuxControlTransport {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let greeting: String
    private(set) var hasStarted = false

    init(greeting: String) {
        self.greeting = greeting
        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        receivedBytes = AsyncThrowingStream { capturedContinuation = $0 }
        continuation = capturedContinuation!
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        hasStarted = true
        continuation.yield(Data(greeting.utf8))
    }

    func send(_ data: Data) async throws {
        if TmuxControlClientExit.isRequested(in: data) {
            continuation.finish()
        }
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        continuation.finish()
    }

    func receive(_ text: String) {
        continuation.yield(Data(text.utf8))
    }

    func finishInput() {
        continuation.finish()
    }
}
