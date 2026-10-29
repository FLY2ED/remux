import SwiftUI
import UIKit

/// How a program is marked, after the Rex app's tab list: a landscape tile with continuous corners, in the same
/// colours in light and dark. Every mark is made here.
///
/// The art contract: an agent Herdr knows shows its maker's official glyph, `AgentGlyph-<id>` in the asset
/// catalog, at its own box size for a 24-point-tall tile, centred on the agent's own tile as its app icon or brand
/// kit has it: one colour, or the icon's vertical gradient. The same tile shows in light and dark; a dark form
/// would come only from its maker. Any program that isn't an agent shows a shell: a mint `>_` on a charcoal
/// gradient. An agent without a known mark shows a white sparkle on a neutral tile.
struct TerminalProgramMark {
    enum Art: Equatable {
        /// The maker's glyph, from the asset catalog.
        case glyph(String)
        /// A shell's prompt.
        case prompt
        case symbol(String)
    }

    /// A tile's fill: one colour, or a vertical gradient's stops from top to bottom.
    struct Fill: Equatable {
        let stops: [Stop]

        struct Stop: Equatable {
            let rgb: UInt32
            let location: CGFloat
        }

        static func solid(_ rgb: UInt32) -> Fill {
            Fill(stops: [Stop(rgb: rgb, location: 0)])
        }

        static func vertical(_ stops: (UInt32, CGFloat)...) -> Fill {
            Fill(stops: stops.map { Stop(rgb: $0.0, location: $0.1) })
        }
    }

    let art: Art
    let tile: Fill
    /// The art's colour where the mark draws it itself: the prompt's or the symbol's; a glyph has its own.
    let ink: UInt32
    /// The glyph's box on a 24-point-tall tile.
    let box: CGSize

    init(_ program: TerminalProgram) {
        guard case .agent(let kind) = program else {
            self.init(art: .prompt, tile: .vertical((0x43454A, 0), (0x2A2C30, 1)), ink: 0xA8DDA8)
            return
        }
        guard let agent = Self.agents[kind] else {
            self.init(art: .symbol("sparkle"), tile: .solid(0x8E8E93), ink: 0xFFFFFF)
            return
        }
        self.init(art: .glyph("AgentGlyph-\(kind)"), tile: agent.tile, box: agent.box)
    }

    private init(art: Art, tile: Fill, ink: UInt32 = 0, box: CGSize = .zero) {
        self.art = art
        self.tile = tile
        self.ink = ink
        self.box = box
    }

    /// The tile's fill over `rect`.
    func shading(in rect: CGRect) -> GraphicsContext.Shading {
        guard tile.stops.count > 1 else { return .color(Self.color(tile.stops[0].rgb)) }
        return .linearGradient(
            Gradient(stops: tile.stops.map { Gradient.Stop(color: Self.color($0.rgb), location: $0.location) }),
            startPoint: CGPoint(x: rect.midX, y: rect.minY),
            endPoint: CGPoint(x: rect.midX, y: rect.maxY)
        )
    }

    var inkColor: Color {
        Self.color(ink)
    }

    /// The agents Herdr knows, by Herdr's names for them (`detect/mod.rs` `agent_label`): each one's tile and its
    /// glyph's box on a 24-point-tall tile, from each maker's app icon or brand kit. Hermes, Maki and Muse have no
    /// official mark that reads at this size, so they show the sparkle.
    private static let agents: [String: (tile: Fill, box: CGSize)] = [
        "claude": (.vertical((0xD97757, 0), (0xDB6843, 1)), CGSize(width: 14.88, height: 14.88)),
        "codex": (.solid(0xFFFFFF), CGSize(width: 15.19, height: 15.06)),
        "gemini": (.solid(0x1E1E2E), CGSize(width: 11.84, height: 15.94)),
        "agy": (.solid(0xFFFFFF), CGSize(width: 16, height: 14)),
        "copilot": (.solid(0xFFFFFF), CGSize(width: 16.30, height: 13.62)),
        "cursor": (.solid(0x14120B), CGSize(width: 12.49, height: 14.24)),
        "grok": (.solid(0x050505), CGSize(width: 16.07, height: 16.07)),
        "kiro": (.solid(0x9046FF), CGSize(width: 11.26, height: 13.69)),
        "opencode": (.solid(0x131010), CGSize(width: 10.95, height: 13.69)),
        "amp": (.vertical((0x2C3A2A, 0), (0x13261C, 0.38), (0x071C17, 0.68), (0x061615, 1)), CGSize(width: 22, height: 9.65)),
        "droid": (.solid(0x020202), CGSize(width: 15.23, height: 14.89)),
        "devin": (.solid(0xFFFFFF), CGSize(width: 12.53, height: 14.36)),
        "cline": (.solid(0x282524), CGSize(width: 16.63, height: 15.27)),
        "kilo": (.solid(0xFFDD00), CGSize(width: 13.72, height: 13.72)),
        "kimi": (.solid(0x000000), CGSize(width: 15.61, height: 15.03)),
        "qwen": (.solid(0xFFFFFF), CGSize(width: 13.82, height: 14.06)),
        "qodercli": (.solid(0xF3F3F3), CGSize(width: 14.69, height: 15.05)),
        "letta": (.solid(0x202020), CGSize(width: 13.87, height: 13.87)),
        "pi": (.solid(0x161D27), CGSize(width: 13.69, height: 13.69)),
        "omp": (.solid(0x0F0A14), CGSize(width: 12.98, height: 14.43)),
        "mastracode": (.solid(0x000000), CGSize(width: 17.01, height: 10.65)),
    ]

    static func color(_ rgb: UInt32) -> Color {
        Color(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

/// A window's panes as tiles cascading up and to the right, as SF Symbols' `square.on.square`: its focused pane's
/// tile in front, and the tiles of up to two of its other panes behind it, the same size, each one step further up
/// and right. Every tile is opaque, and only the tiles in front of it cover it. A tile behind the front one shows
/// its program by its tile alone: only a strip along its top and trailing edges shows, too little for any art to
/// read. A one-point clearance cut around each tile in front parts it from the tiles behind and shows what lies
/// under the stack, and every tile has a one-pixel keyline inside its edge. The state dot sits on the front tile's
/// top-trailing corner; four panes or more show how many in a capsule at the column's bottom-trailing corner.
///
/// The stack takes one fixed column whatever it holds, with its front tile at the column's leading edge, so the
/// front tiles of every row, and whatever follows the column, start at the same x. Every edge, keyline and
/// clearance falls on whole pixels at the display's scale. A sheet the system shrinks to float at a partial height
/// scales them with the rest of its content.
struct TerminalProgramStack: View {
    /// What the window's panes run, its focused pane's first; `paneCount` may be more.
    let programs: [TerminalProgram]
    let paneCount: Int
    /// The state the dot on the front tile shows.
    let dot: TerminalAgentStatus?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    /// Where a stack's parts go, in points from the column's leading edge and the front tile's top; the tiles behind
    /// rise above it.
    struct Layout: Equatable {
        /// The front tile's first.
        let tiles: [CGRect]
        let dot: CGRect?
        let badge: CGRect?
    }

    /// The column, to the count's trailing edge.
    static let width: CGFloat = 56
    static let tile = CGSize(width: 30, height: 24)
    private static let cornerRadius: CGFloat = 5
    /// How far each tile behind sits from the one in front of it.
    private static let step = CGSize(width: 5, height: -4)
    private static let dotCenter = CGPoint(x: 28, y: 2)
    private static let dotDiameter: CGFloat = 7
    private static let badgeHeight: CGFloat = 14
    private static let badgeTop: CGFloat = 15
    /// The count's capsule for one digit, two, and "99+".
    private static let badgeWidths: [CGFloat] = [14, 20, 24]
    /// What is cut away around each tile in front, the dot and the count, so the background parts them from what
    /// lies behind.
    private static let clearance: CGFloat = 1
    /// Room drawn around the column for the tiles behind, the dot and the count.
    private static let room: CGFloat = 8

    /// A shell's `>_` in a tile's points, and its stroke.
    private static let chevron = [CGPoint(x: 8.5, y: 7.5), CGPoint(x: 13, y: 12), CGPoint(x: 8.5, y: 16.5)]
    private static let underscore = (from: CGPoint(x: 14.5, y: 16.5), to: CGPoint(x: 21.5, y: 16.5))
    private static let promptStroke: CGFloat = 1.4

    /// What the count shows for `paneCount` panes: nothing for fewer than four, and at most "99+".
    static func count(_ paneCount: Int) -> String? {
        guard paneCount >= 4 else { return nil }
        return paneCount > 99 ? "99+" : "\(paneCount)"
    }

    /// Where `tileCount` tiles, the dot when there is one, and `paneCount`'s count go, with every edge on the
    /// device's pixels at `scale`. The tiles and the count lie on whole points. The dot's edges fall on half points,
    /// so it snaps its origin and keeps its size, since rounding its edges apart would make it an oval.
    static func layout(tileCount: Int, paneCount: Int, hasDot: Bool, scale: CGFloat) -> Layout {
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let tiles = (0..<min(tileCount, 3)).map { index in
            CGRect(origin: CGPoint(x: step.width * CGFloat(index), y: step.height * CGFloat(index)), size: tile)
        }
        let dot = hasDot
            ? CGRect(
                x: snap(dotCenter.x - dotDiameter / 2), y: snap(dotCenter.y - dotDiameter / 2),
                width: snap(dotDiameter), height: snap(dotDiameter)
            )
            : nil
        let badge = count(paneCount).map { text in
            let width = badgeWidths[min(text.count, badgeWidths.count) - 1]
            return CGRect(x: Self.width - width, y: badgeTop, width: width, height: badgeHeight)
        }
        return Layout(tiles: tiles, dot: dot, badge: badge)
    }

    var body: some View {
        let scale = displayScale
        let dark = colorScheme == .dark
        let keyline = dark ? Color.white.opacity(0.24) : Color.black.opacity(0.24)
        Canvas { context, _ in
            context.translateBy(x: Self.room, y: Self.room)
            let marks = programs.prefix(3).map(TerminalProgramMark.init)
            let placed = Self.layout(tileCount: marks.count, paneCount: paneCount, hasDot: dot != nil, scale: scale)
            let clearance = Self.pixels(Self.clearance, scale: scale)
            var cut = context
            if let dotBounds = placed.dot {
                cut.clip(to: Path(ellipseIn: dotBounds.insetBy(dx: -clearance, dy: -clearance)), options: .inverse)
            }
            if let badgeBounds = placed.badge {
                cut.clip(to: capsule(badgeBounds.insetBy(dx: -clearance, dy: -clearance)), options: .inverse)
            }
            // The farthest first, each cut around the tiles in front of it.
            for index in marks.indices.reversed() {
                var tile = cut
                for nearer in 0..<index {
                    let silhouette = placed.tiles[nearer].insetBy(dx: -clearance, dy: -clearance)
                    tile.clip(
                        to: Path(roundedRect: silhouette, cornerRadius: Self.cornerRadius + clearance, style: .continuous),
                        options: .inverse
                    )
                }
                draw(marks[index], in: placed.tiles[index], showsArt: index == 0, keyline: keyline, scale: scale, context: tile)
            }
            if let dotBounds = placed.dot, let dot {
                context.fill(Path(ellipseIn: dotBounds), with: .color(dot.color))
            }
            if let badgeBounds = placed.badge, let count = Self.count(paneCount) {
                context.fill(capsule(badgeBounds), with: .color(TerminalProgramMark.color(dark ? 0x505259 : 0x636366)))
                if dark {
                    // Its fill alone is too close to the dark glass to show where it ends.
                    stroke(
                        inside: badgeBounds, cornerRadius: badgeBounds.height / 2, color: TerminalProgramMark.color(0x8E8E93),
                        scale: scale, context: context
                    )
                }
                let text = Text(count)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(TerminalProgramMark.color(dark ? 0xF2F2F7 : 0xFFFFFF))
                context.draw(text, at: CGPoint(x: badgeBounds.midX, y: badgeBounds.midY))
            }
        }
        .frame(width: Self.width + Self.room * 2, height: Self.tile.height + Self.room * 2)
        .padding(-Self.room)
        .accessibilityHidden(true)
    }

    /// `points` in whole device pixels, at least one.
    private static func pixels(_ points: CGFloat, scale: CGFloat) -> CGFloat {
        max(1, (points * scale).rounded()) / scale
    }

    /// A tile: its fill, its art centred on it when `showsArt`, and its keyline.
    private func draw(_ mark: TerminalProgramMark, in rect: CGRect, showsArt: Bool, keyline: Color, scale: CGFloat, context: GraphicsContext) {
        let shape = Path(roundedRect: rect, cornerRadius: Self.cornerRadius, style: .continuous)
        context.fill(shape, with: mark.shading(in: rect))
        if showsArt {
            var art = context
            art.clip(to: shape)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            switch mark.art {
            case .glyph(let name):
                let image = art.resolve(Image(name))
                let fit = min(mark.box.width / image.size.width, mark.box.height / image.size.height)
                let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
                art.draw(image, in: CGRect(origin: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), size: size))
            case .prompt:
                art.stroke(
                    Self.prompt(in: rect),
                    with: .color(mark.inkColor),
                    style: StrokeStyle(lineWidth: Self.promptStroke, lineCap: .round, lineJoin: .round)
                )
            case .symbol(let name):
                let symbol = Text(Image(systemName: name)).font(.system(size: Self.tile.height * 0.5, weight: .semibold))
                art.draw(symbol.foregroundStyle(mark.inkColor), at: center)
            }
        }
        stroke(inside: rect, cornerRadius: Self.cornerRadius, color: keyline, scale: scale, context: context)
    }

    /// A line one device pixel wide just inside `rect`'s edge.
    private func stroke(inside rect: CGRect, cornerRadius: CGFloat, color: Color, scale: CGFloat, context: GraphicsContext) {
        let width = 1 / scale
        context.stroke(
            Path(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2), cornerRadius: cornerRadius - width / 2, style: .continuous),
            with: .color(color),
            lineWidth: width
        )
    }

    /// A shell's `>_` in `rect`.
    private static func prompt(in rect: CGRect) -> Path {
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x, y: rect.minY + p.y) }
        var path = Path()
        path.addLines(chevron.map(point))
        path.move(to: point(underscore.from))
        path.addLine(to: point(underscore.to))
        return path
    }

    private func capsule(_ rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: rect.height / 2, style: .continuous)
    }
}
