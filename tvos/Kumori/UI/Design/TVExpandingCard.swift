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
            ZStack(alignment: .leading) {
                // One shape. Every layer takes the card's own animated frame and its one
                // spring (no layer has a size or timing of its own), so mid-morph there is
                // never a poster-shaped or banner-shaped edge showing through, however fast
                // focus moves along the row.
                // The wide picture is laid out at its full width and uncovered from the left
                // as the card opens, so it never stretches.
                // It is never half see-through: it is there at once when the card opens and
                // stays solid until the poster has covered it again, so two pictures are
                // never blended into a ghost of each other.
                TVArtwork(source: wide, title: "", titleOnPlaceholder: false, fill: true, placeholder: false)
                    .frame(width: openWidth, height: height)
                    .opacity(open ? 1 : 0)
                    .animation(open || reduced ? nil : .linear(duration: 0).delay(0.2), value: open)
                // The poster keeps its own size, sits over the solid picture and steps
                // aside quickly; it never stretches or lingers as an afterimage.
                TVArtwork(source: poster, title: title, shape: .poster, fill: true)
                    .frame(width: width, height: height)
                    .opacity(open ? 0 : 1)
                    .animation(reduced ? TVMotion.reducedFade : .easeOut(duration: open ? 0.1 : 0.16), value: open)
                shade
                    .frame(width: open ? openWidth : width, height: height)
                    .opacity(open ? 1 : 0)
                // The words come in once the card is most of the way open, out of a soft
                // blur, and go at once when it starts to close, so they are never cut off
                // by a narrowing card.
                info
                    .frame(width: openWidth, height: height, alignment: .bottomLeading)
                    .frame(width: open ? openWidth : width, height: height, alignment: .bottomLeading)
                    .clipped()
                    .opacity(open ? 1 : 0)
                    .blur(radius: open || reduced ? 0 : 10)
                    .animation(reduced ? TVMotion.reducedFade
                               : (open ? .easeOut(duration: 0.34).delay(0.22) : .easeOut(duration: 0.08)),
                               value: open)
            }
            .frame(width: open ? openWidth : width, height: height, alignment: .leading)
            .clipShape(shape)
            // Lifted by its shadow and a touch of scale, with no outline or sheen. The shadow
            // is cast by a plain shape underneath, not by the pictures: a shadow of the
            // artwork itself is redrawn off screen every frame of the morph and stuttered
            // when focus ran fast along a row.
            .background {
                shape.fill(Color.black)
                    .shadow(color: .black.opacity(0.55), radius: 30, y: 18)
                    .opacity(open ? 1 : 0)
            }
            .scaleEffect(open && !reduced ? 1.04 : 1, anchor: .leading)
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
        // Open while focused, and while this card's game page is open over it, so the page
        // shrinks back into the same open card it grew out of.
        .onChange(of: focused || held) { _, now in
            // In one transaction, so the cards beside this one move with it.
            withAnimation(reduced ? TVMotion.reducedFade : (now ? TVMotion.cardOpen : TVMotion.cardClose)) {
                open = now
            }
        }
        .accessibilityIdentifier("lockup-\(id)")
        .accessibilityLabel([title, line, running ? "Running" : nil].compactMap { $0 }.joined(separator: ", "))
    }

    private func fade(_ duration: Double, delay: Double) -> Animation {
        reduced ? TVMotion.reducedFade : .easeInOut(duration: duration).delay(delay)
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
