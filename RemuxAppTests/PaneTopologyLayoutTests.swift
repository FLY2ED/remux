import CoreGraphics
import XCTest
@testable import Remux

final class PaneTopologyLayoutTests: XCTestCase {
    func testSizeUsesAvailableWidthAndCapsItsHeight() {
        let size = PaneTopologyLayout.size(
            availableWidth: 361,
            maximumHeight: 240
        )

        XCTAssertEqual(size.width, 361, accuracy: 0.001)
        XCTAssertEqual(size.height, 240, accuracy: 0.001)
    }

    func testSizeUsesPortraitAspectWhenHeightAllows() {
        let size = PaneTopologyLayout.size(
            availableWidth: 361,
            maximumHeight: 520
        )

        XCTAssertEqual(size, CGSize(width: 361, height: 271))
    }

    func testPreservesSplitStructureWithEqualPaneArea() throws {
        let panes = fivePaneTopology()
        let metrics = try XCTUnwrap(PaneTopologyLayout.frames(
            panes: panes,
            size: CGSize(width: 360, height: 100)
        ))
        let frames = try panes.map { try XCTUnwrap(metrics.frame(for: $0.id)) }
        let expectedArea = frames[0].width * frames[0].height

        for frame in frames {
            XCTAssertEqual(frame.width * frame.height, expectedArea, accuracy: 0.01)
        }
        XCTAssertEqual(frames[0].minX, 0, accuracy: 0.001)
        XCTAssertEqual(frames[1].minX, 0, accuracy: 0.001)
        XCTAssertEqual(frames[2].minX, frames[0].maxX, accuracy: 0.001)
        XCTAssertEqual(frames[3].minX, frames[0].maxX, accuracy: 0.001)
        XCTAssertEqual(frames[4].minX, frames[0].maxX, accuracy: 0.001)
        XCTAssertEqual(frames[0].maxY, frames[1].minY, accuracy: 0.001)
        XCTAssertEqual(frames[2].maxY, frames[3].minY, accuracy: 0.001)
        XCTAssertEqual(frames[3].maxY, frames[4].minY, accuracy: 0.001)
    }

    /// Herdr with its borders and gaps off lays panes out with no cell between them; the map still cuts
    /// between them and gives every pane a tile, as for panes a border apart.
    func testTouchingPanesGetATileEach() throws {
        let left = UUID()
        let topRight = UUID()
        let bottomRight = UUID()
        let panes: [PaneTopologyLayout.Pane] = [
            .init(id: left, frame: .init(x: 0, y: 0, columns: 27, rows: 40)),
            .init(id: topRight, frame: .init(x: 27, y: 0, columns: 26, rows: 20)),
            .init(id: bottomRight, frame: .init(x: 27, y: 20, columns: 26, rows: 20)),
        ]
        let frames = try XCTUnwrap(PaneTopologyLayout.frames(panes: panes, size: CGSize(width: 300, height: 200)))

        XCTAssertEqual(frames.frame(for: left), CGRect(x: 0, y: 0, width: 100, height: 200))
        XCTAssertEqual(frames.frame(for: topRight), CGRect(x: 100, y: 0, width: 200, height: 100))
        XCTAssertEqual(frames.frame(for: bottomRight), CGRect(x: 100, y: 100, width: 200, height: 100))
    }

    /// Panes that overlap along an axis can't be cut there.
    func testOverlappingPanesAreNotCut() {
        let panes: [PaneTopologyLayout.Pane] = [
            .init(id: UUID(), frame: .init(x: 0, y: 0, columns: 28, rows: 40)),
            .init(id: UUID(), frame: .init(x: 27, y: 0, columns: 26, rows: 40)),
        ]
        XCTAssertNil(PaneTopologyLayout.frames(panes: panes, size: CGSize(width: 300, height: 200)))
    }

    private func fivePaneTopology() -> [PaneTopologyLayout.Pane] {
        [
            .init(id: UUID(), frame: .init(x: 0, y: 0, columns: 39, rows: 59)),
            .init(id: UUID(), frame: .init(x: 0, y: 60, columns: 39, rows: 40)),
            .init(id: UUID(), frame: .init(x: 40, y: 0, columns: 60, rows: 9)),
            .init(id: UUID(), frame: .init(x: 40, y: 10, columns: 60, rows: 69)),
            .init(id: UUID(), frame: .init(x: 40, y: 80, columns: 60, rows: 20)),
        ]
    }
}
