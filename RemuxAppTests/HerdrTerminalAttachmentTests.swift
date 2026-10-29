import CryptoKit
import GhosttyKit
import XCTest
@testable import Remux

/// The direct terminal connection, against recordings of Herdr v0.9.3 and v0.9.5 (`Fixtures/HerdrWire`,
/// `direct-terminal-*`): Remux decodes what Herdr sent, encodes what the recorded client sent, and an
/// attachment over a recorded stream shows its terminal and ends as Herdr ended it.
final class HerdrTerminalAttachmentTests: XCTestCase {
    private static let versions = ["0.9.3", "0.9.5"]
    private static let scenarios = ["01-shell", "02-refused", "03-missing", "04-exit", "05-keyboard"]
    /// The recorded client sent no cell size, which GhosttyKit's terminals need; the attachments here send one.
    private static let geometry = HerdrTerminalAttachment.Geometry(columns: 40, rows: 12, cellWidthPx: 8, cellHeightPx: 16)
    private static let resized = HerdrTerminalAttachment.Geometry(columns: 44, rows: 14, cellWidthPx: 8, cellHeightPx: 16)

    // MARK: - Wire

    func testEveryRecordedServerMessageDecodesAsHerdrSentIt() throws {
        for version in Self.versions {
            for scenario in Self.scenarios {
                let fixture = try DirectTerminalFixture(version: version, scenario: scenario)
                let payloads = try fixture.serverPayloads()
                XCTAssertEqual(payloads.count, fixture.expected.server.count, fixture.name)
                for (payload, entry) in zip(payloads, fixture.expected.server) {
                    let context = "\(fixture.name) at \(entry.offset)"
                    XCTAssertEqual(payload.count, entry.length, context)
                    let message = try HerdrDirectTerminalServerMessage.decode(payload)
                    switch message {
                    case .welcome(let version, let terminalBytes, let error):
                        let welcome = try XCTUnwrap(entry.Welcome, context)
                        XCTAssertEqual(version, welcome.version, context)
                        XCTAssertEqual(terminalBytes, welcome.encoding == "TerminalAnsi", context)
                        XCTAssertEqual(error, welcome.error, context)
                    case .frame(let frame):
                        let terminal = try XCTUnwrap(entry.Terminal, context)
                        XCTAssertEqual(frame.sequence, terminal.seq, context)
                        XCTAssertEqual([frame.columns, frame.rows], [terminal.width, terminal.height], context)
                        XCTAssertEqual(frame.full, terminal.full, context)
                        XCTAssertEqual(frame.bytes.count, terminal.bytes, context)
                        XCTAssertEqual(Self.sha256(frame.bytes), terminal.sha256, context)
                    case .shutdown(let reason):
                        XCTAssertEqual(reason, try XCTUnwrap(entry.ServerShutdown, context).reason, context)
                    case .mouseCapture(let enabled):
                        XCTAssertEqual(enabled, try XCTUnwrap(entry.MouseCapture, context).enabled, context)
                    case .keyboardProtocol(let flags, let level):
                        let keyboard = try XCTUnwrap(entry.DirectTerminalKeyboardProtocol, context)
                        XCTAssertEqual(flags, keyboard.flags, context)
                        XCTAssertEqual(level, keyboard.modify_other_keys_level, context)
                    case .skipped(let tag):
                        XCTFail("\(context): tag \(tag) skipped")
                    }
                }
            }
        }
    }

    /// Herdr accepted these bytes: the popup's pty took the hello's and the resize's sizes, the input ran
    /// and the wheel scrolled its history.
    func testRemuxEncodesWhatTheRecordedClientSent() throws {
        for version in Self.versions {
            let fixture = try DirectTerminalFixture(version: version, scenario: "01-shell")
            let terminalID = try XCTUnwrap(fixture.expected.client.compactMap(\.AttachTerminal).first?.terminal_id)
            let messages: [HerdrDirectTerminalClientMessage] = [
                .hello(columns: 40, rows: 12, cellWidthPx: 0, cellHeightPx: 0),
                .attach(terminalID: terminalID, takeover: false),
                .input(Array("echo wire\r".utf8)),
                .resize(columns: 44, rows: 14, cellWidthPx: 0, cellHeightPx: 0),
                .scroll(.up, lines: 3, column: nil, row: nil),
                .scroll(.down, lines: 3, column: nil, row: nil),
                .detach,
            ]
            XCTAssertEqual(messages.flatMap(\.frame), fixture.client, fixture.name)
        }
    }

    /// A direct terminal connection carries only these types; any other, as a newer Herdr might send, is an
    /// error.
    func testOnlyTheDirectTerminalsMessageTypesDecode() throws {
        for tag: UInt32 in [2, 4, 5, 6, 7, 9, 10, 11] {
            var writer = HerdrWireWriter()
            writer.variant(tag)
            XCTAssertEqual(try HerdrDirectTerminalServerMessage.decode(writer.bytes), .skipped(tag: tag))
        }
        for tag: UInt32 in [12, 13, 14, 15, 17, 18, 19, 20, 21] {
            var writer = HerdrWireWriter()
            writer.variant(tag)
            XCTAssertThrowsError(try HerdrDirectTerminalServerMessage.decode(writer.bytes)) {
                XCTAssertEqual($0 as? HerdrWireError, .unknownMessage(tag: tag))
            }
        }
    }

    // MARK: - Attachment

    func testAnAttachmentShowsTheRecordedTerminalItsNewGridAndTheDetach() async throws {
        for version in Self.versions {
            let fixture = try DirectTerminalFixture(version: version, scenario: "01-shell")
            let bridge = FakeBridgeTransport()
            let producers = RecordingProducers()
            let attachment = Self.attachment(fixture, bridge: bridge, producers: producers)
            Task { await attachment.run() }
            let hello = try await bridge.written(0)
            XCTAssertEqual(hello, try Self.opening(fixture), "\(fixture.name): hello and attach")
            // The recorded client resized before Herdr's frames of the new size.
            await attachment.resize(to: Self.resized)
            await bridge.serve(fixture.server)

            var events: [String] = []
            for await event in attachment.updates {
                switch event {
                case .terminal(_, let columns, let rows): events.append("terminal \(columns)x\(rows)")
                case .grid(let columns, let rows): events.append("grid \(columns)x\(rows)")
                case .ended(let ending): events.append("ended \(ending)")
                }
            }
            XCTAssertEqual(events, ["terminal 40x12", "grid 44x14", "ended detached"], fixture.name)
            // Pastes go bracketed, which Herdr unwraps and pastes the way the program asks.
            let first = try XCTUnwrap(producers.fed.first, fixture.name)
            XCTAssertTrue(first.starts(with: Array("\u{1b}[?2004h".utf8)), fixture.name)
        }
    }

    /// A terminal another client holds ends the attach held; one that isn't there, refused.
    func testAHeldOrMissingTerminalEndsTheAttachHeldOrRefused() async throws {
        for version in Self.versions {
            for scenario in ["02-refused", "03-missing"] {
                let fixture = try DirectTerminalFixture(version: version, scenario: scenario)
                let reason = try XCTUnwrap(fixture.expected.server.compactMap(\.ServerShutdown).first?.reason)
                let ending = try await Self.ending(of: fixture.server, fixture)
                XCTAssertEqual(ending, scenario == "02-refused" ? .held(reason) : .refused(reason), fixture.name)
                XCTAssertTrue(reason.hasPrefix("terminal attach failed"), fixture.name)
            }
        }
    }

    func testAProgramThatExitsEndsTheAttachClosed() async throws {
        for version in Self.versions {
            let fixture = try DirectTerminalFixture(version: version, scenario: "04-exit")
            let reason = try XCTUnwrap(fixture.expected.server.compactMap(\.ServerShutdown).first?.reason)
            let ending = try await Self.ending(of: fixture.server, fixture)
            XCTAssertEqual(ending, .closed(reason), fixture.name)
        }
    }

    // MARK: - What Remux doesn't expect

    /// A message type outside the direct terminal's, between the recording's first frame and the rest,
    /// fails the attach.
    func testAMessageTypeRemuxDoesntKnowFailsTheAttach() async throws {
        let fixture = try DirectTerminalFixture(version: "0.9.5", scenario: "01-shell")
        let payloads = try fixture.serverPayloads()
        var unknown = HerdrWireWriter()
        unknown.variant(21)
        let stream = payloads.prefix(4) + [unknown.bytes] + payloads.dropFirst(4)
        let ending = try await Self.ending(of: stream.flatMap(HerdrWire.frame), fixture)
        XCTAssertEqual(ending, .failed(HerdrWireError.unknownMessage(tag: 21).localizedDescription))
    }

    /// The recording's first frame cut short inside its terminal bytes fails the attach.
    func testATruncatedFrameFailsTheAttach() async throws {
        let fixture = try DirectTerminalFixture(version: "0.9.5", scenario: "01-shell")
        let payloads = try fixture.serverPayloads()
        let first = try XCTUnwrap(payloads.firstIndex { (try? HerdrDirectTerminalServerMessage.decode($0)).map {
            if case .frame = $0 { true } else { false }
        } ?? false })
        let stream = payloads.prefix(first) + [Array(payloads[first].dropLast(8))]
        let ending = try await Self.ending(of: stream.flatMap(HerdrWire.frame), fixture)
        XCTAssertEqual(ending, .failed(HerdrWireError.truncated.localizedDescription))
    }

    /// Herdr's frames of 44x14 when the client asked only for 40x12 fail the attach.
    func testAFrameOfASizeNotAskedForFailsTheAttach() async throws {
        let fixture = try DirectTerminalFixture(version: "0.9.5", scenario: "01-shell")
        let ending = try await Self.ending(of: fixture.server, fixture)
        XCTAssertEqual(ending, .failed("Herdr sent a 44x14 frame for another size."))
    }

    /// The protocol the program asked for, sent before the first frame, is on the terminal the renderer
    /// encodes keys for.
    func testTheProgramsKeyboardProtocolIsOnTheAttachmentsTerminal() async throws {
        for version in Self.versions {
            let fixture = try DirectTerminalFixture(version: version, scenario: "05-keyboard")
            let bridge = FakeBridgeTransport()
            let producers = RecordingProducers()
            let attachment = Self.attachment(fixture, bridge: bridge, producers: producers)
            Task { await attachment.run() }
            await bridge.serve(fixture.server)
            for await _ in attachment.updates {}
            let first = try XCTUnwrap(producers.fed.first, fixture.name)
            XCTAssertEqual(Array(first.prefix(13)), Array("\u{1b}[?2004h\u{1b}[>1u".utf8), fixture.name)
        }
    }

    func testKeyboardProtocolChangesAsHerdrsClientSetsItsTerminal() {
        var keyboard = HerdrTerminalAttachment.KeyboardProtocol()
        XCTAssertEqual(keyboard.change(kittyFlags: 0, modifyOtherKeysLevel: 0), [])
        XCTAssertEqual(String(decoding: keyboard.change(kittyFlags: 1, modifyOtherKeysLevel: 0), as: UTF8.self), "\u{1b}[>1u")
        XCTAssertEqual(
            String(decoding: keyboard.change(kittyFlags: 3, modifyOtherKeysLevel: 2), as: UTF8.self),
            "\u{1b}[<1u\u{1b}[>3u\u{1b}[>4;2m"
        )
        XCTAssertEqual(String(decoding: keyboard.current, as: UTF8.self), "\u{1b}[>3u\u{1b}[>4;2m")
        XCTAssertEqual(String(decoding: keyboard.change(kittyFlags: 0, modifyOtherKeysLevel: 0), as: UTF8.self), "\u{1b}[<1u\u{1b}[>4;0m")
    }

    func testAnAttachHerdrNeverAnswersFailsAndClosesItsBridge() async throws {
        let bridge = FakeBridgeTransport()
        let attachment = HerdrTerminalAttachment(
            terminalID: "term",
            geometry: .init(columns: 10, rows: 4, cellWidthPx: 0, cellHeightPx: 0),
            openBridge: { bridge },
            welcomeDeadline: .milliseconds(50)
        )
        Task { await attachment.run() }
        var ending: HerdrTerminalAttachment.Ending?
        for await event in attachment.updates {
            if case .ended(let reason) = event { ending = reason }
        }
        guard case .failed = ending else { return XCTFail("ended \(String(describing: ending))") }
        let closes = await bridge.closes
        XCTAssertEqual(closes.first, .unresponsive)
    }

    /// A stream that ends without Herdr saying why is a failure, not a terminal that is gone.
    func testAStreamThatEndsWithoutAShutdownFails() async throws {
        let fixture = try DirectTerminalFixture(version: "0.9.5", scenario: "01-shell")
        let payloads = try fixture.serverPayloads()
        let bridge = FakeBridgeTransport()
        let attachment = Self.attachment(fixture, bridge: bridge, producers: RecordingProducers())
        Task { await attachment.run() }
        // The welcome, the modes and the first frame, then the end.
        await bridge.serve(payloads.prefix(4).flatMap(HerdrWire.frame))
        await bridge.finishServing()
        var ending: HerdrTerminalAttachment.Ending?
        for await event in attachment.updates {
            if case .ended(let reason) = event { ending = reason }
        }
        guard case .failed = ending else { return XCTFail("ended \(String(describing: ending))") }
    }

    func testInputScrollsAndAResizeGoAsWrittenOnceAttached() async throws {
        let fixture = try DirectTerminalFixture(version: "0.9.5", scenario: "01-shell")
        let payloads = try fixture.serverPayloads()
        let bridge = FakeBridgeTransport()
        let attachment = Self.attachment(fixture, bridge: bridge, producers: RecordingProducers())
        Task { await attachment.run() }
        _ = try await bridge.written(0)
        await bridge.serve(payloads.prefix(4).flatMap(HerdrWire.frame))
        let sent = await attachment.send(Array("echo wire\r".utf8))
        XCTAssertTrue(sent)
        await attachment.resize(to: Self.resized)
        // The size already asked for doesn't go again.
        await attachment.resize(to: Self.resized)
        await attachment.scroll(.up, lines: 3, column: nil, row: nil)
        await attachment.scroll(.down, lines: 3, column: nil, row: nil)
        await attachment.detach()
        // The recorded client's messages, which Remux encodes as Herdr accepted them, with the cell size.
        let terminalID = try XCTUnwrap(fixture.expected.client.compactMap(\.AttachTerminal).first?.terminal_id)
        let expected: [HerdrDirectTerminalClientMessage] = [
            .hello(columns: 40, rows: 12, cellWidthPx: 8, cellHeightPx: 16),
            .attach(terminalID: terminalID, takeover: false),
            .input(Array("echo wire\r".utf8)),
            .resize(columns: 44, rows: 14, cellWidthPx: 8, cellHeightPx: 16),
            .scroll(.up, lines: 3, column: nil, row: nil),
            .scroll(.down, lines: 3, column: nil, row: nil),
            .detach,
        ]
        // The hello and the attach go in one write.
        var written: [UInt8] = []
        for index in 0..<6 { written += try await bridge.written(index) }
        XCTAssertEqual(written, expected.flatMap(\.frame))
        let writes = await bridge.writtenCount
        XCTAssertEqual(writes, 6)
        let closed = await bridge.isClosed
        XCTAssertTrue(closed)
    }

    // MARK: - Helpers

    private static func attachment(
        _ fixture: DirectTerminalFixture,
        bridge: FakeBridgeTransport,
        producers: RecordingProducers
    ) -> HerdrTerminalAttachment {
        let terminalID = fixture.expected.client.compactMap(\.AttachTerminal).first?.terminal_id ?? "term"
        return HerdrTerminalAttachment(
            terminalID: terminalID,
            geometry: geometry,
            openBridge: { bridge },
            makeProducer: producers.factory
        )
    }

    /// The hello and the attach an attachment for `fixture`'s terminal writes first.
    private static func opening(_ fixture: DirectTerminalFixture) throws -> [UInt8] {
        let terminalID = try XCTUnwrap(fixture.expected.client.compactMap(\.AttachTerminal).first?.terminal_id)
        return HerdrDirectTerminalClientMessage.hello(
            columns: geometry.columns,
            rows: geometry.rows,
            cellWidthPx: geometry.cellWidthPx,
            cellHeightPx: geometry.cellHeightPx
        ).frame + HerdrDirectTerminalClientMessage.attach(terminalID: terminalID, takeover: false).frame
    }

    /// How an attachment for `fixture`'s terminal ends when Herdr sends `server`.
    private static func ending(of server: [UInt8], _ fixture: DirectTerminalFixture) async throws -> HerdrTerminalAttachment.Ending? {
        let bridge = FakeBridgeTransport()
        let attachment = attachment(fixture, bridge: bridge, producers: RecordingProducers())
        Task { await attachment.run() }
        await bridge.serve(server)
        var ending: HerdrTerminalAttachment.Ending?
        for await event in attachment.updates {
            if case .ended(let reason) = event { ending = reason }
        }
        return ending
    }

    private static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One recording of a direct terminal attach and what its reference decoder read.
struct DirectTerminalFixture {
    struct Expected: Decodable {
        let server: [Server]
        let client: [Client]
    }

    struct Server: Decodable {
        struct Welcome: Decodable {
            let version: UInt32
            let encoding: String
            let error: String?
        }

        struct Terminal: Decodable {
            let seq: UInt64
            let width: UInt16
            let height: UInt16
            let full: Bool
            let bytes: Int
            let sha256: String
        }

        struct Shutdown: Decodable {
            let reason: String?
        }

        struct MouseCapture: Decodable {
            let enabled: Bool
        }

        struct Keyboard: Decodable {
            let flags: UInt16
            let modify_other_keys_level: UInt8
        }

        let offset: Int
        let length: Int
        let tag: UInt32
        let Welcome: Welcome?
        let Terminal: Terminal?
        let ServerShutdown: Shutdown?
        let MouseCapture: MouseCapture?
        let DirectTerminalKeyboardProtocol: Keyboard?
    }

    struct Client: Decodable {
        struct Attach: Decodable {
            let terminal_id: String
            let takeover: Bool
        }

        let hex: String
        let tag: UInt32
        let AttachTerminal: Attach?
    }

    let name: String
    let server: [UInt8]
    let client: [UInt8]
    let expected: Expected

    init(version: String, scenario: String) throws {
        let name = "direct-terminal-\(version)-\(scenario)"
        let bundle = Bundle(for: HerdrTerminalAttachmentTests.self)
        let load = { (suffix: String) throws -> Data in
            try Data(contentsOf: XCTUnwrap(bundle.url(forResource: name, withExtension: suffix), "\(name).\(suffix)"))
        }
        self.name = name
        server = Array(try load("s2c.bin"))
        client = Array(try load("c2s.bin"))
        expected = try JSONDecoder().decode(Expected.self, from: try load("expected.json"))
    }

    func serverPayloads() throws -> [[UInt8]] {
        var splitter = HerdrFrameSplitter()
        splitter.append(server)
        var payloads: [[UInt8]] = []
        while let payload = try splitter.nextPayload() { payloads.append(payload) }
        return payloads
    }
}

/// GhosttyKit's producers, recording every feed in order.
final class RecordingProducers: @unchecked Sendable {
    private let lock = NSLock()
    private var feeds: [[UInt8]] = []

    var fed: [[UInt8]] { lock.withLock { feeds } }

    var factory: HerdrTerminalAttachment.ProducerFactory {
        { [self] columns, rows in Recording(producer: try HerdrPaneProducer(columns: columns, rows: rows), owner: self) }
    }

    fileprivate func record(_ bytes: [UInt8]) {
        lock.withLock { feeds.append(bytes) }
    }

    private final class Recording: HerdrPaneProducing {
        let producer: HerdrPaneProducer
        let owner: RecordingProducers

        init(producer: HerdrPaneProducer, owner: RecordingProducers) {
            self.producer = producer
            self.owner = owner
        }

        func retainTerminal() throws -> HerdrRetainedTerminal { try producer.retainTerminal() }

        func feed(_ bytes: [UInt8]) -> ghostty_terminal_producer_result_e {
            owner.record(bytes)
            return producer.feed(bytes)
        }

        func resizeAndFeed(columns: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32, bytes: [UInt8]) -> ghostty_terminal_producer_result_e {
            owner.record(bytes)
            return producer.resizeAndFeed(columns: columns, rows: rows, cellWidthPx: cellWidthPx, cellHeightPx: cellHeightPx, bytes: bytes)
        }

        func resize(columns: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32) -> ghostty_terminal_producer_result_e {
            producer.resize(columns: columns, rows: rows, cellWidthPx: cellWidthPx, cellHeightPx: cellHeightPx)
        }
    }
}
