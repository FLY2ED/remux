import XCTest
@testable import Remux

/// The image bytes kept for a connection, and the kitty commands a pane's terminal is fed. What the
/// commands draw is checked against real Ghostty in `HerdrTerminalEngineTests`; these check what they
/// cost: pixels go to a terminal once, and an unchanged scene writes nothing.
@MainActor
final class HerdrPaneImagesTests: XCTestCase {
    private let image = HerdrTerminalEngineTests.redImage(pane: "P")

    // MARK: - Store

    /// The store keeps an image while Herdr places or retains it, as Herdr's delivery does; Herdr
    /// sends the bytes again before placing an image it dropped.
    func testTheStoreKeepsWhatHerdrStillCountsAsDelivered() throws {
        var store = HerdrImageStore()
        let key = try XCTUnwrap(try scene(placing: [(0, 0)], bytes: true).placements.first?.asset)

        store.receive(try scene(placing: [(0, 0)], bytes: true))
        XCTAssertEqual(store[key]?.count, 16)
        store.receive(try scene(placing: [(1, 0)], bytes: false))
        XCTAssertEqual(store[key]?.count, 16, "placed again without its bytes")
        store.receive(try decode(HerdrTerminalEngineTests.scene(retaining: image)))
        XCTAssertEqual(store[key]?.count, 16, "retained while its pane is out of view")
        store.receive(try scene(placing: [], bytes: false))
        XCTAssertNil(store[key], "neither placed nor retained")
    }

    /// Bytes that don't match their declared length aren't kept, as in Herdr's client.
    func testTheStoreDropsBytesOfTheWrongLength() throws {
        var store = HerdrImageStore()
        let short = HerdrTerminalEngineTests.scene(placing: image, at: [(x: 0, y: 0, columns: 2, rows: 1)], sendingBytes: true)
            .replacingOccurrences(of: #""data":[255,0,0,255,"#, with: #""data":["#)
        let scene = try decode(short)
        store.receive(scene)
        XCTAssertNil(store[try XCTUnwrap(scene.placements.first?.asset)])
    }

    // MARK: - Pane commands

    /// An image is uploaded once: the same scene again writes nothing, and a moved placement is placed
    /// again without its pixels.
    func testPixelsGoToTheTerminalOnce() throws {
        var store = HerdrImageStore()
        var images = HerdrPaneImages()
        let first = try scene(placing: [(1, 0)], bytes: true)
        store.receive(first)

        let upload = text(images.update(to: try paneScene(first), from: store))
        XCTAssertEqual(upload.components(separatedBy: "a=t,").count - 1, 1)
        XCTAssertTrue(upload.contains("a=p,"))
        XCTAssertTrue(upload.hasPrefix("\u{1B}7") && upload.hasSuffix("\u{1B}8"), "the cursor stays where the painter left it")

        let again = images.update(to: try paneScene(first), from: store)
        XCTAssertEqual(again, [])

        let moved = try scene(placing: [(2, 1)], bytes: false)
        store.receive(moved)
        let move = text(images.update(to: try paneScene(moved), from: store))
        XCTAssertFalse(move.contains("a=t,"))
        XCTAssertTrue(move.contains("\u{1B}[2;3H\u{1B}_Ga=p,"))
    }

    /// A placement whose bytes haven't arrived is drawn once they do.
    func testAPlacementWaitsForItsBytes() throws {
        var store = HerdrImageStore()
        var images = HerdrPaneImages()
        let placed = try scene(placing: [(0, 0)], bytes: false)
        store.receive(placed)
        let waiting = images.update(to: try paneScene(placed), from: store)
        XCTAssertEqual(waiting, [])

        let arrived = try scene(placing: [(0, 0)], bytes: true)
        store.receive(arrived)
        let drawn = text(images.update(to: try paneScene(arrived), from: store))
        XCTAssertTrue(drawn.contains("a=t,") && drawn.contains("a=p,"))
    }

    /// Only a placement inside the pane's text area is drawn; its image is still kept.
    func testAPlacementOutsideItsPaneIsNotDrawn() throws {
        let outside = try scene(placing: [(7, 0)], bytes: true)
        let paneScene = try self.paneScene(outside)
        XCTAssertEqual(paneScene.placements, [])
        XCTAssertEqual(paneScene.kept, Set(outside.placements.map(\.asset)))
    }

    // MARK: - Fixtures

    /// The test image placed in pane P over 2×1 cells at each (x, y).
    private func scene(placing cells: [(Int, Int)], bytes: Bool) throws -> HerdrGraphicsScene {
        try decode(HerdrTerminalEngineTests.scene(
            placing: image,
            at: cells.map { (x: $0.0, y: $0.1, columns: 2, rows: 1) },
            sendingBytes: bytes
        ))
    }

    /// Pane P: an 8×3 text area at the frame's origin.
    private func paneScene(_ scene: HerdrGraphicsScene) throws -> HerdrPaneImages.Scene {
        let pane = try JSONDecoder().decode(
            HerdrSurfacePane.self,
            from: Data(HerdrTerminalEngineTests.pane("P", x: 0, width: 8, height: 3).utf8)
        )
        return HerdrPaneImages.Scene(scene, pane: pane)
    }

    private func text(_ commands: [UInt8]) -> String {
        String(decoding: commands, as: UTF8.self)
    }

    private func decode(_ json: String) throws -> HerdrGraphicsScene {
        try JSONDecoder().decode(HerdrGraphicsScene.self, from: Data(json.utf8))
    }
}
