import SwiftUI

// Pages, shelves, grids and the focusable artwork lockup (D01, D02).
//
// Focus rules this file follows (kumori/research/01-tvos-design-guide.md section A):
// - One Button is the lockup. Its label holds the art and the caption, so one thing lifts.
// - The art carries the native highlight (borderless button + `.hoverEffect(.highlight)`):
//   the system scales it, lights it and tilts it with the remote. Nothing is added on top.
// - Every lockup has a stable identifier built from the game ID, so focus and Back
//   restoration survive reloads and artwork arriving late.
// - Shelves are focus sections, aligned to the same safe edge, and never clip a lifted tile.

/// The root of a browsing page. It owns the horizontal safe area: it measures the full
/// width once and hands it down as `tvLayout`, and every shelf and grid inside insets its
/// content by exactly `TVTokens.safeX`. Nothing inside adds the safe inset again.
struct TVPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            content()
                .environment(\.tvLayout, TVLayout(width: geo.size.width))
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea(edges: .horizontal)
    }
}

/// A focusable piece of game artwork with its title underneath.
struct TVLockup: View {
    let id: String
    let title: String
    var subtitle: String?
    let art: TVArtworkSource
    var shape: TVLockupShape = .landscape
    let width: CGFloat
    /// Marks a game that is running in the cloud right now.
    var running = false
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: TVTokens.small) {
                TVArtwork(source: art, title: title, shape: shape)
                    .frame(width: width)
                    .overlay(alignment: .topLeading) {
                        if running { TVRunningBadge().padding(TVTokens.medium) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: TVTokens.artRadius, style: .continuous))
                    .hoverEffect(.highlight)
                TVLockupCaption(title: title, subtitle: subtitle, lines: captionLines,
                                lift: width / shape.aspect * TVTokens.focusLift)
                    .frame(width: width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("lockup-\(id)")
        .accessibilityLabel([title, subtitle, running ? "Running" : nil].compactMap { $0 }.joined(separator: ", "))
    }

    private var captionLines: Int {
        if typeSize.isAccessibilitySize { return 4 }
        return shape == .poster ? 2 : 1
    }
}

/// The title under a lockup. When the art lifts under focus, the caption steps down by the
/// same amount so the enlarged picture never covers it, as the system's own lockups do.
private struct TVLockupCaption: View {
    let title: String
    let subtitle: String?
    let lines: Int
    let lift: CGFloat

    @Environment(\.isFocused) private var focused
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.tvReduceMotion) private var reduced

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(TVType.caption.weight(.medium))
                .foregroundStyle(TVColor.primary)
                .lineLimit(lines)
            if let subtitle {
                Text(subtitle)
                    .font(TVType.detail)
                    .foregroundStyle(TVColor.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            }
        }
        .offset(y: focused ? lift : 0)
        .animation(reduced ? nil : .smooth(duration: 0.2), value: focused)
    }
}

/// "Running" on artwork: an opaque chip so it reads on bright and dark art alike.
struct TVRunningBadge: View {
    var body: some View {
        HStack(spacing: TVTokens.small) {
            Circle().fill(TVColor.accent).frame(width: 12, height: 12)
            Text("Running").font(TVType.detail.weight(.semibold)).foregroundStyle(TVColor.primary)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.black.opacity(0.72), in: Capsule())
        .accessibilityHidden(true)
    }
}

/// A shelf heading, aligned to the safe edge.
struct TVSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(TVType.shelf)
            .foregroundStyle(TVColor.primary)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, TVTokens.safeX)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A titled horizontal row of lockups. Four landscape tiles fill the safe width at default
/// text size; fewer, wider ones at larger sizes. Scrolls edge to edge, aligned to the safe edge.
struct TVShelf<Item: Identifiable, Cell: View>: View {
    let title: String
    let items: [Item]
    var shape: TVLockupShape = .landscape
    /// Builds one tile for an item at the width the shelf works out.
    @ViewBuilder let cell: (Item, CGFloat) -> Cell

    @Environment(\.tvLayout) private var layout
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let width = layout.tileWidth(shape, at: typeSize)
        VStack(alignment: .leading, spacing: 0) {
            TVSectionHeader(title: title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: TVTokens.gutter) {
                    ForEach(items) { item in cell(item, width) }
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

/// A vertical grid of lockups: six posters across at default text size, down to three at
/// the largest. Put it inside the page's vertical ScrollView.
struct TVGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    var shape: TVLockupShape = .poster
    @ViewBuilder let cell: (Item, CGFloat) -> Cell

    @Environment(\.tvLayout) private var layout
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let count = TVTokens.columns(shape, at: typeSize)
        let width = layout.tileWidth(shape, at: typeSize)
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(width), spacing: TVTokens.gutter, alignment: .top), count: count),
            alignment: .leading,
            spacing: TVTokens.gridRowGap - TVTokens.captionAllowance
        ) {
            ForEach(items) { item in cell(item, width) }
        }
        .padding(.horizontal, TVTokens.safeX)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }
}

/// The text and actions of a hero: one game, its title, a line of metadata and the actions
/// that launch *that* game. It sits inside the safe edge at a fixed position, so the buttons
/// never move while artwork loads or the backdrop changes.
struct TVHeroBlock<Actions: View>: View {
    let title: String
    var eyebrow: String?
    var metadata: String?
    var summary: String?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: TVTokens.medium) {
            if let eyebrow {
                Text(eyebrow).font(TVType.callout.weight(.semibold)).foregroundStyle(TVColor.secondary)
            }
            Text(title)
                .font(TVType.hero)
                .foregroundStyle(TVColor.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .accessibilityAddTraits(.isHeader)
            if let metadata {
                Text(metadata).font(TVType.detail.weight(.medium)).foregroundStyle(TVColor.secondary)
            }
            if let summary {
                Text(summary).font(TVType.body).foregroundStyle(TVColor.secondary).lineLimit(3)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: TVTokens.group) { actions() }
                VStack(alignment: .leading, spacing: TVTokens.medium) { actions() }
            }
            .padding(.top, TVTokens.small)
            .focusSection()
        }
        .frame(maxWidth: TVTokens.heroTextWidth, alignment: .leading)
    }
}
