import SwiftUI
import UIKit

/// A popup the backend shows over the terminal area, framed as Herdr's client frames one: a box of lines on
/// the outer cells of the panes' grid, drawn as the panes' lines are, the popup's title in its top line, and
/// the popup's terminal in the cells inside, at the panes' font. Remux adds the tab it is open over at the
/// top line's other end. A tap brings up the keyboard and a swipe scrolls, as on a pane.
struct GhosttyTerminalPopupFrameView: View {
    let popup: GhosttyTerminalViewportPresentationProjection.Popup
    /// The panes' grid and cell, which the frame is laid out on.
    let windowGrid: GhosttyTerminalGridSize?
    let cellMetrics: GhosttyTerminalCellDisplayMetrics?
    let surfaceLookup: GhosttyManagedSurfaceLookup
    let terminalTheme: TerminalTheme
    /// For the layout record only.
    let keyboardMode: GhosttyKeyboardChromeMode
    let submitScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let submitPointer: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    let onTap: () -> Void

    var body: some View {
        GeometryReader { proxy in
            if let windowGrid, let cellMetrics,
               let layout = GhosttyCompositeViewportLayout(
                   bounds: CGRect(origin: .zero, size: proxy.size),
                   grid: windowGrid,
                   cellMetrics: cellMetrics
               ),
               let content = GhosttyTerminalViewportPresentationProjection.Popup.content(in: windowGrid)
            {
                let contentFrame = layout.frame(for: content)
                ZStack(alignment: .topLeading) {
                    GhosttyPaneLinesView(
                        lines: popup.border,
                        layout: layout,
                        separatorColor: terminalTheme.terminalCompositeSeparatorUIColor
                    )
                    .accessibilityHidden(true)
                    GhosttyTerminalPopupHost(
                        popup: popup,
                        surfaceLookup: surfaceLookup,
                        keyboardMode: keyboardMode,
                        submitScroll: submitScroll,
                        submitPointer: submitPointer,
                        onTap: onTap
                    )
                    .frame(width: contentFrame.width, height: contentFrame.height)
                    .offset(x: contentFrame.minX, y: contentFrame.minY)
                    .accessibilityElement()
                    .accessibilityLabel("Terminal")
                    .accessibilityIdentifier("terminal.popup.content")
                    labels(layout: layout, columns: windowGrid.columns)
                }
            }
        }
        .background(terminalTheme.terminalSurfaceBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.popup")
    }

    /// The top line's cells between its corners: the title from the first, as Herdr's client writes it,
    /// and the tab at the other end.
    private func labels(layout: GhosttyCompositeViewportLayout, columns: UInt32) -> some View {
        let cell = layout.cellSize
        let font = Font(Self.labelFont(cellWidth: cell.width))
        return HStack(spacing: 0) {
            label(popup.title, ink: popup.titleInk, font: font, height: cell.height)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("terminal.popup.title")
            Spacer(minLength: cell.width)
            if let tabLabel = popup.tabLabel {
                label("over \(tabLabel)", ink: popup.tabInk, font: font, height: cell.height)
                    .accessibilityIdentifier("terminal.popup.tab")
            }
        }
        .frame(width: CGFloat(max(Int(columns) - 2, 0)) * cell.width, height: cell.height, alignment: .leading)
        .offset(x: layout.origin.x + cell.width, y: layout.origin.y)
    }

    /// The label's cells take the place of the line under it, as a title's do in Herdr's client.
    private func label(_ text: String, ink: GhosttyPaneLine.Ink, font: Font, height: CGFloat) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color(of: ink))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: height)
            .background(terminalTheme.terminalSurfaceBackground)
    }

    private func color(of ink: GhosttyPaneLine.Ink) -> Color {
        switch ink {
        case .color(let red, let green, let blue):
            Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
        case .focus:
            Color.accentColor
        case .separator:
            Color(uiColor: terminalTheme.terminalCompositeSeparatorUIColor)
        }
    }

    /// The system's monospaced font at the size whose characters are a cell wide. Herdr's client writes the
    /// title in the terminal's own font, which isn't one UIKit has; this one follows the terminal's font
    /// size, a character a cell.
    static func labelFont(cellWidth: CGFloat) -> UIFont {
        let reference = UIFont.monospacedSystemFont(ofSize: 100, weight: .regular)
        let advance = ("0" as NSString).size(withAttributes: [.font: reference]).width
        return UIFont.monospacedSystemFont(ofSize: 100 * cellWidth / advance, weight: .regular)
    }
}

/// Lines drawn as the panes' lines are (`GhosttyPaneLine.draw`), over a clear background.
private struct GhosttyPaneLinesView: UIViewRepresentable {
    let lines: [GhosttyPaneLine]
    let layout: GhosttyCompositeViewportLayout
    let separatorColor: UIColor

    func makeUIView(context: Context) -> GhosttyPaneLinesUIView {
        GhosttyPaneLinesUIView()
    }

    func updateUIView(_ view: GhosttyPaneLinesUIView, context: Context) {
        view.update(lines: lines, layout: layout, separatorColor: separatorColor)
    }
}

private final class GhosttyPaneLinesUIView: UIView {
    private var lines: [GhosttyPaneLine] = []
    private var layout: GhosttyCompositeViewportLayout?
    private var separatorColor = UIColor.clear

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(lines: [GhosttyPaneLine], layout: GhosttyCompositeViewportLayout, separatorColor: UIColor) {
        guard lines != self.lines || layout != self.layout || !separatorColor.isEqual(self.separatorColor) else { return }
        self.lines = lines
        self.layout = layout
        self.separatorColor = separatorColor
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let layout, let context = UIGraphicsGetCurrentContext() else { return }
        let separator = separatorColor.cgColor
        GhosttyPaneLine.draw(
            lines,
            in: context,
            layout: layout,
            scale: max(window?.screen.scale ?? traitCollection.displayScale, 1)
        ) { ink in
            switch ink {
            case .separator, .focus:
                separator
            case .color(let red, let green, let blue):
                UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1).cgColor
            }
        }
    }
}

/// Hosts the popup's surface at its grid's size, whole pixels at the panes' font.
private struct GhosttyTerminalPopupHost: UIViewRepresentable {
    let popup: GhosttyTerminalViewportPresentationProjection.Popup
    let surfaceLookup: GhosttyManagedSurfaceLookup
    let keyboardMode: GhosttyKeyboardChromeMode
    let submitScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let submitPointer: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    let onTap: () -> Void

    func makeUIView(context: Context) -> GhosttyTerminalPopupHostView {
        GhosttyTerminalPopupHostView()
    }

    func updateUIView(_ view: GhosttyTerminalPopupHostView, context: Context) {
        view.onTap = onTap
        view.keyboardMode = keyboardMode
        view.update(
            popup: popup,
            surface: surfaceLookup.managedSurface(for: popup.id),
            submitScroll: submitScroll,
            submitPointer: submitPointer
        )
    }

    static func dismantleUIView(_ view: GhosttyTerminalPopupHostView, coordinator: ()) {
        view.dismantle()
    }
}

/// The popup's terminal, in the cells inside the frame. It draws the grid of Herdr's frames at its cells'
/// size from the cells' top left: while Herdr's frames catch up with a new grid, the grid drawn has more or
/// fewer cells than there are, as the panes' canvas does. A tap brings up the keyboard; the scroll container
/// forwards swipes. Each new placement is recorded in the diagnostics, for the popup's layout record.
final class GhosttyTerminalPopupHostView: UIView {
    var onTap: (() -> Void)?
    var keyboardMode: GhosttyKeyboardChromeMode = .hidden
    private let container = GhosttyPaneScrollContainerView()
    private var drawable: CGSize?
    private var recorded: (cells: CGRect, drawable: CGSize)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        container.backgroundColor = .clear
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        popup: GhosttyTerminalViewportPresentationProjection.Popup,
        surface: GhosttyManagedSurface?,
        submitScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?,
        submitPointer: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    ) {
        guard let surface, let grid = popup.grid, let cell = popup.cell, cell.contentScale > 0 else {
            detachSurface()
            return
        }
        drawable = CGSize(
            width: Double(grid.columns) * Double(cell.pixelWidth) / cell.contentScale,
            height: Double(grid.rows) * Double(cell.pixelHeight) / cell.contentScale
        )
        if container.superview !== self { addSubview(container) }
        container.update(
            surface: surface,
            displayScale: scale,
            submitRouteForwardedMouseScroll: submitScroll,
            submitRouteForwardedMousePosition: submitPointer
        )
        setNeedsLayout()
    }

    func dismantle() {
        detachSurface()
        onTap = nil
    }

    private func detachSurface() {
        drawable = nil
        container.detachCurrentSurfaceForRemoval()
        container.removeFromSuperview()
    }

    private var scale: CGFloat {
        max(window?.screen.scale ?? traitCollection.displayScale, 1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let drawable else { return }
        let frame = CGRect(origin: .zero, size: drawable)
        // Cell geometry never animates, even in a layout pass inside another animation.
        UIView.performWithoutAnimation {
            guard container.frame != frame else { return }
            container.frame = frame
            container.layoutIfNeeded()
        }
        record(drawable: drawable)
    }

    private func record(drawable: CGSize) {
        guard GhosttyRuntimeTrace.diagnosticsEnabled, window != nil else { return }
        let cells = convert(bounds, to: nil)
        guard recorded.map({ $0.cells != cells || $0.drawable != drawable }) ?? true else { return }
        recorded = (cells, drawable)
        let orientation = window?.windowScene?.interfaceOrientation.isLandscape == true ? "landscape" : "portrait"
        GhosttyRuntimeTrace.diagnostics(
            "popup host keyboard=\(keyboardMode) orientation=\(orientation) scale=\(scale) "
                + "cells=\(cells.width)x\(cells.height)pt@(\(cells.minX),\(cells.minY)) "
                + "drawable=\(drawable.width)x\(drawable.height)pt"
        )
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        recorded = nil
        setNeedsLayout()
    }

    @objc private func tapped() {
        onTap?()
    }
}
