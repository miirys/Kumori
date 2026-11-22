import SwiftUI

// The Home shelves' card, as on Kumori for Android: a poster at rest that, under focus,
// opens sideways into a wide banner with the game's title, its store and genre, and a few
// lines about it. Its neighbours make room as it opens, so the row moves as one.

/// A titled row of expanding cards, aligned to the safe edge.
struct TVExpandingShelf<Item: Identifiable, Card: View>: View {
    let title: String
    let items: [Item]
    /// Builds one card for an item at the poster width the shelf works out.
    @ViewBuilder let card: (Item, CGFloat) -> Card

    @Environment(\.tvLayout) private var layout
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let width = TVExpandingCard.posterWidth(in: layout, at: typeSize)
        VStack(alignment: .leading, spacing: 0) {
            TVSectionHeader(title: title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: TVExpandingCard.gap) {
                    ForEach(items) { item in card(item, width) }
                }
                .padding(.horizontal, TVTokens.safeX)
                .padding(.top, TVTokens.group)
                .padding(.bottom, TVTokens.focusClearance)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }
}

struct TVExpandingCard: View {
    let id: String
    let title: String
    /// Store and genre: "Steam · Action".
    var line: String?
    var summary: String?
    let poster: TVArtworkSource
    let wide: TVArtworkSource
    /// The poster width; the card is this wide at rest.
    let width: CGFloat
    var running = false
    /// What the page background shows while this has focus.
    var backdrop: TVArtworkSource?
    let action: () -> Void

    @Environment(\.tvAmbient) private var ambient
    @Environment(\.tvReduceMotion) private var reduced
    @FocusState private var focused: Bool
    @State private var open = false

    /// Seven posters across the safe width at default text size, fewer at larger sizes.
    static func posterWidth(in layout: TVLayout, at size: DynamicTypeSize) -> CGFloat {
        let columns = size.isAccessibilitySize ? 4 : (size > .large ? 5 : 7)
        let gaps = CGFloat(columns - 1) * gap
        return ((layout.contentWidth - gaps) / CGFloat(columns)).rounded(.down)
    }

    static let gap: CGFloat = 36

    private var height: CGFloat { (width / TVTokens.poster).rounded() }
    private var openWidth: CGFloat { (height * 16 / 9).rounded() }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: TVTokens.artRadius, style: .continuous) }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                // The wide art is laid out at its full width from the start and uncovered as
                // the card opens, so it never stretches.
                TVArtwork(source: wide, title: title, titleOnPlaceholder: false, fill: true)
                    .frame(width: openWidth, height: height)
                    .opacity(open ? 1 : 0)
                TVArtwork(source: poster, title: title, shape: .poster, fill: true)
                    .frame(width: width, height: height)
                    .opacity(open ? 0 : 1)
                info
                    .frame(width: openWidth, height: height, alignment: .bottomLeading)
                    .opacity(open ? 1 : 0)
            }
            .frame(width: open ? openWidth : width, height: height, alignment: .leading)
            .clipShape(shape)
            .hoverEffect(.highlight)
        }
        .buttonStyle(.borderless)
        .focused($focused)
        .onChange(of: focused) { _, now in
            if now { ambient?.show(backdrop ?? wide) }
            // In one transaction, so the cards beside this one move with it.
            withAnimation(reduced ? TVMotion.reducedFade : (now ? TVMotion.cardOpen : TVMotion.cardClose)) {
                open = now
            }
        }
        .accessibilityIdentifier("lockup-\(id)")
        .accessibilityLabel([title, line, running ? "Running" : nil].compactMap { $0 }.joined(separator: ", "))
    }

    /// Title, store and genre, and the summary, over a dark fade at the bottom left.
    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TVType.callout.weight(.semibold))
                .foregroundStyle(TVColor.primary)
                .lineLimit(1)
            if let sub = running ? ["Still running", line].compactMap({ $0 }).joined(separator: " \u{00B7} ") : line,
               !sub.isEmpty {
                Text(sub)
                    .font(TVType.detail.weight(.medium))
                    .foregroundStyle(TVColor.secondary)
                    .lineLimit(1)
            }
            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(TVType.detail)
                    .foregroundStyle(TVColor.secondary)
                    .lineLimit(3)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: openWidth * 0.62, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.86), location: 0),
                    .init(color: .black.opacity(0.55), location: 0.45),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .bottomLeading, endPoint: .topTrailing
            )
        }
        .accessibilityHidden(true)
    }
}
