import SwiftUI
import UIKit
import XCTest
@testable import Remux

/// The pane lines keep their place on the grid while the terminal area's size animates, as it does when the
/// keyboard comes up or goes down. Core Animation scales a layer's drawing to its bounds through a bounds
/// animation, so a line drawn into a layer whose bounds animate is drawn stretched until the animation ends,
/// while the panes, which are laid out without animation, stay where they are.
@MainActor
final class GhosttyPaneLinesViewTests: XCTestCase {
    /// 8 x 17.67 points at 3x.
    private let cell = GhosttyTerminalCellDisplayMetrics(pixelWidth: 24, pixelHeight: 53, contentScale: 3)
    private let grid = GhosttyTerminalGridSize(columns: 50, rows: 41)
    /// The terminal area with the keyboard down, and with it up.
    private let tall = CGSize(width: 402, height: 726)
    private let short = CGSize(width: 402, height: 459)

    /// The panes' lines draw in a view of their own on the grid's canvas, behind the panes, and the area's
    /// own layer, whose bounds the keyboard animates, draws nothing: through the animation the lines stay on
    /// the canvas, unanimated.
    func testThePanesLinesStayOnTheGridWhileTheTerminalAreaAnimates() throws {
        let projection = GhosttyTerminalViewportPresentationProjection(
            windowGrid: grid,
            cellMetrics: cell,
            panes: [],
            paneLines: box(ink: .separator),
            focusedSurfaceID: nil,
            isServerZoomed: false,
            windowCount: 1
        )
        let (window, host) = show(GhosttyCompositeViewportView(
            surfaceLookup: .empty,
            projection: projection,
            terminalTheme: TerminalTheme.allCases[0],
            trackpadDriver: GhosttyKeyboardCursorTrackpadDriver(),
            onSurfaceTap: nil,
            onPreviewSelection: nil,
            onWindowSwipe: nil,
            sendKeyEventToSurface: { _, _ in false },
            onTrackpadFeedbackChange: { _ in },
            isMouseCaptured: { _ in false },
            submitMouseButton: nil,
            submitMousePosition: nil,
            submitMouseScroll: nil,
            selectionSource: nil
        ))
        defer { hide(window) }
        let area = try XCTUnwrap(descendant(of: host.view, named: "GhosttyCompositeViewportContainerView"))
        XCTAssertEqual(area.bounds.size, tall)

        UIView.animate(withDuration: 0.4) {
            area.frame.size = self.short
            area.layoutIfNeeded()
        }
        area.layer.displayIfNeeded()

        XCTAssertNotNil(area.layer.animation(forKey: "bounds.size"), "the area's bounds didn't animate")
        XCTAssertNil(area.layer.contents, "the lines are drawn into the layer whose bounds animate")
        let lines = try XCTUnwrap(descendant(of: area, named: "GhosttyPaneLinesUIView"), "no view of the lines")
        XCTAssertEqual(lines.frame, canvas(in: short))
        XCTAssertEqual(lines.layer.animationKeys() ?? [], [], "the lines' geometry animated")
        XCTAssertEqual(area.subviews.first, lines, "the lines aren't behind the panes")
    }

    /// The popup's frame draws its lines the same way, on the canvas, above the panes: while the area under
    /// it animates its size, the frame's lines keep the canvas's place and size, unanimated.
    func testThePopupsFrameStaysOnTheGridWhileTheTerminalAreaAnimates() throws {
        let popup = GhosttyTerminalViewportPresentationProjection.Popup(
            id: UUID(),
            title: "popup",
            tabLabel: nil,
            border: box(ink: .color(red: 120, green: 160, blue: 240)),
            titleInk: .separator,
            tabInk: .separator,
            grid: nil,
            cell: nil
        )
        let (window, host) = show(GhosttyTerminalPopupFrameView(
            popup: popup,
            windowGrid: grid,
            cellMetrics: cell,
            surfaceLookup: .empty,
            terminalTheme: TerminalTheme.allCases[0],
            keyboardMode: .hidden,
            submitScroll: nil,
            submitPointer: nil,
            isMouseCaptured: nil,
            submitMouseButton: nil,
            onTap: {}
        ))
        defer { hide(window) }
        let lines = try XCTUnwrap(descendant(of: host.view, named: "GhosttyPaneLinesUIView"), "no view of the lines")
        assertSize(lines.bounds.size, canvas(in: tall).size)
        let origin = lines.convert(CGPoint.zero, to: host.view)

        UIView.animate(withDuration: 0.4) {
            host.view.frame.size = self.short
            host.view.layoutIfNeeded()
        }

        assertSize(lines.bounds.size, canvas(in: short).size)
        XCTAssertEqual(lines.convert(CGPoint.zero, to: host.view), origin)
        XCTAssertEqual(lines.layer.animationKeys() ?? [], [], "the frame's lines' geometry animated")
    }

    /// A box on the grid's outer cells, as Herdr draws a pane's or a popup's.
    private func box(ink: GhosttyPaneLine.Ink) -> [GhosttyPaneLine] {
        let columns = CGFloat(grid.columns), rows = CGFloat(grid.rows)
        return [
            GhosttyPaneLine(orientation: .horizontal, position: 0.5, start: 0.5, end: columns - 0.5, ink: ink, width: 1, cap: .square),
            GhosttyPaneLine(orientation: .horizontal, position: rows - 0.5, start: 0.5, end: columns - 0.5, ink: ink, width: 1, cap: .square),
            GhosttyPaneLine(orientation: .vertical, position: 0.5, start: 0.5, end: rows - 0.5, ink: ink, width: 1, cap: .square),
            GhosttyPaneLine(orientation: .vertical, position: columns - 0.5, start: 0.5, end: rows - 0.5, ink: ink, width: 1, cap: .square),
        ]
    }

    /// SwiftUI hands its views sizes a rounding away from the canvas's.
    private func assertSize(_ size: CGSize, _ expected: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(size.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(size.height, expected.height, accuracy: 0.001, file: file, line: line)
    }

    private func canvas(in size: CGSize) -> CGRect {
        let layout = GhosttyCompositeViewportLayout(bounds: CGRect(origin: .zero, size: size), grid: grid, cellMetrics: cell)!
        return CGRect(origin: layout.origin, size: layout.canvasSize)
    }

    private func show<Content: View>(_ content: Content) -> (UIWindow, UIHostingController<Content>) {
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: tall))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        return (window, host)
    }

    private func hide(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// The first view under `root`, depth first, whose class is named `name`.
    private func descendant(of root: UIView, named name: String) -> UIView? {
        for view in root.subviews {
            if String(describing: type(of: view)) == name { return view }
            if let found = descendant(of: view, named: name) { return found }
        }
        return nil
    }
}
