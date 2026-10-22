import GhosttyKit
import UIKit
import XCTest
@testable import Remux

/// Recorded Herdr bytes through the real pieces: the connection (which decodes), the presentation, the
/// painter and one Ghostty terminal per pane. Each pane terminal is read back as text and compared with
/// the cells Herdr sent.
@MainActor
final class HerdrPipelineTests: XCTestCase {
    private let recording = "herdr-04-patch-and-delta-A"

    /// The welcome, the snapshot and every surface can arrive in the same read; the screen gets them
    /// before `open` returns, already decoded.
    func testASessionArrivingWithTheWelcomeIsPaintedAsHerdrSentIt() async throws {
        let transport = FakeBridgeTransport()
        await transport.serve(try HerdrConnectionTests.recording(recording))
        await transport.finishServing()
        let screen = try PipelineScreen()
        let connection = try await screen.open(transport, surfaceActive: true)
        _ = connection
        let end = await screen.waitForEnd()

        XCTAssertEqual(end, .closed)
        XCTAssertNil(screen.failure)
        try assertPanesShowHerdrsCells(screen)
    }

    /// A hide sent while a show is being answered wins, and surfaces that arrive while hidden still
    /// go through the decoder, so the deltas after them apply.
    func testAHideDuringAShowWinsAndHiddenSurfacesStillDecode() async throws {
        let frames = try HerdrConnectionTests.frames(HerdrConnectionTests.recording(recording))
        let transport = FakeBridgeTransport()
        await transport.serve(frames[0...3].flatMap(HerdrWire.frame))
        let screen = try PipelineScreen()
        let connection = try await screen.open(transport, surfaceActive: false)
        await screen.waitForSnapshot()

        let geometry = HerdrSurfaceGeometry(cellWidthPx: 9, cellHeightPx: 18, cols: 80, rows: 24)
        async let shown = connection.show(geometry)
        let showRequest = try HerdrConnectionTests.request(try await transport.written(2))
        async let hidden: Void = connection.hide()
        let hideRequest = try HerdrConnectionTests.request(try await transport.written(5))
        XCTAssertEqual(showRequest.params, ["active": true])
        XCTAssertEqual(hideRequest.params, ["active": false])
        await transport.serve(HerdrConnectionTests.reply(id: showRequest.id, json: #"{"type":"client_shell_surface_set","active":true,"projection_revision":1}"#))
        await transport.serve(HerdrConnectionTests.reply(id: hideRequest.id, json: #"{"type":"client_shell_surface_set","active":false,"projection_revision":1}"#))
        _ = try await shown
        try await hidden
        do {
            try await connection.send([.text("a")], toPane: "w1:p1")
            XCTFail("input sent while hidden")
        } catch {
            XCTAssertEqual(error as? HerdrInputError, .inactive)
        }

        await transport.serve(frames[4...].flatMap(HerdrWire.frame))
        await transport.finishServing()
        let end = await screen.waitForEnd()

        XCTAssertEqual(end, .closed)
        XCTAssertNil(screen.failure)
        try assertPanesShowHerdrsCells(screen)
    }

    /// Closing while the screen still holds a message ends the connection quietly: nothing follows
    /// that message, not even an end.
    func testClosingWhileTheScreenHoldsAMessageEndsQuietly() async throws {
        let transport = FakeBridgeTransport()
        let screen = try PipelineScreen()
        screen.holdEvent(at: 3)
        await transport.serve(try HerdrConnectionTests.recording(recording))
        let connection = try await screen.open(transport, surfaceActive: true)
        await screen.waitForHeldEvent()

        await connection.close()
        screen.releaseHeldEvent()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(screen.eventCount, 3)
        XCTAssertNil(screen.end)
        let closed = await transport.isClosed
        XCTAssertTrue(closed)
    }

    /// A surface the decoder can't apply reaches the screen as the connection's wire failure.
    func testASurfaceTheDecoderCannotApplyEndsAsAWireFailure() async throws {
        let frames = try HerdrConnectionTests.frames(HerdrConnectionTests.recording(recording))
        let transport = FakeBridgeTransport()
        // The deltas without the full surface they build on.
        await transport.serve((frames[0...3] + frames[9...]).flatMap(HerdrWire.frame))
        let screen = try PipelineScreen()
        _ = try await screen.open(transport, surfaceActive: true)
        let end = await screen.waitForEnd()

        XCTAssertEqual(end, .wire(.invalidSurfaceUpdate("surface delta without a baseline")))
    }

    // MARK: - Checking

    private func assertPanesShowHerdrsCells(_ screen: PipelineScreen, file: StaticString = #filePath, line: UInt = #line) throws {
        let presented = try XCTUnwrap(screen.presentation.presented, file: file, line: line)
        var written = false
        for pane in presented.surface.panes {
            let expected = Self.text(of: presented.surface.frame, in: pane.innerRect)
            let shown = try screen.text(ofPane: pane.paneID)
            XCTAssertEqual(shown, expected, "pane \(pane.paneID)", file: file, line: line)
            written = written || !expected.isEmpty
        }
        // Blank panes would match a terminal that was never painted.
        XCTAssertTrue(written, "no pane holds any text", file: file, line: line)
    }

    /// The area's rows as text: covered cells (`""`) add nothing, trailing blanks and blank rows at the
    /// end are dropped, as Ghostty's selection text drops them.
    static func text(of frame: HerdrFrame, in area: HerdrSurfaceRect) -> String {
        let rows = (0..<Int(area.height)).map { y in
            (0..<Int(area.width)).map { x in
                frame.cells[(Int(area.y) + y) * Int(frame.width) + Int(area.x) + x].symbol
            }.joined()
        }
        return normalized(rows.joined(separator: "\n"))
    }

    static func normalized(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").map { line in
            String(line.reversed().drop(while: \.isWhitespace).reversed())
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// The screen side of the pipeline, as a Herdr screen will run it: presentation, then each presented
/// pane painted into its own Ghostty terminal.
@MainActor
private final class PipelineScreen {
    private(set) var presentation = HerdrPresentation()
    private(set) var end: HerdrConnectionError?
    private(set) var failure: Error?
    private(set) var eventCount = 0

    private let runtime: GhosttyKitRuntime
    private var terminals: [String: PaneTerminal] = [:]
    private var painted: [String: HerdrPanePainter.Painted] = [:]
    private var waiters: [(condition: () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
    private var heldAt: Int?
    private var held: CheckedContinuation<Void, Never>?

    init() throws {
        runtime = try GhosttyKitRuntime(terminalSettings: .default)
    }

    func open(_ transport: FakeBridgeTransport, surfaceActive: Bool) async throws -> HerdrConnection {
        let hello = HerdrHello(cellWidthPx: 9, cellHeightPx: 18, cols: 80, rows: 24, surfaceActive: surfaceActive)
        return try await HerdrConnection.open(transport: transport, hello: hello, appActive: false) { [self] event in
            await receive(event)
        }
    }

    func holdEvent(at count: Int) { heldAt = count }

    func releaseHeldEvent() {
        heldAt = nil
        held?.resume()
        held = nil
    }

    func waitForHeldEvent() async { await wait { self.held != nil } }

    func waitForSnapshot() async { await wait { self.presentation.snapshot != nil } }

    func waitForEnd() async -> HerdrConnectionError? {
        await wait { self.end != nil }
        return end
    }

    func text(ofPane paneID: String) throws -> String {
        let terminal = try XCTUnwrap(terminals[paneID])
        let area = try XCTUnwrap(painted[paneID]).area
        return try terminal.text(columns: Int(area.width), rows: Int(area.height), runtime: runtime)
    }

    private func receive(_ event: HerdrConnectionEvent) async {
        eventCount += 1
        do {
            switch event {
            case .snapshot(let snapshot):
                presentation.receive(snapshot)
            case .surface(.surface(let surface)):
                try presentation.receive(surface)
            case .surface(.patch(let patch)):
                _ = presentation.receive(patch)
            case .ended(let error):
                end = error
            case .bell, .notification, .clipboard, .inputRefused:
                break
            }
            try paint()
        } catch {
            failure = error
        }
        resumeWaiters()
        if heldAt == eventCount {
            await withCheckedContinuation { held = $0; resumeWaiters() }
        }
    }

    private func paint() throws {
        guard let (_, surface) = presentation.presented else { return }
        let cursor = HerdrPanePainter.paneCursor(of: surface)
        for pane in surface.panes {
            let next = HerdrPanePainter.Painted(frame: surface.frame, area: pane.innerRect, cursor: cursor)
            if let terminal = terminals[pane.paneID], let previous = painted[pane.paneID] {
                if previous.area.width == next.area.width, previous.area.height == next.area.height {
                    try terminal.feed(HerdrPanePainter.update(from: previous, to: next))
                } else {
                    try terminal.resizeAndFeed(next.area, HerdrPanePainter.repaint(next))
                }
            } else {
                let terminal = try PaneTerminal(columns: next.area.width, rows: next.area.height)
                try terminal.feed(HerdrPanePainter.repaint(next))
                terminals[pane.paneID] = terminal
            }
            painted[pane.paneID] = next
        }
    }

    private func wait(until condition: @escaping () -> Bool) async {
        guard !condition() else { return }
        await withCheckedContinuation { waiters.append((condition, $0)) }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { $0.condition() }
        waiters.removeAll { $0.condition() }
        ready.forEach { $0.continuation.resume() }
    }
}

/// One pane's Ghostty terminal, fed through a producer, and read back through a terminal surface.
private final class PaneTerminal {
    enum Failure: Error {
        case producer(ghostty_terminal_producer_result_e)
        case surface(ghostty_terminal_surface_result_e)
        case selection(String)
    }

    private let producer: ghostty_terminal_producer_t
    private let terminal: ghostty_terminal_t

    init(columns: UInt16, rows: UInt16) throws {
        var config = ghostty_terminal_producer_config_new()
        config.columns = columns
        config.rows = rows
        config.max_scrollback = 0
        var created: ghostty_terminal_producer_t?
        let result = ghostty_terminal_producer_new(&config, &created)
        guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK, let created else { throw Failure.producer(result) }
        var retained: ghostty_terminal_t?
        let retainResult = ghostty_terminal_producer_retain_terminal(created, &retained)
        guard retainResult == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK, let retained else {
            ghostty_terminal_producer_free(created)
            throw Failure.producer(retainResult)
        }
        producer = created
        terminal = retained
    }

    deinit {
        ghostty_terminal_release(terminal)
        ghostty_terminal_producer_free(producer)
    }

    func feed(_ bytes: [UInt8]) throws {
        let result = bytes.withUnsafeBufferPointer { ghostty_terminal_producer_feed(producer, $0.baseAddress, $0.count) }
        guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else { throw Failure.producer(result) }
    }

    func resizeAndFeed(_ area: HerdrSurfaceRect, _ bytes: [UInt8]) throws {
        let result = bytes.withUnsafeBufferPointer {
            ghostty_terminal_producer_resize_and_feed(producer, area.width, area.height, 9, 18, $0.baseAddress, $0.count)
        }
        guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else { throw Failure.producer(result) }
    }

    /// Selects the whole `columns` × `rows` grid through a Ghostty surface and returns its text. The
    /// cursor is moved to the first cell first, which locates the grid in the surface; nothing else
    /// is written.
    @MainActor
    func text(columns: Int, rows: Int, runtime: GhosttyKitRuntime) throws -> String {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 900, height: 900))
        let controller = UIViewController()
        window.rootViewController = controller
        let view = GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 900, height: 900))
        controller.view.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }

        let scale = max(window.screen.scale, 1)
        var config = runtime.makeTmuxBaseSurfaceConfig()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(view).toOpaque()))
        config.scale_factor = scale
        config.width_px = UInt32((view.bounds.width * scale).rounded())
        config.height_px = UInt32((view.bounds.height * scale).rounded())
        config.visible = false
        var created: ghostty_terminal_surface_t?
        let result = ghostty_terminal_surface_new(runtime.appHandleForTesting, terminal, &config, &created)
        guard result == GHOSTTY_TERMINAL_SURFACE_RESULT_OK, let surface = created else { throw Failure.surface(result) }
        defer { ghostty_terminal_surface_free(surface) }

        try feed(Array("\u{1B}[1;1H".utf8))
        var origin = ghostty_terminal_surface_cell_geometry_s()
        let geometryResult = ghostty_terminal_surface_cursor_geometry(surface, &origin)
        guard geometryResult == GHOSTTY_TERMINAL_SURFACE_RESULT_OK, origin.visible else {
            throw Failure.selection("no cell geometry")
        }
        func center(_ column: Int, _ row: Int) -> (Double, Double) {
            (origin.x_px + (Double(column) + 0.5) * Double(origin.width_px),
             origin.y_px + (Double(row) + 0.5) * Double(origin.height_px))
        }

        var snapshot = ghostty_terminal_surface_selection_snapshot_s()
        var anchored = false
        search: for row in 0..<rows {
            for column in 0..<columns {
                let (x, y) = center(column, row)
                guard ghostty_terminal_surface_select_word(surface, x, y, &snapshot) == GHOSTTY_TERMINAL_SURFACE_RESULT_OK,
                      snapshot.active
                else { continue }
                anchored = true
                break search
            }
        }
        guard anchored else { return "" }
        let (startX, startY) = center(0, 0)
        let (endX, endY) = center(columns - 1, rows - 1)
        guard ghostty_terminal_surface_set_selection_endpoint(surface, GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_START, startX, startY, &snapshot) == GHOSTTY_TERMINAL_SURFACE_RESULT_OK,
              ghostty_terminal_surface_set_selection_endpoint(surface, GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_END, endX, endY, &snapshot) == GHOSTTY_TERMINAL_SURFACE_RESULT_OK
        else { throw Failure.selection("endpoints") }

        var text = ghostty_text_s()
        guard ghostty_terminal_surface_read_selection(surface, &text) == GHOSTTY_TERMINAL_SURFACE_INPUT_SENT else {
            throw Failure.selection("read")
        }
        defer { _ = ghostty_terminal_surface_free_text(surface, &text) }
        return HerdrPipelineTests.normalized(GhosttyKitControlSurface.decodeGhosttyText(text))
    }
}
