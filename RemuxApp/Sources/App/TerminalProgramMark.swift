import SwiftUI

/// How a program is marked: art on a tile with continuous corners, as Settings marks its rows. Every mark is
/// made here, so the programs' own logos take the place of the placeholders in one place.
struct TerminalProgramMark: Equatable {
    /// What a mark shows on its tile.
    enum Art: Equatable {
        case symbol(String)
    }

    /// The tile under the art: a logo's own background, else neutral. A pane behind the front one shows its
    /// tile alone.
    let tile: Color
    let art: Art

    /// A tile for art without a background of its own.
    static let neutralTile = Color(uiColor: .systemGray)

    init(_ program: TerminalProgram) {
        switch program {
        case .terminal:
            tile = Self.neutralTile
            art = .symbol("terminal.fill")
        case .agent:
            // Every agent shares the placeholder until the agents' logos are in.
            tile = Self.neutralTile
            art = .symbol("sparkle")
        }
    }

    /// The corner radius of a tile `side` points wide, in the proportion of an app icon's.
    static func cornerRadius(side: CGFloat) -> CGFloat {
        side * 0.225
    }
}

/// A window's panes as marks lying on top of each other: its focused pane's in front; for two panes, the edge
/// of one behind it; for three or more, the edges of two. Each step back is the same offset up and to the
/// right, a little smaller and dimmer, and shows only its program's tile. A gap is cut around each layer
/// where the next one in front overlaps it, and around the state dot on the front mark's top-right corner,
/// so the background shows through it in light and dark alike. Four panes or more also show how many, in a
/// badge on the front mark's bottom-right corner, as an app icon shows a count. The stack keeps one width
/// whatever it holds, so the text after it lines up.
struct TerminalProgramStack: View {
    /// What the window's panes run, its focused pane's first; `paneCount` may be more.
    let programs: [TerminalProgram]
    let paneCount: Int
    /// The state the dot on the front mark shows.
    let dot: TerminalAgentStatus?
    var side: CGFloat = 28

    /// How far each step back moves up and to the right, how much smaller it is, and how much dimmer.
    private static let step: CGFloat = 6
    private static let shrink: CGFloat = 0.1
    private static let dim: [Double] = [1, 0.62, 0.36]
    private static let gap: CGFloat = 1.5
    private static let dotSize: CGFloat = 10
    private static let badgeHeight: CGFloat = 14
    /// Room drawn around the stack for what reaches past it: the layers behind, above it, and the dot.
    private static let room: CGFloat = 14

    var body: some View {
        let room = Self.room
        Canvas { context, _ in
            let marks = programs.prefix(3).map(TerminalProgramMark.init)
            let count = paneCount >= 4 ? countText("\(paneCount)") : nil
            let dotBounds = dot.map { _ in
                CGRect(x: room + side - 3, y: room + 3, width: 0, height: 0)
                    .insetBy(dx: -Self.dotSize / 2, dy: -Self.dotSize / 2)
            }
            let badgeBounds = count.map { badge($0, center: CGPoint(x: room + side - 2, y: room + side - 2), context: context) }
            for index in marks.indices.reversed() {
                var layer = context
                for front in 0..<index {
                    layer.clip(to: tile(front, room: room, grownBy: Self.gap), options: .inverse)
                }
                if let dotBounds {
                    layer.clip(to: Path(ellipseIn: dotBounds.insetBy(dx: -Self.gap, dy: -Self.gap)), options: .inverse)
                }
                if let badgeBounds {
                    layer.clip(to: capsule(badgeBounds.insetBy(dx: -Self.gap, dy: -Self.gap)), options: .inverse)
                }
                layer.opacity = Self.dim[index]
                layer.fill(tile(index, room: room), with: .color(marks[index].tile))
                if index == 0 {
                    let bounds = tile(0, room: room).boundingRect
                    switch marks[0].art {
                    case .symbol(let name):
                        let symbol = Text(Image(systemName: name)).font(.system(size: side * 0.5, weight: .semibold))
                        layer.draw(symbol.foregroundStyle(.white), at: CGPoint(x: bounds.midX, y: bounds.midY))
                    }
                }
            }
            if let dotBounds, let dot {
                context.fill(Path(ellipseIn: dotBounds), with: .color(dot.color))
            }
            if let count, let badgeBounds {
                context.fill(capsule(badgeBounds), with: .color(.primary))
                context.draw(count, at: CGPoint(x: badgeBounds.midX, y: badgeBounds.midY))
            }
        }
        .frame(width: side + Self.step * 2 + room * 2, height: side + room * 2)
        .padding(-room)
        .accessibilityHidden(true)
    }

    /// The layer `index` steps back, grown by `growth` on every side.
    private func tile(_ index: Int, room: CGFloat, grownBy growth: CGFloat = 0) -> Path {
        let size = side * (1 - Self.shrink * CGFloat(index))
        let offset = Self.step * CGFloat(index)
        let rect = CGRect(x: room + side + offset - size, y: room - offset, width: size, height: size)
            .insetBy(dx: -growth, dy: -growth)
        return Path(roundedRect: rect, cornerRadius: TerminalProgramMark.cornerRadius(side: size) + growth, style: .continuous)
    }

    private func capsule(_ rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: rect.height / 2, style: .continuous)
    }

    /// The count, in the background's colour, on a badge filled in the text's.
    private func countText(_ text: String) -> Text {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color(uiColor: .systemBackground))
    }

    /// The badge's bounds for `count`, centred on `center`: round for one digit, wider for more.
    private func badge(_ count: Text, center: CGPoint, context: GraphicsContext) -> CGRect {
        let width = max(Self.badgeHeight, context.resolve(count).measure(in: CGSize(width: 100, height: 100)).width + 7)
        return CGRect(x: center.x - width / 2, y: center.y - Self.badgeHeight / 2, width: width, height: Self.badgeHeight)
    }
}
