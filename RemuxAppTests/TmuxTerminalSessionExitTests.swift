import Foundation
import XCTest

@testable import Remux

/// tmux ends the client the same bare way (`%exit`, then the channel closes) whether the session ended or another
/// client detached it, and refuses an attach to a missing session with an error before the exit (bytes as tmux
/// 3.5a sends them). The session asks the server whether it still runs before it says which.
@MainActor
final class TmuxTerminalSessionExitTests: XCTestCase {
    func testAnExitWhenTheServerNoLongerHasTheSessionIsSessionEnded() async throws {
        let (session, transport, runtime) = try await connectedSession(sessionRuns: { false })

        await transport.receive("%sessions-changed\n%exit\n")
        await transport.finishInput()

        try await waitUntil { session.state == .detached(.sessionEnded) }
        await session.shutdown()
        withExtendedLifetime(runtime) {}
    }

    func testAnExitWhileTheSessionStillRunsIsAnotherClientDetachingIt() async throws {
        let (session, transport, runtime) = try await connectedSession(sessionRuns: { true })

        await transport.receive("%exit\n")
        await transport.finishInput()

        try await waitUntil { session.state == .detached(.detachedElsewhere) }
        await session.shutdown()
        withExtendedLifetime(runtime) {}
    }

    /// The list goes over the same server: when it can't be had, the connection is gone too.
    func testAnExitWhenTheServerCannotBeAskedIsALostConnection() async throws {
        let (session, transport, runtime) = try await connectedSession(sessionRuns: { nil })

        await transport.receive("%exit\n")
        await transport.finishInput()

        try await waitUntil { session.state == .detached(.transportClosed) }
        await session.shutdown()
        withExtendedLifetime(runtime) {}
    }

    func testAnAttachTmuxRefusesForAMissingSessionIsSessionEnded() async throws {
        let (session, _, runtime) = try await connectedSession(
            greeting: "%begin 1 1 0\ncan't find session: main\n%error 1 1 0\n%exit\n",
            sessionRuns: { false }
        )

        try await waitUntil { session.state == .detached(.sessionEnded) }
        await session.shutdown()
        withExtendedLifetime(runtime) {}
    }

    /// A failure while the session still runs is no ended session.
    func testAProtocolFailureWhileTheSessionRunsStaysAFailure() async throws {
        let (session, _, runtime) = try await connectedSession(
            greeting: "%begin 1 1 0\nsomething went wrong\n%error 1 1 0\n",
            sessionRuns: { true }
        )

        try await waitUntil { session.state == .detached(.channelAborted) }
        await session.shutdown()
        withExtendedLifetime(runtime) {}
    }

    /// Until the server answers, the screen keeps what it showed, and nothing after the exit changes the answer.
    func testTheStateHoldsUntilTheServerAnswers() async throws {
        let answer = PendingAnswer()
        let (session, transport, runtime) = try await connectedSession(sessionRuns: { await answer.value() })
        let before = session.state

        await transport.receive("%exit\n")
        await transport.finishInput()
        try await waitUntil { answer.isWaiting }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.state, before)

        answer.resume(false)
        try await waitUntil { session.state == .detached(.sessionEnded) }
        await session.shutdown()
        withExtendedLifetime(runtime) {}
    }

    func testAnAnswerAfterShutdownChangesNothing() async throws {
        let answer = PendingAnswer()
        let (session, transport, runtime) = try await connectedSession(sessionRuns: { await answer.value() })

        await transport.receive("%exit\n")
        await transport.finishInput()
        try await waitUntil { answer.isWaiting }
        let before = session.state
        await session.shutdown()

        answer.resume(false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.state, before)
        withExtendedLifetime(runtime) {}
    }

    // MARK: - Support

    private func connectedSession(
        greeting: String = "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n",
        sessionRuns: @escaping TmuxTerminalSession.SessionLookup
    ) async throws -> (TmuxTerminalSession, ExitTestTransport, GhosttyKitRuntime) {
        let runtime = try GhosttyKitRuntime()
        let transport = ExitTestTransport(greeting: greeting)
        let session = TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            transport: transport,
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { .remuxDark },
            sessionRuns: sessionRuns
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

/// An answer the test gives when it chooses.
@MainActor
private final class PendingAnswer {
    private var continuation: CheckedContinuation<Bool?, Never>?
    private(set) var isWaiting = false

    func value() async -> Bool? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
    }

    func resume(_ value: Bool?) {
        continuation?.resume(returning: value)
        continuation = nil
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
