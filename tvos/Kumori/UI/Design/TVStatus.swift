import SwiftUI

/// Loading, empty and error each get their own words and a way forward. A page shows one of
/// these only when it has nothing else to show: a background refresh never replaces content
/// that is already on screen.
struct TVStatusView<Actions: View>: View {
    enum Kind {
        /// First load, nothing to show yet.
        case loading
        /// The answer came back and it is empty.
        case empty
        /// The request failed. Say why and offer to retry.
        case error
    }

    let kind: Kind
    let title: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: TVTokens.group) {
            switch kind {
            case .loading:
                ProgressView()
            case .empty:
                Image(systemName: "square.stack.3d.up").font(TVType.section).foregroundStyle(TVColor.secondary)
            case .error:
                Image(systemName: "wifi.exclamationmark").font(TVType.section).foregroundStyle(TVColor.accent)
            }
            Text(title)
                .font(TVType.section)
                .foregroundStyle(TVColor.primary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(TVType.body)
                    .foregroundStyle(TVColor.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: TVTokens.heroTextWidth)
            }
            HStack(spacing: TVTokens.group) { actions() }
                .padding(.top, TVTokens.small)
                .focusSection()
        }
        .padding(.horizontal, 64).padding(.vertical, 56)
        .frame(maxWidth: 1100)
        .tvSurface(.grouped, radius: 32)
        .accessibilityElement(children: .contain)
    }
}

extension TVStatusView where Actions == EmptyView {
    init(kind: Kind, title: String, message: String? = nil) {
        self.init(kind: kind, title: title, message: message) { EmptyView() }
    }
}
