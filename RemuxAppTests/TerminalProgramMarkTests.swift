import UIKit
import XCTest
@testable import Remux

/// The Tabs sheet's marks: every agent Herdr knows has its glyph in the asset catalog for light and dark, and
/// everything else falls back.
final class TerminalProgramMarkTests: XCTestCase {
    /// The agent ids Herdr 0.9.5 sends (`src/detect/mod.rs` `agent_label`).
    private static let herdrAgents = [
        "pi", "claude", "codex", "gemini", "cursor", "devin", "agy", "cline", "omp", "mastracode", "opencode",
        "copilot", "kimi", "kiro", "droid", "amp", "grok", "hermes", "kilo", "qodercli", "qwen", "letta", "maki",
        "muse",
    ]
    /// Agents whose marks don't read at the Tabs sheet's size.
    private static let generic: Set = ["hermes", "maki", "muse"]

    func testEveryAgentHerdrKnowsHasItsLogoInLightAndDark() {
        for id in Self.herdrAgents where !Self.generic.contains(id) {
            guard case .glyph(let name) = TerminalProgramMark(.agent(id)).art else {
                XCTFail("\(id) has no glyph")
                continue
            }
            XCTAssertEqual(name, "AgentGlyph-\(id)")
            for style in [UIUserInterfaceStyle.light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: style)
                XCTAssertNotNil(UIImage(named: name, in: .main, compatibleWith: traits), "\(id), \(style.rawValue)")
            }
        }
    }

    /// An agent without a mark of its own, as the ones that report to Herdr by a name of their own choosing,
    /// shows the sparkle on the neutral tile; a pane without an agent shows a shell's prompt on its charcoal tile.
    func testOtherAgentsAndPanesFallBack() {
        for id in Self.generic.sorted() + ["crush", "command-code", "my-agent"] {
            let mark = TerminalProgramMark(.agent(id))
            XCTAssertEqual(mark.art, .symbol("sparkle"), id)
            XCTAssertEqual(mark.tile, .solid(0x8E8E93), id)
        }
        XCTAssertEqual(TerminalProgramMark(.terminal).art, .prompt)
        XCTAssertEqual(TerminalProgramMark(.terminal).tile, .vertical((0x43454A, 0), (0x2A2C30, 1)))
    }

    /// The front tile sits at the column's leading edge, two tiles its size behind it, each 5 points right of and 4
    /// points above the one in front, the dot sits on the front tile's top-trailing corner and the count at the
    /// column's bottom-trailing corner, with every edge on whole pixels at 2x and 3x.
    func testStackGeometry() throws {
        for scale in [CGFloat(2), 3] {
            let layout = TerminalProgramStack.layout(tileCount: 3, paneCount: 12, hasDot: true, scale: scale)
            XCTAssertEqual(layout.tiles, [
                CGRect(x: 0, y: 0, width: 30, height: 24),
                CGRect(x: 5, y: -4, width: 30, height: 24),
                CGRect(x: 10, y: -8, width: 30, height: 24),
            ])
            let dot = try XCTUnwrap(layout.dot)
            XCTAssertEqual(dot.size, CGSize(width: 7, height: 7))
            XCTAssertEqual(dot.midX, 28, accuracy: 1 / scale)
            XCTAssertEqual(dot.midY, 2, accuracy: 1 / scale)
            XCTAssertEqual(layout.badge, CGRect(x: 36, y: 15, width: 20, height: 14))
            let edges = (layout.tiles + [dot]).flatMap { [$0.minX, $0.minY, $0.maxX, $0.maxY] }
            for edge in edges {
                XCTAssertEqual((edge * scale).rounded(), edge * scale, accuracy: 1e-9, "\(edge) at \(scale)x")
            }
        }
    }

    /// Four panes or more show their count, up to "99+", in a capsule that grows leftward from the column's edge.
    func testCountShowsFourPanesOrMore() {
        XCTAssertNil(TerminalProgramStack.count(3))
        XCTAssertEqual(TerminalProgramStack.count(4), "4")
        XCTAssertEqual(TerminalProgramStack.count(99), "99")
        XCTAssertEqual(TerminalProgramStack.count(100), "99+")
        let badges = [3, 4, 12, 100].map { TerminalProgramStack.layout(tileCount: 3, paneCount: $0, hasDot: false, scale: 3).badge }
        XCTAssertEqual(badges.map { $0?.width }, [nil, 14, 20, 24])
        XCTAssertEqual(Set(badges.compactMap { $0?.maxX }), [TerminalProgramStack.width])
    }
}
