import GhosttyKit
import UIKit
import XCTest
@testable import Remux

/// Recorded Herdr sessions through the pieces the app runs: a bridge serving the recording, the
/// connection (which decodes), the session engine (presentation, painter, one Ghostty terminal per
/// pane) and the screen model's renderers. Each pane's renderer is read back as text and compared with
/// the cells of the last frame Herdr drew, which Herdr's own decoder produced from the same recording.
@MainActor
final class HerdrPipelineTests: XCTestCase {
    private var harnesses: [HerdrModelHarness] = []

    override func tearDown() async throws {
        for harness in harnesses {
            await harness.model.stop()
        }
        harnesses.removeAll()
    }

    private func makeHarness() async -> HerdrModelHarness {
        let harness = await HerdrModelHarness()
        harnesses.append(harness)
        return harness
    }

    /// The welcome, the snapshot and every surface can arrive in the same read; the model paints them,
    /// and keeps the last frame when the stream ends, reconnecting by itself.
    func testASessionArrivingWithTheWelcomeIsPaintedAsHerdrSentIt() async throws {
        let recording = "herdr-04-patch-and-delta-A"
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrConnectionTests.recording(recording))
        await bridge.finishServing()
        harness.setScreenSize()

        try await assertPanesShowHerdrsCells(harness, recording: recording)
        XCTAssertEqual(harness.states.last, .reconnecting(.transportLoss))
    }

    /// Connected hidden as Herdr's client connects, the session is shown once selected, and painted as
    /// Herdr drew it from then on.
    func testASessionShownAfterConnectingHiddenIsPaintedAsHerdrSentIt() async throws {
        let recording = "herdr-08-connect-inactive-A"
        let frames = try HerdrConnectionTests.frames(HerdrConnectionTests.recording(recording))
        let last = try Self.herdrsLastFrame(recording)
        let screen = try HerdrModelHarness.screenSize(columns: last.frame.width, rows: last.frame.height)
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        // Up to the snapshot and the server's state for this client; the recorded show reply answers
        // another client's request id, so the model's own is answered instead.
        await bridge.serve(frames[0...4].flatMap(HerdrWire.frame))
        harness.setScreenSize(screen)
        harness.model.setSelected(true)

        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        XCTAssertTrue(show.active)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(frames[6...].flatMap(HerdrWire.frame))
        await bridge.finishServing()

        try await assertPanesShowHerdrsCells(harness, recording: recording)
    }

    /// A hide sent while a show is being answered wins. Surfaces that arrive after it aren't drawn, so the
    /// panes keep what they showed, but they still go through the decoder and the presentation: shown
    /// again, the deltas built on them apply.
    func testAHideDuringAShowWinsAndHiddenSurfacesStillDecode() async throws {
        let recording = "herdr-04-patch-and-delta-A"
        let frames = try HerdrConnectionTests.frames(HerdrConnectionTests.recording(recording))
        let last = try Self.herdrsLastFrame(recording)
        let screen = try HerdrModelHarness.screenSize(columns: last.frame.width, rows: last.frame.height)
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(frames[0...3].flatMap(HerdrWire.frame))
        harness.setScreenSize(screen)
        harness.model.setSelected(true)

        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        harness.model.setSelected(false)
        let hide = try await harness.nextSurfaceSet(bridge, from: &index)
        XCTAssertEqual([show.active, hide.active], [true, false])
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: hide.id, active: false))
        // The full surface, a patch, and a delta on them, all while hidden.
        await bridge.serve(frames[4...11].flatMap(HerdrWire.frame))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(harness.model.layout, "a surface that came after the hide was drawn")

        harness.model.setSelected(true)
        let again = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: again.id, active: true))
        // A delta built on the hidden one, and a patch.
        await bridge.serve(frames[12...].flatMap(HerdrWire.frame))
        await bridge.finishServing()

        try await assertPanesShowHerdrsCells(harness, recording: recording)
        XCTAssertEqual(harness.model.stateTraceLabel, "reconnecting")
    }

    /// A surface the decoder can't apply ends the connection; before the first snapshot the model
    /// reports it as a wire failure.
    func testASurfaceTheDecoderCannotApplyIsReportedAsAWireFailure() async throws {
        let frames = try HerdrConnectionTests.frames(HerdrConnectionTests.recording("herdr-04-patch-and-delta-A"))
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        // The deltas without the full surface they build on, and without the snapshots, after which the
        // session would reconnect instead.
        await bridge.serve(([frames[0], frames[1], frames[3]] + frames[11...]).flatMap(HerdrWire.frame))
        harness.setScreenSize()

        try await harness.waitUntil("the failure wasn't reported") {
            harness.states.last?.disconnectedReason != nil
        }
        XCTAssertEqual(
            harness.states.last,
            .disconnected(HerdrConnectionError.wire(.invalidSurfaceUpdate("surface delta without a baseline")).terminalDisconnectReason(on: SavedServer(displayName: "Herdr Host", host: "herdr.example.test", username: "builder")))
        )
    }

    /// Stopped while the recording is still arriving: the bridge closes and nothing more is reported.
    func testStoppingWhileFramesArriveEndsQuietly() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrConnectionTests.recording("herdr-04-patch-and-delta-A"), inChunksOf: 64)
        harness.setScreenSize()
        try await harness.waitUntil("the hello wasn't sent") { await bridge.writtenCount > 0 }

        await harness.model.stop()
        let reportsAtStop = harness.states.count
        let closed = await bridge.isClosed
        XCTAssertTrue(closed)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(harness.states.count, reportsAtStop)
    }

    // MARK: - Checking

    /// The last frame Herdr drew in the recording: the frame a reference decoder and presentation reach
    /// from it, which matches Herdr's own decoder's cells.
    private static func herdrsLastFrame(_ recording: String) throws -> HerdrPaneSurfaceFrame {
        let fixtures = try HerdrWireTests.goldenFixtures()
        let fixture = try XCTUnwrap(fixtures.first { $0.name == recording })
        let negotiated = try XCTUnwrap(fixture.golden.negotiated)
        var decoder = HerdrSurfaceDecoder(deltaNegotiated: negotiated.delta, scrollNegotiated: negotiated.scroll)
        var reference = HerdrPresentation()
        var splitter = HerdrFrameSplitter()
        splitter.append(fixture.serverStream)
        while let payload = try splitter.nextPayload() {
            let message = try HerdrServerMessage.decode(payload)
            if case .control(let kind, let data) = message,
               case .snapshot(let snapshot) = try HerdrEndpointControl.parse(kind: kind, data: data) {
                reference.receive(snapshot)
                continue
            }
            guard let surfaceMessage = try HerdrSurfaceDecoderTests.surfaceMessage(message) else { continue }
            switch try decoder.decode(surfaceMessage) {
            case .surface(let surface): try reference.receive(surface)
            case .patch(let patch): _ = reference.receive(patch)
            }
        }
        let surface = try XCTUnwrap(reference.presented?.surface)
        XCTAssertEqual(
            HerdrSurfaceDecoderTests.digest(surface.frame.cells),
            fixture.golden.final?.cells,
            "the reference isn't Herdr's own frame"
        )
        return surface
    }

    /// Each pane with a text area shows the cells of the last frame Herdr drew.
    private func assertPanesShowHerdrsCells(
        _ harness: HerdrModelHarness,
        recording: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let surface = try Self.herdrsLastFrame(recording)

        var expected: [String: [String]] = [:]
        for pane in surface.panes where pane.innerRect.width > 0 && pane.innerRect.height > 0 {
            expected[pane.paneID] = RendererText.rows(of: surface.frame, in: pane.innerRect)
        }
        // Blank panes would match terminals that were never painted.
        XCTAssertTrue(expected.values.contains { $0.contains { !$0.isEmpty } }, file: file, line: line)
        try await harness.waitUntil("the panes don't show Herdr's last frame") {
            harness.shownRows() == expected
        }
        XCTAssertEqual(harness.shownRows(), expected, file: file, line: line)
    }
}
