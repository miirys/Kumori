#if DEBUG
import SwiftUI

// Fixture screens. Each is built only from the design system (UI/Design) and
// CatalogueFixtures, so a screenshot shows exactly what the components do. The Home and
// Detail compositions preview the direction for the U02–U06 screen tasks; the real screens
// in Browse.swift are not changed here.

// tvArt, tvPoster, tvHero and metadataLine live in UI/Browse.swift.
private extension Game {
    var running: Bool { CatalogueFixtures.runningIDs.contains(id) }
}

/// Applies the `-focus` argument (or a screen's own default) once the screen has laid out.
private struct InitialFocus: ViewModifier {
    let binding: FocusState<String?>.Binding
    let fallback: String?
    @Environment(\.fixtureFocus) private var requested

    func body(content: Content) -> some View {
        content.task {
            // Let lazy stacks mount their first items before asking for one.
            try? await Task.sleep(for: .milliseconds(250))
            binding.wrappedValue = requested ?? fallback
        }
    }
}

private extension View {
    func initialFocus(_ binding: FocusState<String?>.Binding, _ fallback: String?) -> some View {
        modifier(InitialFocus(binding: binding, fallback: fallback))
    }
}

/// The focused ID, small in the top corner, so screenshots and UI tests can read where focus is.
private struct FocusReadout: View {
    let id: String?

    var body: some View {
        Text("focus: " + (id ?? "none"))
            .font(TVType.detail).foregroundStyle(TVColor.tertiary)
            .padding(.trailing, TVTokens.safeX).padding(.top, 24)
            .allowsHitTesting(false)
            .accessibilityLabel(id ?? "none")
            .accessibilityIdentifier("focused-id")
    }
}

// MARK: Home

struct FixtureHome: View {
    enum Mode { case full, loading, error }
    let state: Mode
    @FocusState private var focus: String?
    @State private var confirming = false

    var body: some View {
        let hero = CatalogueFixtures.recent.first
        TVPage {
            ZStack(alignment: .top) {
                if state == .full, let hero {
                    TVBackdrop(source: hero.tvHero).frame(height: 900)
                }
                switch state {
                case .full: content(hero: hero)
                case .loading:
                    TVStatusView(kind: .loading, title: "Loading your games")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .error:
                    TVStatusView(kind: .error, title: "Couldn't reach GeForce NOW",
                                 message: "Check that your Apple TV is online, then try again. Your games will be here when it connects.") {
                        Button { } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                            .focused($focus, equals: "retry")
                        Button("Open Settings") { }
                            .focused($focus, equals: "settings")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .initialFocus($focus, state == .error ? "retry" : "hero-play")
        .endSessionConfirmation(isPresented: $confirming, title: hero?.title ?? "",
                                onCancel: { focus = "hero-play" }, onEnd: {})
    }

    private func content(hero: Game?) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: TVTokens.section) {
                if let hero {
                    TVHeroBlock(title: hero.title, metadata: hero.metadataLine, summary: hero.summary) {
                        Button { } label: { Label(hero.running ? "Resume" : "Play", systemImage: "play.fill") }
                            .focused($focus, equals: "hero-play")
                            .accessibilityIdentifier("hero-play")
                        Button { } label: { Label("Details", systemImage: "info.circle") }
                            .focused($focus, equals: "hero-details")
                    }
                    .padding(.horizontal, TVTokens.safeX)
                    .frame(height: TVTokens.heroHeight, alignment: .bottomLeading)
                }
                TVShelf(title: "Recently played", items: Array(CatalogueFixtures.recent.dropFirst())) { g, w in
                    TVLockup(id: g.id, title: g.title, art: g.tvArt, width: w, running: g.running) {}
                        .focused($focus, equals: g.id)
                }
                ForEach(CatalogueFixtures.shelves) { shelf in
                    TVShelf(title: shelf.title, items: shelf.games) { g, w in
                        TVLockup(id: g.id, title: g.title, art: g.tvArt, width: w, running: g.running) {}
                            .focused($focus, equals: g.id)
                    }
                }
            }
            .padding(.bottom, TVTokens.safeY)
        }
        .scrollClipDisabled()
    }
}

// MARK: Shelves, for focus tests

struct FixtureShelves: View {
    let lateArt: Bool
    @FocusState private var focus: String?

    var body: some View {
        let shelves = CatalogueFixtures.shelves
        let first = lateArt ? "fx-late-art" : shelves.first?.games.first?.id
        TVPage {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: TVTokens.section) {
                    ForEach(lateArt ? Array(shelves.reversed()) : shelves) { shelf in
                        TVShelf(title: shelf.title, items: shelf.games) { g, w in
                            TVLockup(id: g.id, title: g.title, subtitle: g.metadataLine, art: g.tvArt, width: w, running: g.running) {}
                                .focused($focus, equals: g.id)
                        }
                    }
                }
                .padding(.vertical, TVTokens.safeY)
            }
            .scrollClipDisabled()
        }
        .initialFocus($focus, first)
        .overlay(alignment: .topTrailing) { FocusReadout(id: focus) }
    }
}

// MARK: Library

struct FixtureLibrary: View {
    let empty: Bool
    @FocusState private var focus: String?

    var body: some View {
        TVPage {
            if empty {
                TVStatusView(kind: .empty, title: "Your library is empty",
                             message: "Games you own on Steam, Epic and other stores show up here once they're linked in GeForce NOW.") {
                    Button { } label: { Label("Search Games", systemImage: "magnifyingglass") }
                        .focused($focus, equals: "search")
                    Button { } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        .focused($focus, equals: "reload")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: TVTokens.group) {
                        TVSectionHeader(title: "Library")
                        TVGrid(items: CatalogueFixtures.games) { g, w in
                            TVLockup(id: g.id, title: g.title, art: g.tvPoster, shape: .poster, width: w, running: g.running) {}
                                .focused($focus, equals: g.id)
                        }
                    }
                    .padding(.vertical, TVTokens.safeY)
                }
                .scrollClipDisabled()
            }
        }
        .initialFocus($focus, empty ? "search" : CatalogueFixtures.games.first?.id)
    }
}

// MARK: Back restoration (D04)

struct FixtureRestore: View {
    @State private var memory = BrowseMemory()
    @State private var open: Game?
    @FocusState private var focus: String?
    private let games = CatalogueFixtures.games

    var body: some View {
        TVPage {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: TVTokens.group) {
                    TVSectionHeader(title: "Library")
                    TVGrid(items: games) { g, w in
                        TVLockup(id: g.id, title: g.title, art: g.tvPoster, shape: .poster, width: w) {
                            memory.remember(tab: "library", section: "grid", item: g.id, order: games.map(\.id))
                            open = g
                        }
                        .focused($focus, equals: g.id)
                    }
                }
                .padding(.vertical, TVTokens.safeY)
            }
            .scrollClipDisabled()
        }
        .initialFocus($focus, games.first?.id)
        .fullScreenCover(item: $open, onDismiss: {
            focus = memory.restoreTarget(in: "library", current: games.map(\.id))
        }) { g in
            FixtureDetail(game: g, close: { open = nil })
        }
        .overlay(alignment: .topTrailing) { FocusReadout(id: focus) }
    }
}

// MARK: Detail

struct FixtureDetail: View {
    let game: Game?
    var close: (() -> Void)?
    @FocusState private var focus: String?
    @State private var confirming = false
    @State private var ended = false

    var body: some View {
        let running = (game?.running ?? false) && !ended
        ZStack(alignment: .bottomLeading) {
            TVColor.canvas.ignoresSafeArea()
            if let game {
                TVBackdrop(source: game.tvHero)
                TVHeroBlock(title: game.title, metadata: game.metadataLine, summary: game.summary) {
                    Button { } label: { Label(running ? "Resume" : "Play", systemImage: "play.fill") }
                        .focused($focus, equals: "detail-play")
                        .accessibilityIdentifier("detail-play")
                    if running {
                        Button { confirming = true } label: { Label("End Game", systemImage: "xmark") }
                            .focused($focus, equals: "detail-end")
                            .accessibilityIdentifier("detail-end")
                    }
                }
                // The system's 80 pt safe area is the left edge here: this screen is not in
                // TVPage, so adding TVTokens.safeX would put the text at 160 pt.
                .padding(.bottom, TVTokens.safeY + 40)
            }
            // Marks which game this is for UI tests. Kept off the container, whose identifier
            // would replace the buttons' own.
            Text(game?.id ?? "none")
                .font(.system(size: 4))
                .foregroundStyle(Color.clear)
                .allowsHitTesting(false)
                .accessibilityIdentifier("detail-\(game?.id ?? "none")")
        }
        .initialFocus($focus, "detail-play")
        .onExitCommand { close?() }
        .endSessionConfirmation(
            isPresented: $confirming, title: game?.title ?? "",
            onCancel: { focus = "detail-end" },
            onEnd: {
                ended = true
                focus = "detail-play"
            }
        )
    }
}

// MARK: End session confirmation (D05)

struct FixtureConfirmEnd: View {
    @State private var confirming = false
    @State private var ended = 0
    @State private var cancelled = 0
    @FocusState private var focus: String?
    private let game = CatalogueFixtures.game(id: "fx-tidebreaker")

    var body: some View {
        TVPage {
            VStack(alignment: .leading, spacing: TVTokens.group) {
                TVSectionHeader(title: "Still running")
                HStack(spacing: TVTokens.group) {
                    TVArtwork(source: game?.tvArt ?? .missing, title: game?.title ?? "", shape: .landscape)
                        .frame(width: 260)
                        .clipShape(RoundedRectangle(cornerRadius: TVTokens.artRadius, style: .continuous))
                    VStack(alignment: .leading, spacing: TVTokens.small) {
                        Text(game?.title ?? "").font(TVType.shelf).foregroundStyle(TVColor.primary)
                        Text("Still running on GeForce NOW").font(TVType.detail).foregroundStyle(TVColor.secondary)
                    }
                    Spacer()
                    Button { } label: { Label("Resume", systemImage: "play.fill") }
                        .focused($focus, equals: "row-resume")
                    Button { confirming = true } label: { Label("End", systemImage: "xmark") }
                        .focused($focus, equals: "row-end")
                        .accessibilityIdentifier("row-end")
                }
                .padding(TVTokens.group)
                .tvSurface(.grouped)
                .padding(.horizontal, TVTokens.safeX)
                .focusSection()
                Text("Ended \(ended) · Cancelled \(cancelled)")
                    .font(TVType.detail).foregroundStyle(TVColor.tertiary)
                    .padding(.horizontal, TVTokens.safeX)
                    .accessibilityIdentifier("end-count")
            }
            .padding(.top, 200)
        }
        .initialFocus($focus, "row-end")
        .endSessionConfirmation(
            isPresented: $confirming, title: game?.title ?? "",
            onCancel: {
                cancelled += 1
                focus = "row-end"
            },
            onEnd: {
                ended += 1
                focus = "row-resume"
            }
        )
        .task {
            // Captures show the dialog itself unless a focus target was asked for.
            try? await Task.sleep(for: .milliseconds(500))
            if ProcessInfo.processInfo.arguments.contains("-openDialog") { confirming = true }
        }
    }
}

// MARK: Materials and contrast (D03)

struct FixtureMaterials: View {
    @FocusState private var focus: String?
    private let bright = CatalogueFixtures.game(id: "fx-saltmarsh")

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TVBackdrop(source: bright?.tvHero ?? .missing)
            HStack(alignment: .bottom, spacing: 60) {
                TVHeroBlock(title: bright?.title ?? "", eyebrow: "Bright artwork", metadata: bright?.metadataLine,
                            summary: "Text over the brightest fixture art, on the standard scrim.") {
                    Button { } label: { Label("Play", systemImage: "play.fill") }
                        .focused($focus, equals: "play")
                    Button("Details") { }
                        .focused($focus, equals: "details")
                }
                VStack(alignment: .leading, spacing: TVTokens.medium) {
                    Text("Overlay surface").font(TVType.shelf).foregroundStyle(TVColor.primary)
                    Text("Glass on tvOS 26 and later, frosted panel before, opaque #202020 with Reduce Transparency.")
                        .font(TVType.body).foregroundStyle(TVColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Resume") { }
                        .focused($focus, equals: "overlay-resume")
                }
                .padding(TVTokens.menuInset)
                .frame(width: 640, alignment: .leading)
                .tvSurface(.overlay)
            }
            // Not in TVPage: the system safe area already gives the 80 pt edge.
            .padding(.bottom, TVTokens.safeY + 40)
        }
        .initialFocus($focus, "play")
    }
}

// MARK: Gallery

/// One sheet with the tokens and every component state, as a visual reference.
struct FixtureGallery: View {
    @FocusState private var focus: String?
    private let games = CatalogueFixtures.games

    var body: some View {
        TVPage {
            HStack(alignment: .top, spacing: 64) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hero · Title 1").font(TVType.hero)
                    Text("Detail title · Title 2").font(TVType.title)
                    Text("Dialog · Title 3").font(TVType.section)
                    Text("Shelf heading · Headline").font(TVType.shelf)
                    Text("Callout for eyebrows").font(TVType.callout)
                    Text("Body for actions and descriptions").font(TVType.body)
                    Text("Caption for lockup titles").font(TVType.caption)
                    Text("Caption 2 for store and genre").font(TVType.detail)
                    HStack(spacing: TVTokens.medium) {
                        swatch(TVColor.canvas, "canvas")
                        swatch(TVColor.panel, "panel")
                        swatch(TVColor.placeholder, "art")
                        swatch(TVColor.secondary, "text 2")
                        swatch(TVColor.tertiary, "text 3")
                        swatch(TVColor.accent, "accent")
                    }
                    .padding(.top, TVTokens.group)
                }
                .foregroundStyle(TVColor.primary)
                .frame(width: 900, alignment: .leading)

                VStack(alignment: .leading, spacing: TVTokens.group) {
                    HStack(spacing: TVTokens.group) {
                        Button { } label: { Label("Play", systemImage: "play.fill") }
                            .focused($focus, equals: "play")
                        Button("Details") { }
                            .focused($focus, equals: "details")
                    }
                    HStack(alignment: .top, spacing: TVTokens.gutter) {
                        if let g = games.first {
                            TVLockup(id: g.id, title: g.title, subtitle: g.metadataLine, art: g.tvArt, width: 340) {}
                                .focused($focus, equals: g.id)
                        }
                        if let g = CatalogueFixtures.game(id: "fx-paper-moons") {
                            TVLockup(id: g.id, title: g.title, subtitle: "No artwork", art: g.tvArt, width: 340) {}
                                .focused($focus, equals: g.id)
                        }
                    }
                    HStack(alignment: .top, spacing: TVTokens.gutter) {
                        ForEach(["fx-tidebreaker", "fx-saltmarsh", "fx-long-title"], id: \.self) { id in
                            if let g = CatalogueFixtures.game(id: id) {
                                TVLockup(id: g.id, title: g.title, art: g.tvPoster, shape: .poster, width: 200, running: g.running) {}
                                    .focused($focus, equals: g.id)
                            }
                        }
                    }
                }
                .focusSection()
            }
            .padding(.horizontal, TVTokens.safeX)
            .padding(.vertical, TVTokens.safeY)
        }
        .initialFocus($focus, "play")
    }

    private func swatch(_ color: Color, _ name: String) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(TVColor.hairline))
                .frame(width: 96, height: 64)
            Text(name).font(TVType.detail).foregroundStyle(TVColor.secondary)
        }
    }
}
#endif
