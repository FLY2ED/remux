import SwiftUI

/// The Herdr notification on screen, as a banner at the top like an iOS notification's. A tap opens its
/// session at its pane; a swipe up puts it away.
struct HerdrNotificationBannerLayer: View {
    @ObservedObject var center: HerdrNotificationCenter
    let onOpen: (HerdrNotificationPolicy.Banner) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let banner = center.banner {
                HerdrNotificationBanner(banner: banner)
                    .onTapGesture { onOpen(banner) }
                    .gesture(
                        DragGesture(minimumDistance: 12).onEnded { drag in
                            if drag.translation.height < -24 { center.dismiss(banner.id) }
                        }
                    )
                    .id(banner.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: center.banner?.id)
        .onChange(of: center.banner?.id) {
            // VoiceOver reads a banner out as it does an iOS notification's.
            guard let banner = center.banner else { return }
            AccessibilityNotification.Announcement(
                "\(banner.notification.title), \(banner.origin.sessionName)"
            ).post()
        }
    }
}

/// The session the notification came from, then Herdr's title and its context line, with Herdr's dot
/// colour for the kind.
struct HerdrNotificationBanner: View {
    let banner: HerdrNotificationPolicy.Banner

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(banner.origin.sessionName) · \(banner.origin.serverName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(banner.notification.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let body = banner.notification.body, !body.isEmpty {
                    Text(body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 500)
        .herdrNotificationBannerSurface()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(banner.notification.paneID == nil ? "Opens the session" : "Opens the pane")
        .accessibilityIdentifier("herdr.notification.banner")
    }

    /// Herdr's colours: red for an agent that needs attention, blue for one that finished.
    private var dotColor: Color {
        switch banner.notification.kind {
        case .needsAttention: .red
        case .finished: .blue
        case .updateInstalled, .custom: .accentColor
        }
    }
}

private extension View {
    @ViewBuilder
    func herdrNotificationBannerSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if #available(iOS 26.0, *) {
            self
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
                .contentShape(shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .contentShape(shape)
        }
    }
}
