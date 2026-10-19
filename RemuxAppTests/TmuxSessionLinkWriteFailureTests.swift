import Foundation
import XCTest

@testable import Remux

@MainActor
final class TmuxSessionLinkWriteFailureTests: XCTestCase {
    func testSendFailureInvalidatesTransportBeforeDisconnectingController() async throws {
        let runtime = try GhosttyKitRuntime()
        let stateRecorder = SessionStateRecorder()
        let transport = LinkTestTransport(failWrites: true)
        let controller = TmuxSessionController(
            callbacks: TmuxSessionController.Callbacks(
                onState: { state in
                    stateRecorder.append(state)
                }
            )
        )
        let link = TmuxSessionLink(controller: controller, transport: transport)

        try await link.start(viewport: .default)

        try await waitUntil("transport was not invalidated after send failure") {
            await transport.closeDispositions().first == .invalidated
        }
        try await waitUntil("controller did not publish transportClosed after send failure") {
            stateRecorder.contains(.detached(.transportClosed))
        }

        await link.stop()
        let closeDispositions = await transport.closeDispositions()
        XCTAssertEqual(closeDispositions, [.invalidated])
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }
        withExtendedLifetime(runtime) {}
    }

    func testExplicitStopDoesNotPublishTransportClosed() async throws {
        let runtime = try GhosttyKitRuntime()
        let stateRecorder = SessionStateRecorder()
        let transport = LinkTestTransport(failWrites: false)
        let controller = TmuxSessionController(
            callbacks: TmuxSessionController.Callbacks(
                onState: { state in
                    stateRecorder.append(state)
                }
            )
        )
        let link = TmuxSessionLink(controller: controller, transport: transport)

        try await link.start(viewport: .default)
        try await waitUntil("startup commands were not sent") {
            await transport.sendCount() > 0
        }

        await link.stop()
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }

        XCTAssertFalse(stateRecorder.contains(.detached(.transportClosed)))
        let closeDispositions = await transport.closeDispositions()
        XCTAssertEqual(closeDispositions, [.reusable])
        withExtendedLifetime(runtime) {}
    }

    func testExplicitStopSendsQueuedWorkThenEndsTmuxClient() async throws {
        let runtime = try GhosttyKitRuntime()
        let stateRecorder = SessionStateRecorder()
        let transport = LinkTestTransport(failWrites: false)
        let controller = TmuxSessionController(
            callbacks: TmuxSessionController.Callbacks(
                onState: { state in
                    stateRecorder.append(state)
                }
            )
        )
        let link = TmuxSessionLink(controller: controller, transport: transport)

        try await link.start(viewport: .default)
        try await waitUntil("controller did not process the initial tmux response") {
            stateRecorder.contains(.syncing)
        }
        controller.requestNewWindow()
        await link.stop()

        let lines = await transport.sentLines()
        XCTAssertTrue(lines.contains("new-window"))
        XCTAssertEqual(lines.last, TmuxControlClientExit.command)
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }
        withExtendedLifetime(runtime) {}
    }

    func testExplicitStopInvalidatesTransportWhenOutboundDrainStalls() async throws {
        let runtime = try GhosttyKitRuntime()
        let transport = StalledLinkTestTransport()
        let controller = TmuxSessionController(callbacks: .init())
        let link = TmuxSessionLink(
            controller: controller,
            transport: transport,
            outboundDrainTimeout: .milliseconds(30)
        )

        try await link.start(viewport: .default)
        try await waitUntil("startup write did not begin") {
            await transport.sendDidStart()
        }

        await link.stop()

        let closeDispositions = await transport.closeDispositions()
        XCTAssertEqual(closeDispositions, [.invalidated])
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }
        withExtendedLifetime(runtime) {}
    }

    func testUnexpectedReadEndInvalidatesTransportBeforeDisconnectingController() async throws {
        let runtime = try GhosttyKitRuntime()
        let stateRecorder = SessionStateRecorder()
        let transport = LinkTestTransport(failWrites: false)
        let controller = TmuxSessionController(
            callbacks: TmuxSessionController.Callbacks(
                onState: { state in
                    stateRecorder.append(state)
                }
            )
        )
        let link = TmuxSessionLink(controller: controller, transport: transport)

        try await link.start(viewport: .default)
        await transport.finishInput()

        try await waitUntil("transport was not invalidated after read end") {
            await transport.closeDispositions().first == .invalidated
        }
        try await waitUntil("controller did not publish transportClosed after read end") {
            stateRecorder.contains(.detached(.transportClosed))
        }

        await link.stop()
        let closeDispositions = await transport.closeDispositions()
        XCTAssertEqual(closeDispositions, [.invalidated])
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }
        withExtendedLifetime(runtime) {}
    }

    func testExplicitStopKeepsChannelOpenUntilTmuxEndsTheClient() async throws {
        let runtime = try GhosttyKitRuntime()
        let stateRecorder = SessionStateRecorder()
        let transport = LinkTestTransport(failWrites: false, exitsOnClientExitRequest: false)
        let controller = TmuxSessionController(
            callbacks: TmuxSessionController.Callbacks(
                onState: { state in
                    stateRecorder.append(state)
                }
            )
        )
        let link = TmuxSessionLink(controller: controller, transport: transport)

        try await link.start(viewport: .default)
        // The client accepts the exit request only after it has read tmux's greeting.
        try await waitUntil("controller did not process the initial tmux response") {
            stateRecorder.contains(.syncing)
        }
        let stop = Task { await link.stop() }
        try await waitUntil("client exit was not requested") {
            await transport.sentLines().contains(TmuxControlClientExit.command)
        }
        try await Task.sleep(for: .milliseconds(100))
        let closedBeforeTmuxEnded = await transport.closeDispositions()
        XCTAssertEqual(closedBeforeTmuxEnded, [])

        await transport.finishInput()
        await stop.value

        let closeDispositions = await transport.closeDispositions()
        XCTAssertEqual(closeDispositions, [.reusable])
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }
        withExtendedLifetime(runtime) {}
    }

    func testExplicitStopClosesChannelWhenTmuxNeverEndsTheClient() async throws {
        let runtime = try GhosttyKitRuntime()
        let stateRecorder = SessionStateRecorder()
        let transport = LinkTestTransport(failWrites: false, exitsOnClientExitRequest: false)
        let controller = TmuxSessionController(
            callbacks: TmuxSessionController.Callbacks(
                onState: { state in
                    stateRecorder.append(state)
                }
            )
        )
        let link = TmuxSessionLink(
            controller: controller,
            transport: transport,
            clientExitTimeout: .milliseconds(50)
        )

        try await link.start(viewport: .default)
        // The client accepts the exit request only after it has read tmux's greeting.
        try await waitUntil("controller did not process the initial tmux response") {
            stateRecorder.contains(.syncing)
        }
        await link.stop()

        let sentLines = await transport.sentLines()
        XCTAssertEqual(sentLines.last, TmuxControlClientExit.command)
        let closeDispositions = await transport.closeDispositions()
        XCTAssertEqual(closeDispositions, [.reusable])
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }
        withExtendedLifetime(runtime) {}
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(failureMessage)
    }
}

private final class SessionStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [TmuxSessionController.SessionState] = []

    func append(_ state: TmuxSessionController.SessionState) {
        lock.lock()
        defer { lock.unlock() }
        states.append(state)
    }

    func contains(_ state: TmuxSessionController.SessionState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return states.contains(state)
    }
}

private actor LinkTestTransport: TmuxControlTransport {
    enum SendFailure: Error {
        case failed
    }

    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let failWrites: Bool
    private let exitsOnClientExitRequest: Bool
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var recordedCloseDispositions: [TmuxControlTransportCloseDisposition] = []
    private var recordedSendCount = 0
    private var recordedData: [Data] = []

    init(failWrites: Bool, exitsOnClientExitRequest: Bool = true) {
        self.failWrites = failWrites
        self.exitsOnClientExitRequest = exitsOnClientExitRequest
        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        receivedBytes = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
        continuation.yield(
            Data("%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n".utf8)
        )
    }

    func send(_ data: Data) async throws {
        recordedData.append(data)
        recordedSendCount += 1
        if failWrites {
            throw SendFailure.failed
        }
        if exitsOnClientExitRequest, TmuxControlClientExit.isRequested(in: data) {
            continuation.finish()
        }
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        recordedCloseDispositions.append(disposition)
        continuation.finish()
    }

    func closeDispositions() -> [TmuxControlTransportCloseDisposition] {
        recordedCloseDispositions
    }

    func sendCount() -> Int {
        recordedSendCount
    }

    func sentLines() -> [String] {
        recordedData
            .reduce(Data(), +)
            .split(separator: UInt8(ascii: "\n"))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    func finishInput() {
        continuation.finish()
    }
}

private actor StalledLinkTestTransport: TmuxControlTransport {
    enum SendFailure: Error {
        case closed
    }

    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let inputContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private var pendingSendContinuation: CheckedContinuation<Void, Never>?
    private var recordedCloseDispositions: [TmuxControlTransportCloseDisposition] = []
    private var startedSend = false
    private var closed = false

    init() {
        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        receivedBytes = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        inputContinuation = capturedContinuation!
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
        inputContinuation.yield(
            Data("%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n".utf8)
        )
    }

    func send(_ data: Data) async throws {
        _ = data
        guard !closed else { throw SendFailure.closed }
        startedSend = true
        await withCheckedContinuation { pendingSendContinuation = $0 }
        if closed { throw SendFailure.closed }
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        guard !closed else { return }
        closed = true
        recordedCloseDispositions.append(disposition)
        let continuation = pendingSendContinuation
        pendingSendContinuation = nil
        continuation?.resume()
        inputContinuation.finish()
    }

    func sendDidStart() -> Bool {
        startedSend
    }

    func closeDispositions() -> [TmuxControlTransportCloseDisposition] {
        recordedCloseDispositions
    }
}
