@preconcurrency import AVFoundation
import Speech

struct GhosttyComposerProgressiveTranscript {
    private var finalized = AttributedString()
    private var volatile = AttributedString()

    var text: String {
        String((finalized + volatile).characters)
    }

    mutating func apply(_ text: AttributedString, isFinal: Bool) {
        if isFinal {
            finalized += text
            volatile = AttributedString()
        } else {
            volatile = text
        }
    }
}

@available(iOS 26.0, *)
final class GhosttySpeechAnalyzerComposerDictationBackend:
    GhosttyComposerDictationBackendProtocol,
    @unchecked Sendable
{
    let requiresSpeechRecognitionAuthorization = false

    private let desiredRunLock = NSLock()
    private var desiredRunID: UInt64?
    private let state = State()

    func prepare(locale: Locale) {
        Task {
            await state.prepare(locale: locale)
        }
    }

    func start(
        id: UInt64,
        locale: Locale,
        requestedAt: UInt64,
        handler: @escaping @Sendable (GhosttyComposerDictationBackendEvent) -> Void
    ) {
        setDesiredRunID(id)
        Task { [self] in
            await state.start(
                id: id,
                locale: locale,
                requestedAt: requestedAt,
                handler: handler,
                isDesired: { self.isDesiredRun(id) }
            )
        }
    }

    func finish(id: UInt64) {
        Task {
            await state.finish(id: id)
        }
    }

    func cancel(id: UInt64, completion: @escaping @Sendable () -> Void) {
        clearDesiredRunID(ifMatching: id)
        Task {
            await state.cancel(id: id)
            completion()
        }
    }

    func cancelAll(completion: @escaping @Sendable () -> Void) {
        setDesiredRunID(nil)
        Task {
            await state.cancelAll()
            completion()
        }
    }

    private func setDesiredRunID(_ id: UInt64?) {
        desiredRunLock.lock()
        desiredRunID = id
        desiredRunLock.unlock()
    }

    private func clearDesiredRunID(ifMatching id: UInt64) {
        desiredRunLock.lock()
        if desiredRunID == id {
            desiredRunID = nil
        }
        desiredRunLock.unlock()
    }

    private func isDesiredRun(_ id: UInt64) -> Bool {
        desiredRunLock.lock()
        defer { desiredRunLock.unlock() }
        return desiredRunID == id
    }
}

@available(iOS 26.0, *)
private extension GhosttySpeechAnalyzerComposerDictationBackend {
    actor State {
        typealias EventHandler = @Sendable (GhosttyComposerDictationBackendEvent) -> Void

        private enum RunPhase {
            case starting
            case recording
            case transcribing
        }

        private final class PreparedSession: @unchecked Sendable {
            let locale: Locale
            let transcriber: SpeechTranscriber
            let analyzer: SpeechAnalyzer
            let analyzerFormat: AVAudioFormat

            init(
                locale: Locale,
                transcriber: SpeechTranscriber,
                analyzer: SpeechAnalyzer,
                analyzerFormat: AVAudioFormat
            ) {
                self.locale = locale
                self.transcriber = transcriber
                self.analyzer = analyzer
                self.analyzerFormat = analyzerFormat
            }
        }

        private final class Run: @unchecked Sendable {
            let id: UInt64
            let locale: Locale
            let handler: EventHandler
            let analyzer: SpeechAnalyzer
            let transcriber: SpeechTranscriber
            var phase = RunPhase.starting
            var transcript = GhosttyComposerProgressiveTranscript()
            var captureSession: GhosttyComposerAudioCaptureSession?
            var resultsTask: Task<Void, Never>?
            var resultsError: Error?

            init(
                id: UInt64,
                locale: Locale,
                handler: @escaping EventHandler,
                analyzer: SpeechAnalyzer,
                transcriber: SpeechTranscriber
            ) {
                self.id = id
                self.locale = locale
                self.handler = handler
                self.analyzer = analyzer
                self.transcriber = transcriber
            }
        }

        private var activeRun: Run?
        private var preparedSession: PreparedSession?
        private var preparationTask: Task<PreparedSession, Error>?
        func prepare(locale: Locale) async {
            guard activeRun == nil else { return }
            let startedAt = GhosttyRuntimeTrace.nowNanos()
            do {
                _ = try await preparedSession(for: locale)
                GhosttyRuntimeTrace.perf(
                    "composer.dictation.analyzer.prepare result=ready locale=\(locale.identifier) "
                        + "elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startedAt))"
                )
            } catch {
                GhosttyRuntimeTrace.perf(
                    "composer.dictation.analyzer.prepareFailed locale=\(locale.identifier) "
                        + "error=\(String(describing: error))"
                )
            }
        }

        func start(
            id: UInt64,
            locale: Locale,
            requestedAt: UInt64,
            handler: @escaping EventHandler,
            isDesired: @escaping @Sendable () -> Bool
        ) async {
            await cancelActiveRun()
            guard isDesired() else { return }

            do {
                handler(.preparing)
                let prepared = try await takePreparedSession(for: locale)
                traceStartup("analyzer.prepared", id: id, requestedAt: requestedAt)
                guard isDesired() else {
                    returnPreparedSession(prepared)
                    return
                }

                handler(.starting)
                let (inputSequence, inputContinuation) = AsyncStream.makeStream(
                    of: AnalyzerInput.self
                )
                let run = Run(
                    id: id,
                    locale: prepared.locale,
                    handler: handler,
                    analyzer: prepared.analyzer,
                    transcriber: prepared.transcriber
                )
                activeRun = run

                run.resultsTask = makeResultsTask(for: run)
                try await prepared.analyzer.start(inputSequence: inputSequence)
                traceStartup("analyzer.analysisStarted", id: id, requestedAt: requestedAt)
                guard activeRun === run, isDesired() else {
                    await cancelActiveRun()
                    return
                }

                let captureSession = GhosttyComposerAudioCaptureSession()
                run.captureSession = captureSession
                let audioLevelHandler: @Sendable (CGFloat) -> Void = { [weak self] level in
                    Task { [weak self] in
                        await self?.publishAudioLevel(level, runID: id)
                    }
                }
                do {
                    try captureSession.start(
                        makeConsumer: { recordingFormat in
                            try GhosttySpeechAnalyzerAudioProcessor(
                                inputFormat: recordingFormat,
                                analyzerFormat: prepared.analyzerFormat,
                                continuation: inputContinuation,
                                onLevel: audioLevelHandler
                            )
                        },
                        onStarted: { [weak self] in
                            Task {
                                await self?.captureStarted(
                                    runID: id,
                                    requestedAt: requestedAt
                                )
                            }
                        },
                        onFailure: { [weak self] in
                            Task {
                                await self?.audioProcessingFailed(runID: id)
                            }
                        }
                    )
                } catch {
                    inputContinuation.finish()
                    throw error
                }
                guard activeRun === run, isDesired() else {
                    await cancelActiveRun()
                    return
                }
            } catch {
                await cancelActiveRun()
                handler(.failed(userMessage(for: error)))
            }
        }

        func finish(id: UInt64) async {
            guard let run = activeRun,
                  run.id == id,
                  run.phase == .recording else {
                return
            }

            run.phase = .transcribing
            let inputFinished = await withCheckedContinuation { continuation in
                run.captureSession?.finish { inputFinished in
                    continuation.resume(returning: inputFinished)
                }
            }
            guard activeRun === run else { return }
            guard inputFinished else {
                run.handler(.recognitionFailed)
                await run.analyzer.cancelAndFinishNow()
                release(run)
                return
            }

            do {
                try await run.analyzer.finalizeAndFinishThroughEndOfInput()
                await run.resultsTask?.value
                guard activeRun === run else { return }
                if let error = run.resultsError {
                    throw error
                }
                run.handler(.completed)
                release(run)
            } catch is CancellationError {
                guard activeRun === run else { return }
                run.handler(.recognitionFailed)
                release(run)
            } catch {
                guard activeRun === run else { return }
                run.handler(.recognitionFailed)
                release(run)
            }
        }

        private func captureStarted(runID: UInt64, requestedAt: UInt64) {
            guard let run = activeRun,
                  run.id == runID,
                  run.phase == .starting else {
                return
            }
            run.phase = .recording
            GhosttyRuntimeTrace.perf(
                "composer.dictation.startup event=analyzer.firstForwardedAudioBuffer id=\(runID) "
                    + "elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: requestedAt))"
            )
            run.handler(.started)
        }

        func cancel(id: UInt64) async {
            guard let run = activeRun, run.id == id else { return }
            let locale = run.locale
            await cancelActiveRun()
            schedulePreparation(locale: locale)
        }

        func cancelAll() async {
            await cancelActiveRun()
            preparationTask?.cancel()
            preparationTask = nil
            if let preparedSession {
                self.preparedSession = nil
                await preparedSession.analyzer.cancelAndFinishNow()
            }
        }

        private func makeResultsTask(for run: Run) -> Task<Void, Never> {
            let transcriber = run.transcriber
            let runID = run.id
            return Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        await self?.handle(result: result, runID: runID)
                    }
                    await self?.resultsEnded(runID: runID, error: nil)
                } catch {
                    await self?.resultsEnded(runID: runID, error: error)
                }
            }
        }

        private func handle(result: SpeechTranscriber.Result, runID: UInt64) {
            guard let run = activeRun, run.id == runID else { return }

            run.transcript.apply(result.text, isFinal: result.isFinal)

            let transcript = run.transcript.text
            if !transcript.isEmpty {
                run.handler(.hypothesis(transcript))
            }
        }

        private func resultsEnded(runID: UInt64, error: Error?) {
            guard let run = activeRun, run.id == runID else { return }
            run.resultsError = error

            if run.phase == .starting || run.phase == .recording {
                run.handler(.recognitionFailed)
                release(run)
            }
        }

        private func publishAudioLevel(_ level: CGFloat, runID: UInt64) {
            guard let run = activeRun,
                  run.id == runID,
                  run.phase == .starting || run.phase == .recording else {
                return
            }
            run.handler(.audioLevel(level))
        }

        private func audioProcessingFailed(runID: UInt64) async {
            guard let run = activeRun,
                  run.id == runID,
                  run.phase == .recording else {
                return
            }
            run.handler(.recognitionFailed)
            await cancelActiveRun()
        }

        private func preparedSession(for locale: Locale) async throws -> PreparedSession {
            if let preparedSession,
               preparedSession.locale.identifier == locale.identifier {
                return preparedSession
            }

            if let preparationTask {
                do {
                    let prepared = try await preparationTask.value
                    self.preparationTask = nil
                    if prepared.locale.identifier == locale.identifier {
                        preparedSession = prepared
                        return prepared
                    }
                } catch {
                    self.preparationTask = nil
                    throw error
                }
            }

            let task = Task {
                try await Self.makePreparedSession(locale: locale)
            }
            preparationTask = task
            do {
                let prepared = try await task.value
                preparationTask = nil
                preparedSession = prepared
                return prepared
            } catch {
                preparationTask = nil
                throw error
            }
        }

        private func takePreparedSession(for locale: Locale) async throws -> PreparedSession {
            let prepared = try await preparedSession(for: locale)
            preparedSession = nil
            return prepared
        }

        private func returnPreparedSession(_ prepared: PreparedSession) {
            guard preparedSession == nil else { return }
            preparedSession = prepared
        }

        private static func makePreparedSession(locale: Locale) async throws -> PreparedSession {
            guard SpeechTranscriber.isAvailable else {
                throw GhosttySpeechAnalyzerError.unavailable
            }
            guard let supportedLocale = await SpeechTranscriber.supportedLocale(
                equivalentTo: locale
            ) else {
                throw GhosttySpeechAnalyzerError.unsupportedLocale
            }

            let transcriber = SpeechTranscriber(
                locale: supportedLocale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )

            if let installationRequest = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await installationRequest.downloadAndInstall()
            }

            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]
            ) else {
                throw GhosttySpeechAnalyzerError.unavailableAudioFormat
            }

            let analyzer = SpeechAnalyzer(
                modules: [transcriber],
                options: SpeechAnalyzer.Options(
                    priority: .userInitiated,
                    modelRetention: .lingering
                )
            )
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            return PreparedSession(
                locale: supportedLocale,
                transcriber: transcriber,
                analyzer: analyzer,
                analyzerFormat: analyzerFormat
            )
        }

        private func cancelActiveRun() async {
            guard let run = activeRun else { return }
            activeRun = nil
            run.captureSession?.cancel()
            run.resultsTask?.cancel()
            await run.analyzer.cancelAndFinishNow()
        }

        private func release(_ run: Run) {
            guard activeRun === run else { return }
            activeRun = nil
            run.captureSession?.cancel()
            run.resultsTask?.cancel()
            schedulePreparation(locale: run.locale)
        }

        private func schedulePreparation(locale: Locale) {
            guard preparedSession?.locale.identifier != locale.identifier,
                  preparationTask == nil else {
                return
            }
            preparationTask = Task {
                try await Self.makePreparedSession(locale: locale)
            }
        }

        private func userMessage(for error: Error) -> String {
            switch error {
            case GhosttySpeechAnalyzerError.unsupportedLocale:
                "Dictation isn’t available for this language."
            case GhosttySpeechAnalyzerError.unavailable:
                "Dictation isn’t available right now."
            default:
                "Couldn’t start dictation. Try again."
            }
        }

        private func traceStartup(
            _ event: String,
            id: UInt64,
            requestedAt: UInt64
        ) {
            guard GhosttyRuntimeTrace.perfEnabled else { return }
            GhosttyRuntimeTrace.perf(
                "composer.dictation.startup event=\(event) id=\(id) "
                    + "elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: requestedAt))"
            )
        }
    }
}

@available(iOS 26.0, *)
final class GhosttySpeechAnalyzerAudioProcessor:
    GhosttyComposerAudioCaptureConsumer,
    @unchecked Sendable
{
    private static let levelPublishInterval = 0.075

    private let converter: AVAudioConverter
    private let analyzerFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: @Sendable (CGFloat) -> Void
    private let lock = NSLock()
    private var lastLevelPublishTime: CFTimeInterval = 0
    private var isFinished = false
    private var didFail = false
    private var outputCapacity: AVAudioFrameCount = 4_096

    init(
        inputFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        onLevel: @escaping @Sendable (CGFloat) -> Void
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw GhosttySpeechAnalyzerError.unavailableAudioFormat
        }
        self.converter = converter
        self.analyzerFormat = analyzerFormat
        self.continuation = continuation
        self.onLevel = onLevel
    }

    func accept(_ buffer: AVAudioPCMBuffer, at _: AVAudioTime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }

        let now = CACurrentMediaTime()
        if now - lastLevelPublishTime >= Self.levelPublishInterval {
            lastLevelPublishTime = now
            onLevel(GhosttyComposerAudioLevelMeter.normalizedPeak(for: buffer))
        }

        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let requiredCapacity = AVAudioFrameCount(
            max(1, ceil(Double(buffer.frameLength) * ratio) + 8)
        )
        outputCapacity = max(outputCapacity, requiredCapacity)
        if !convert(buffer, outputCapacity: requiredCapacity) {
            failProcessing()
            return false
        }
        return true
    }

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return !didFail }
        isFinished = true
        if !flushConverter() {
            didFail = true
        }
        continuation.finish()
        return !didFail
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        isFinished = true
        continuation.finish()
    }

    private func convert(
        _ inputBuffer: AVAudioPCMBuffer,
        outputCapacity: AVAudioFrameCount
    ) -> Bool {
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: analyzerFormat,
            frameCapacity: outputCapacity
        ) else {
            return false
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard conversionError == nil,
              status != .error else {
            return false
        }
        if converted.frameLength > 0 {
            guard inputWasEnqueued(converted) else { return false }
        }
        return true
    }

    private func flushConverter() -> Bool {
        while true {
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: analyzerFormat,
                frameCapacity: outputCapacity
            ) else {
                return false
            }

            var conversionError: NSError?
            let status = converter.convert(
                to: converted,
                error: &conversionError
            ) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if conversionError != nil || status == .error {
                return false
            }
            if converted.frameLength > 0 {
                guard inputWasEnqueued(converted) else { return false }
            }
            if status != .haveData {
                return true
            }
        }
    }

    private func failProcessing() {
        guard !didFail else { return }
        didFail = true
        isFinished = true
        continuation.finish()
    }

    private func inputWasEnqueued(_ buffer: AVAudioPCMBuffer) -> Bool {
        switch continuation.yield(AnalyzerInput(buffer: buffer)) {
        case .enqueued:
            true
        case .dropped, .terminated:
            false
        @unknown default:
            false
        }
    }

}

@available(iOS 26.0, *)
private enum GhosttySpeechAnalyzerError: Error {
    case unavailable
    case unavailableAudioFormat
    case unsupportedLocale
}
