import SwiftUI

// The Home shelves' card, as on Kumori for Android: a poster at rest that, under focus,
// opens sideways into a wide banner with the game's title, its store and genre, and a few
// lines about it. Its neighbours make room as it opens, so the row moves as one.

/// Which column focus was last in, as the left edge of the card that had it, shared by the
/// rows of one page. Up and Down land on the card in the next row nearest that edge, so focus
/// moves straight up and down instead of drifting toward the middle of an opened card.
@Observable final class TVShelfColumn {
    var x: CGFloat?
}

private struct TVShelfColumnKey: EnvironmentKey {
    static let defaultValue: TVShelfColumn? = nil
}

extension EnvironmentValues {
    var tvShelfColumn: TVShelfColumn? {
        get { self[TVShelfColumnKey.self] }
        set { self[TVShelfColumnKey.self] = newValue }
    }
}

/// Where each card in a row sits, written as they lay out; nothing redraws when it changes.
private final class TVShelfLefts {
    var x: [String: CGFloat] = [:]
}

/// A row of expanding cards, aligned to the safe edge, with an optional title.
struct TVExpandingShelf<Item: Identifiable, Card: View>: View {
    let title: String?
    let items: [Item]
    /// Builds one card for an item at the poster width the shelf works out. Pass the row's
    /// focus on to the card as its `rowFocus`.
    @ViewBuilder let card: (Item, CGFloat, FocusState<String?>.Binding) -> Card

    @Environment(\.tvLayout) private var layout
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.tvShelfColumn) private var column
    @FocusState private var focused: String?
    @State private var lefts = TVShelfLefts()

    var body: some View {
        let width = TVExpandingCard.posterWidth(in: layout, at: typeSize)
        VStack(alignment: .leading, spacing: 0) {
            if let title { TVSectionHeader(title: title) }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: TVExpandingCard.gap) {
                    ForEach(items) { item in
                        let key = "\(item.id)"
                        card(item, width, $focused)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { x in
                                lefts.x[key] = x
                            }
                    }
                }
                .padding(.horizontal, TVTokens.safeX)
                .padding(.top, title == nil ? TVTokens.medium : TVTokens.group)
                .padding(.bottom, TVTokens.focusClearance)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .defaultFocus($focused, landing, priority: .userInitiated)
        .onChange(of: focused) { _, now in
            if let now, let x = lefts.x[now] { column?.x = x }
        }
    }

    /// The card nearest the column focus came from; the first card when there is none.
    private var landing: String? {
        let first = items.first.map { "\($0.id)" }
        guard let x = column?.x else { return first }
        return items.map { "\($0.id)" }.min { abs((lefts.x[$0] ?? .infinity) - x) < abs((lefts.x[$1] ?? .infinity) - x) } ?? first
    }
}

struct TVExpandingCard: View {
    let id: String
    let title: String
    /// Store and genre: "Steam, Action".
    var line: String?
    var summary: String?
    let poster: TVArtworkSource
    let wide: TVArtworkSource
    /// The poster width; the card is this wide at rest.
    let width: CGFloat
    var running = false
    /// What the page background shows while this has focus.
    var backdrop: TVArtworkSource?
    /// The row's focus, so the row can say which card Up or Down lands on.
    var rowFocus: FocusState<String?>.Binding?
    let action: () -> Void

    @Environment(\.tvAmbient) private var ambient
    @Environment(\.tvReduceMotion) private var reduced
    @Environment(\.tvZoomIsHeld) private var held
    @FocusState private var focused: Bool
    @State private var open = false
    /// This card on screen, for Link's select: a game can be on two shelves at once.
    @State private var token = UUID().uuidString

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
            // Every layer follows one animated value, the card's openness, so opening and
            // closing are exact reverses of each other at any speed, and turning back halfway
            // just runs the same frames backwards. Nothing has a timing or delay of its own,
            // so no layer can snap ahead of the frame or lag behind it.
            CardMorph(progress: open ? 1 : 0, width: width, openWidth: openWidth, height: height,
                      reduced: reduced, wide: wide, poster: poster, title: title,
                      shade: shade, info: info)
        }
        .buttonStyle(TVPlainCardStyle())
        .focused($focused)
        .modifier(RowFocus(binding: rowFocus, id: id))
        .onChange(of: focused) { _, now in
            if now { ambient?.show(backdrop ?? wide) }
            // A from a Kumori Link controller opens exactly this card.
            if now { LinkNavigator.shared.cardFocused(token, action) } else { LinkNavigator.shared.cardUnfocused(token) }
        }
        .onDisappear { LinkNavigator.shared.cardUnfocused(token) }
        // A card rebuilt while its game's page is open over it (a lazy row recreating it)
        // starts open, so the page still shrinks back into an open card.
        .onAppear { if (focused || held) && !open { open = true } }
        // Open while focused, and while this card's game page is open over it, so the page
        // shrinks back into the same open card it grew out of.
        .onChange(of: focused || held) { _, now in
            // In one transaction, so the cards beside this one move with it.
            withAnimation(reduced ? TVMotion.reducedFade : TVMotion.cardOpen) {
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
            if let sub = running ? "Still running" : line,
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

/// The card's look at one point between poster (0) and open banner (1).
private struct CardMorph<Shade: View, Info: View>: View, Animatable {
    var progress: CGFloat
    let width: CGFloat
    let openWidth: CGFloat
    let height: CGFloat
    let reduced: Bool
    let wide: TVArtworkSource
    let poster: TVArtworkSource
    let title: String
    let shade: Shade
    let info: Info

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = min(1, max(0, progress))
        let w = width + (openWidth - width) * progress
        let shape = RoundedRectangle(cornerRadius: TVTokens.artRadius, style: .continuous)
        // Both pictures fill the card's current shape at every frame, so the picture grows
        // and narrows with the frame instead of snapping to its new size. The wide picture is
        // solid underneath the whole time the card isn't at rest, and the poster dissolves
        // into it over the middle of the morph (and back out of it, closing), so the card is
        // never see-through and never without a picture.
        let t = min(1, max(0, (p - 0.12) / 0.5))
        let posterOpacity = 1 - t * t * (3 - 2 * t)
        // The words arrive over the last part, out of a soft blur, and leave first.
        let words = min(1, max(0, (p - 0.55) / 0.45))
        // Every layer stays in the tree (hidden ones at zero opacity, which the renderer
        // skips), so no picture is ever reloaded mid-morph and flashes.
        ZStack(alignment: .leading) {
            TVArtwork(source: wide, title: "", titleOnPlaceholder: false, fill: true, placeholder: false)
                .frame(width: max(1, w), height: height)
                .clipped()
                .opacity(p > 0.001 ? 1 : 0)
            TVArtwork(source: poster, title: title, shape: .poster, fill: true)
                .frame(width: max(1, w), height: height)
                .clipped()
                .opacity(posterOpacity)
            shade
                .frame(width: max(0, w), height: height)
                .opacity(p)
            info
                .frame(width: openWidth, height: height, alignment: .bottomLeading)
                .frame(width: max(0, w), height: height, alignment: .bottomLeading)
                .clipped()
                .blur(radius: reduced || words > 0.99 ? 0 : 10 * (1 - words))
                .opacity(words)
        }
        .frame(width: max(0, w), height: height, alignment: .leading)
        .clipShape(shape)
        // Lifted by its shadow and a touch of scale, with no outline or sheen. The shadow is
        // cast by a plain shape underneath, never by the pictures.
        .background {
            shape.fill(Color.black)
                .shadow(color: .black.opacity(0.55 * p), radius: 30, y: 18)
                .opacity(p > 0.001 ? 1 : 0)
        }
        .scaleEffect(reduced ? 1 : 1 + 0.04 * progress, anchor: .leading)
    }
}

/// Ties a card to its row's focus, when it has a row.
private struct RowFocus: ViewModifier {
    let binding: FocusState<String?>.Binding?
    let id: String

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding, equals: id)
        } else {
            content
        }
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
