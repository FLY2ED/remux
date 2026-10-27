import SwiftUI

/// Ghostty's visual bell (`bell-features = border`, macOS `BellBorderOverlay`): a border around the
/// terminal while a bell is unanswered. Its colour, width and fade are Ghostty's.
struct GhosttyBellBorder: View {
    let isRinging: Bool

    var body: some View {
        Rectangle()
            .strokeBorder(Color(red: 1.0, green: 0.8, blue: 0.0).opacity(0.5), lineWidth: 3)
            .allowsHitTesting(false)
            .opacity(isRinging ? 1 : 0)
            .animation(.easeInOut(duration: 0.3), value: isRinging)
            .accessibilityHidden(true)
    }
}
