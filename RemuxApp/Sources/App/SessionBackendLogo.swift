import SwiftUI

/// The mark of the program a session runs in, in place of a generic terminal icon, so a tmux and a Herdr
/// session with the same name are told apart at a glance. Both marks carry their own colors.
struct SessionBackendLogo: View {
    let backend: SessionBackend
    var size: CGFloat = 30

    var body: some View {
        Image(backend.logoAssetName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 7 / 30))
            .accessibilityLabel(backend.displayName)
    }
}

private extension SessionBackend {
    var logoAssetName: String {
        switch self {
        case .tmux: "SessionBackendTmux"
        case .herdr: "SessionBackendHerdr"
        }
    }
}
