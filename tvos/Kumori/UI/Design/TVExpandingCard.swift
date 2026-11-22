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
                TVArtwork(source: wide, title: "", titleOnPlaceholder: false, fill: true)
                    .frame(width: openWidth, height: height)
                    .opacity(open ? 1 : 0)
                TVArtwork(source: poster, title: title, shape: .poster, fill: true)
                    .frame(width: width, height: height)
                    .opacity(open ? 0 : 1)
                shade
                    .frame(width: openWidth, height: height)
                    .opacity(open ? 1 : 0)
                // The words come in a beat after the card has opened, out of a soft blur.
                info
                    .frame(width: openWidth, height: height, alignment: .bottomLeading)
                    .opacity(open ? 1 : 0)
                    .blur(radius: open || reduced ? 0 : 10)
                    .animation(reduced ? TVMotion.reducedFade
                               : (open ? .easeOut(duration: 0.38).delay(0.14) : .easeIn(duration: 0.12)),
                               value: open)
            }
            .frame(width: open ? openWidth : width, height: height, alignment: .leading)
            .clipShape(shape)
            // Lifted by its shadow and a touch of scale, with no outline or sheen.
            .shadow(color: .black.opacity(open ? 0.55 : 0), radius: open ? 30 : 0, y: open ? 18 : 0)
            .scaleEffect(open && !reduced ? 1.04 : 1, anchor: .leading)
        }
        .buttonStyle(TVPlainCardStyle())
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

    /// Darkness rising from the bottom and in from the left, under the words.
    private var shade: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.88), location: 0),
                .init(color: .black.opacity(0.5), location: 0.42),
                .init(color: .clear, location: 0.78),
            ], startPoint: .bottom, endPoint: .top)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.45), location: 0),
                .init(color: .clear, location: 0.6),
            ], startPoint: .leading, endPoint: .trailing)
        }
        .allowsHitTesting(false)
    }

    /// Title, store and genre, and the summary.
    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(TVType.section)
                .foregroundStyle(TVColor.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let sub = running ? ["Still running", line].compactMap({ $0 }).joined(separator: " \u{00B7} ") : line,
               !sub.isEmpty {
                Text(sub)
                    .font(TVType.detail.weight(.semibold))
                    .foregroundStyle(running ? TVColor.primary : TVColor.secondary)
                    .lineLimit(1)
            }
            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(TVType.detail)
                    .foregroundStyle(TVColor.secondary)
                    .lineLimit(2)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: openWidth * 0.7, alignment: .leading)
        .padding(.horizontal, 30)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .shadow(color: .black.opacity(0.5), radius: 10)
        .accessibilityHidden(true)
    }
}

/// No system focus treatment: the card draws its own.
private struct TVPlainCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(duration: 0.2, bounce: 0), value: configuration.isPressed)
    }
}
