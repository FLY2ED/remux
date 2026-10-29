import SwiftUI
import UIKit

/// A popup the backend shows over the terminal area, as Herdr's client draws one: a thin frame in the
/// backend's accent with the popup's title in its top edge, filling the space a pane gets, with the
/// popup's terminal inside at the panes' font. Remux adds the tab it is open over at the frame's other end.
/// A tap brings up the keyboard and a swipe scrolls, as on a pane.
struct GhosttyTerminalPopupFrameView: View {
    let popup: GhosttyTerminalViewportPresentationProjection.Popup
    let surfaceLookup: GhosttyManagedSurfaceLookup
    let terminalTheme: TerminalTheme
    /// For the layout record only.
    let keyboardMode: GhosttyKeyboardChromeMode
    let onArea: (_ widthPx: UInt32, _ heightPx: UInt32) -> Void
    let submitScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let submitPointer: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    let onTap: () -> Void

    /// The frame's place in the terminal area, in points.
    enum Metrics {
        static let sideInset: CGFloat = 6
        static let border: CGFloat = 1.5
        /// The labels' line box, centred on the frame's top edge.
        static let labelHeight: CGFloat = 16
        static let labelInset: CGFloat = 10
        static let labelPadding: CGFloat = 4
        /// Between the frame and the terminal.
        static let padding: CGFloat = 4
        static let bottomInset: CGFloat = 2

        static var frameTop: CGFloat { labelHeight / 2 }
        static var contentInsets: EdgeInsets {
            EdgeInsets(
                top: labelHeight + padding,
                leading: sideInset + border + padding,
                bottom: bottomInset + border + padding,
                trailing: sideInset + border + padding
            )
        }
    }

    private var ink: Color {
        switch popup.ink {
        case .color(let red, let green, let blue):
            Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
        case .focus:
            Color.accentColor
        case .separator:
            Color(uiColor: .separator)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(ink, lineWidth: Metrics.border)
                .padding(EdgeInsets(
                    top: Metrics.frameTop,
                    leading: Metrics.sideInset,
                    bottom: Metrics.bottomInset,
                    trailing: Metrics.sideInset
                ))
                .accessibilityHidden(true)
            GhosttyTerminalPopupHost(
                popup: popup,
                surfaceLookup: surfaceLookup,
                keyboardMode: keyboardMode,
                onArea: onArea,
                submitScroll: submitScroll,
                submitPointer: submitPointer,
                onTap: onTap
            )
            .padding(Metrics.contentInsets)
            .accessibilityElement()
            .accessibilityLabel("Terminal")
            .accessibilityIdentifier("terminal.popup.content")
            labels
        }
        .background(terminalTheme.terminalSurfaceBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.popup")
    }

    private var labels: some View {
        HStack(spacing: 0) {
            label(popup.title, color: ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("terminal.popup.title")
            Spacer(minLength: Metrics.labelInset)
            if let tabLabel = popup.tabLabel {
                label("over \(tabLabel)", color: ink.opacity(0.6))
                    .accessibilityIdentifier("terminal.popup.tab")
            }
        }
        .frame(height: Metrics.labelHeight)
        .padding(.horizontal, Metrics.sideInset + Metrics.labelInset)
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, Metrics.labelPadding)
            .background(terminalTheme.terminalSurfaceBackground)
    }
}

/// Hosts the popup's surface at its grid's size, whole pixels at the panes' font.
private struct GhosttyTerminalPopupHost: UIViewRepresentable {
    let popup: GhosttyTerminalViewportPresentationProjection.Popup
    let surfaceLookup: GhosttyManagedSurfaceLookup
    let keyboardMode: GhosttyKeyboardChromeMode
    let onArea: (UInt32, UInt32) -> Void
    let submitScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?
    let submitPointer: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    let onTap: () -> Void

    func makeUIView(context: Context) -> GhosttyTerminalPopupHostView {
        GhosttyTerminalPopupHostView()
    }

    func updateUIView(_ view: GhosttyTerminalPopupHostView, context: Context) {
        view.onArea = onArea
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

/// The popup's terminal area. It reports the whole pixels inside its bounds, which the popup's grid fills,
/// and draws the grid at exactly its cells' size, on whole pixels (`placement`). A tap brings up the
/// keyboard; the scroll container forwards swipes. Each new placement is recorded in the diagnostics, for
/// the popup's layout record.
final class GhosttyTerminalPopupHostView: UIView {
    var onArea: ((UInt32, UInt32) -> Void)?
    var onTap: (() -> Void)?
    var keyboardMode: GhosttyKeyboardChromeMode = .hidden
    private let container = GhosttyPaneScrollContainerView()
    private var drawn: (grid: GhosttyTerminalGridSize, cell: GhosttyTerminalCellDisplayMetrics)?
    private var reported: (UInt32, UInt32)?
    private var recorded: CGRect?

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
        drawn = (grid, cell)
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
        onArea = nil
        onTap = nil
    }

    private func detachSurface() {
        drawn = nil
        container.detachCurrentSurfaceForRemoval()
        container.removeFromSuperview()
    }

    private var scale: CGFloat {
        max(window?.screen.scale ?? traitCollection.displayScale, 1)
    }

    /// The bounds' whole pixels: its edges rounded inward to the screen's pixels.
    private var pixelArea: (origin: CGPoint, widthPx: UInt32, heightPx: UInt32) {
        let scale = scale
        let inWindow = convert(bounds, to: nil)
        let minX = (inWindow.minX * scale).rounded(.up), maxX = (inWindow.maxX * scale).rounded(.down)
        let minY = (inWindow.minY * scale).rounded(.up), maxY = (inWindow.maxY * scale).rounded(.down)
        let origin = CGPoint(x: minX / scale - inWindow.minX, y: minY / scale - inWindow.minY)
        return (origin, UInt32(max(maxX - minX, 0)), UInt32(max(maxY - minY, 0)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = pixelArea
        if reported.map({ $0 != (area.widthPx, area.heightPx) }) ?? true, area.widthPx > 0, area.heightPx > 0 {
            reported = (area.widthPx, area.heightPx)
            onArea?(area.widthPx, area.heightPx)
        }
        guard let drawn else { return }
        let frame = Self.placement(
            areaOrigin: area.origin,
            widthPx: area.widthPx,
            heightPx: area.heightPx,
            grid: drawn.grid,
            cell: drawn.cell,
            scale: scale
        )
        // Cell geometry never animates, even in a layout pass inside another animation.
        UIView.performWithoutAnimation {
            guard container.frame != frame else { return }
            container.frame = frame
            container.layoutIfNeeded()
        }
        record(area: area, drawableFrame: frame)
    }

    /// Where the grid goes in the area: at its top left, past half of what is left over after the area's
    /// whole cells, on whole pixels. While Herdr's frames catch up with a new area, the grid drawn has more
    /// or fewer cells than the area holds; it is drawn where the area's grid will be, so nothing moves when
    /// they arrive.
    static func placement(
        areaOrigin: CGPoint,
        widthPx: UInt32,
        heightPx: UInt32,
        grid: GhosttyTerminalGridSize,
        cell: GhosttyTerminalCellDisplayMetrics,
        scale: CGFloat
    ) -> CGRect {
        func inset(_ room: UInt32, _ cellPx: UInt32) -> CGFloat {
            cellPx > 0 ? CGFloat((room % cellPx) / 2) / scale : 0
        }
        return CGRect(
            x: areaOrigin.x + inset(widthPx, cell.pixelWidth),
            y: areaOrigin.y + inset(heightPx, cell.pixelHeight),
            width: CGFloat(grid.columns * cell.pixelWidth) / cell.contentScale,
            height: CGFloat(grid.rows * cell.pixelHeight) / cell.contentScale
        )
    }

    private func record(area: (origin: CGPoint, widthPx: UInt32, heightPx: UInt32), drawableFrame: CGRect) {
        guard GhosttyRuntimeTrace.diagnosticsEnabled, recorded != drawableFrame else { return }
        recorded = drawableFrame
        let inWindow = convert(bounds, to: nil)
        let orientation = window?.windowScene?.interfaceOrientation.isLandscape == true ? "landscape" : "portrait"
        GhosttyRuntimeTrace.diagnostics(
            "popup host keyboard=\(keyboardMode) orientation=\(orientation) scale=\(scale) "
                + "bounds=\(inWindow.width)x\(inWindow.height)pt@(\(inWindow.minX),\(inWindow.minY)) "
                + "area=\(area.widthPx)x\(area.heightPx)px origin=(\(area.origin.x),\(area.origin.y))pt "
                + "drawable=\(drawableFrame.width)x\(drawableFrame.height)pt@(\(drawableFrame.minX),\(drawableFrame.minY))"
        )
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reported = nil
        recorded = nil
        setNeedsLayout()
    }

    @objc private func tapped() {
        onTap?()
    }
}
