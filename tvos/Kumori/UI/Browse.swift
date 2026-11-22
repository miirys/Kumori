import SwiftUI

// The browsing screens: Home, Library, Search and a game's detail screen (U02–U06).
// Everything here is built from the design system in UI/Design. See tvos/DESIGN-SYSTEM.md.

extension Game {
    /// Landscape art for shelves.
    var tvArt: TVArtworkSource { TVArtworkSource(banner ?? hero) }
    /// Portrait art for the library grid.
    var tvPoster: TVArtworkSource { TVArtworkSource(boxArt ?? banner) }
    /// The widest picture, for backdrops.
    var tvHero: TVArtworkSource { TVArtworkSource(hero ?? banner) }

    /// "Steam · Action · Adventure"
    var metadataLine: String {
        ([store].compactMap { $0 } + genres.prefix(2).map(Self.genreLabel)).joined(separator: " · ")
    }

    /// The catalogue sends some genres as "ROLE_PLAYING". Show them as "Role Playing".
    static func genreLabel(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "_", with: " ")
        return spaced == spaced.uppercased() ? spaced.capitalized : spaced
    }
}

// MARK: Home

struct HomeView: View {
    /// Opens a game's page, zooming out of the view marked with the given source ID.
    let open: (Game, String) -> Void
    /// Goes to Search, from the empty state.
    let browse: () -> Void

    @EnvironmentObject private var app: AppModel
    @Environment(\.tvZoomNamespace) private var zoom
    @EnvironmentObject private var player: Player
    @State private var ending: ActiveSession?
    /// Home opens on Play (or Resume), never on End Game or a tile halfway down the page.
    @FocusState private var heroFocus: HeroButton?
    @Environment(\.tvAmbient) private var ambient

    private enum HeroButton: Hashable { case play, details, end }

    var body: some View {
        TVPage {
            if hasContent {
                content
            } else if let problem = app.problem {
                TVStatusView(kind: .error, title: "Couldn\u{2019}t reach GeForce NOW",
                             message: problem) {
                    Button { Task { await app.load() } } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.loaded {
                TVStatusView(kind: .empty, title: "Nothing to play yet") {
                    Button(action: browse) { Label("Search Games", systemImage: "magnifyingglass") }
                    Button { Task { await app.load() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TVStatusView(kind: .loading, title: "Loading your games")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .endSessionConfirmation(
            isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
            title: ending.flatMap { app.game(for: $0)?.title } ?? "this game",
            onEnd: { if let s = ending { player.quit(s) } }
        )
    }

    private var hasContent: Bool { !app.recent.isEmpty || !app.shelves.isEmpty || !app.sessions.isEmpty }

    /// What the top of Home is about: a game running in the cloud first, then the game played
    /// last, then the first game the catalogue features.
    private var hero: (game: Game?, session: ActiveSession?)? {
        if let s = app.sessions.first { return (app.game(for: s), s) }
        if let g = app.recent.first { return (g, nil) }
        if let g = app.shelves.first?.games.first { return (g, nil) }
        return nil
    }

    private var content: some View {
        let top = hero
        let heroID = top?.game?.id
        let recent = app.recent.filter { $0.id != heroID }
        let running = app.sessions.dropFirst().compactMap { app.game(for: $0) }
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: TVTokens.section) {
                if let top {
                    heroSection(game: top.game, session: top.session)
                }
                if let problem = app.problem {
                    // Content is already on screen: say what went wrong without taking it away.
                    HStack(spacing: TVTokens.group) {
                        Text(problem)
                            .font(TVType.callout)
                            .foregroundStyle(TVColor.secondary)
                            .lineLimit(2)
                        Spacer(minLength: TVTokens.group)
                        Button { Task { await app.load() } } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                    }
                    .padding(.horizontal, TVTokens.group)
                    .padding(.vertical, TVTokens.medium)
                    .tvSurface(.grouped)
                    .padding(.horizontal, TVTokens.safeX)
                    .focusSection()
                }
                if !running.isEmpty {
                    shelf("Also running", running)
                }
                if !recent.isEmpty {
                    shelf("Recently played", Array(recent.prefix(12)))
                }
                ForEach(app.shelves) { s in
                    shelf(s.title.isEmpty ? "More to play" : s.title, s.games)
                }
            }
            .padding(.bottom, TVTokens.safeY)
        }
        .scrollClipDisabled()
        // The hero art runs up under the tab bar, as in Apple's own apps.
        .ignoresSafeArea(edges: .top)
    }

    /// The game at the top of Home, its art filling the screen behind it.
    private func heroSection(game: Game?, session: ActiveSession?) -> some View {
        ZStack(alignment: .bottomLeading) {
            HomeHeroArt(source: game?.tvHero ?? .missing, ambient: ambient)
                .frame(height: 800)
            TVHeroBlock(
                title: game?.title ?? "A game on another device",
                eyebrow: session != nil ? "Still running" : (app.recent.isEmpty ? "Featured" : nil),
                metadata: game?.metadataLine
            ) {
                Button {
                    if let session { player.resume(session, game: game) } else if let game { player.play(game) }
                } label: {
                    Label(session != nil ? "Resume" : "Play", systemImage: "play.fill")
                }
                .focused($heroFocus, equals: .play)
                .accessibilityIdentifier("hero-play")
                if let game {
                    Button { open(game, "hero|\(game.id)") } label: { Label("Details", systemImage: "info.circle") }
                        .focused($heroFocus, equals: .details)
                        .accessibilityIdentifier("hero-details")
                }
                if let session {
                    Button { ending = session } label: { Label("End Game", systemImage: "xmark") }
                        .focused($heroFocus, equals: .end)
                        .accessibilityIdentifier("hero-end")
                }
            }
            .padding(.horizontal, TVTokens.safeX)
            .padding(.bottom, TVTokens.medium)
            // The band with the title and buttons is one focus section across the whole
            // width, and it starts below the tab bar. Down from any tab and Up from any tile,
            // however far right, land here, and always on Play or Resume, never on End Game.
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
            .defaultFocus($heroFocus, .play, priority: .userInitiated)
        }
        .frame(height: 800, alignment: .bottomLeading)
        .onChange(of: heroFocus) { _, now in
            if now != nil, let game { ambient?.show(game.tvHero) }
        }
        .onAppear {
            if let game { ambient?.set(game.tvHero) }
        }
        // Details grows the game's page out of the whole hero.
        .tvZoomSource("hero|\(game?.id ?? "")", in: zoom)
    }

    private func shelf(_ title: String, _ games: [Game]) -> some View {
        TVExpandingShelf(title: title, items: games) { g, w in
            TVExpandingCard(id: g.id, title: g.title, line: g.metadataLine, summary: g.summary,
                            // The clean backdrop, not the banner: the card sets the title itself.
                            poster: g.tvPoster, wide: g.tvHero, width: w,
                            running: app.session(for: g) != nil, backdrop: g.tvHero) { open(g, "\(title)|\(g.id)") }
                .tvZoomSource("\(title)|\(g.id)", in: zoom)
        }
    }
}

/// The hero's art, sharp at the top of Home. While focus is on another game further down,
/// the background shows that game and this art steps back, so the two never compete; it
/// returns when the background is this game again.
private struct HomeHeroArt: View {
    let source: TVArtworkSource
    let ambient: TVAmbient?

    var body: some View {
        if let ambient {
            Tracking(source: source, ambient: ambient)
        } else {
            TVBackdrop(source: source)
        }
    }

    private struct Tracking: View {
        let source: TVArtworkSource
        @ObservedObject var ambient: TVAmbient
        @Environment(\.tvReduceMotion) private var reduced

        var body: some View {
            let mine = ambient.source == source || ambient.source == .missing
            TVBackdrop(source: source)
                .opacity(mine ? 1 : 0)
                .animation(reduced ? TVMotion.reducedFade : .easeInOut(duration: 0.9), value: mine)
        }
    }
}

// MARK: Library

struct LibraryView: View {
    /// Opens a game's page, zooming out of the view marked with the given source ID.
    let open: (Game, String) -> Void
    let browse: () -> Void
    @EnvironmentObject private var app: AppModel
    @Environment(\.tvZoomNamespace) private var zoom

    var body: some View {
        TVPage {
            if app.library.isEmpty {
                Group {
                    if app.loaded {
                        TVStatusView(kind: .empty, title: "Your library is empty",
                                     message: "Link Steam, Epic or other stores in GeForce NOW.") {
                            Button(action: browse) { Label("Search Games", systemImage: "magnifyingglass") }
                            Button { Task { await app.load() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        }
                    } else if let problem = app.problem {
                        TVStatusView(kind: .error, title: "Couldn\u{2019}t load your library", message: problem) {
                            Button { Task { await app.load() } } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                        }
                    } else {
                        TVStatusView(kind: .loading, title: "Loading your library")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: TVTokens.group) {
                        HStack(alignment: .firstTextBaseline, spacing: TVTokens.medium) {
                            Text("Library").font(TVType.section).foregroundStyle(TVColor.primary)
                                .accessibilityAddTraits(.isHeader)
                            Text("\(app.library.count) games").font(TVType.callout).foregroundStyle(TVColor.tertiary)
                        }
                        .padding(.horizontal, TVTokens.safeX)
                        TVGrid(items: sorted) { g, w in
                            TVLockup(id: g.id, title: g.title, art: g.tvPoster, shape: .poster, width: w,
                                     running: app.session(for: g) != nil, backdrop: g.tvHero) { open(g, "library|\(g.id)") }
                                .tvZoomSource("library|\(g.id)", in: zoom)
                        }
                    }
                    .padding(.top, TVTokens.group)
                    .padding(.bottom, TVTokens.safeY)
                }
                .scrollClipDisabled()
            }
        }
    }

    /// A to Z, so a game is where you expect it.
    private var sorted: [Game] {
        app.library.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

// MARK: Search

struct SearchView: View {
    /// Opens a game's page, zooming out of the view marked with the given source ID.
    let open: (Game, String) -> Void
    @EnvironmentObject private var app: AppModel
    @Environment(\.tvZoomNamespace) private var zoom
    @State private var text: String
    @State private var results: [Game] = []
    /// What the results on screen were searched for, so "no results" only shows for an
    /// answer that really came back empty.
    @State private var answered: String?
    @State private var failed = false
    /// Goes up for Try Again, so the same text is asked again.
    @State private var attempt = 0

    init(open: @escaping (Game, String) -> Void, initialText: String = "") {
        self.open = open
        _text = State(initialValue: initialText)
    }

    private var query: String { text.trimmingCharacters(in: .whitespaces) }
    private var pending: Bool { query.count >= 2 && answered != query && !failed }

    var body: some View {
        TVPage {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: TVTokens.group) {
                    if failed {
                        TVStatusView(kind: .error, title: "Couldn\u{2019}t reach GeForce NOW") {
                            Button { attempt += 1 } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                        }
                        .frame(maxWidth: .infinity)
                    } else if query.count < 2 {
                        Text("Search by title")
                            .font(TVType.body)
                            .foregroundStyle(TVColor.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, TVTokens.section)
                    } else if results.isEmpty && answered == query {
                        TVStatusView(kind: .empty, title: "No results for \u{201C}\(query)\u{201D}")
                            .frame(maxWidth: .infinity)
                    } else {
                        if !results.isEmpty {
                            TVSectionHeader(title: "Games")
                            TVGrid(items: results, shape: .landscape) { g, w in
                                TVLockup(id: g.id, title: g.title, subtitle: g.metadataLine, art: g.tvArt, width: w,
                                         backdrop: g.tvHero) { open(g, "search|\(g.id)") }
                                    .tvZoomSource("search|\(g.id)", in: zoom)
                            }
                        }
                        if pending && results.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, TVTokens.section)
                        }
                    }
                }
                .padding(.vertical, TVTokens.group)
            }
            .scrollClipDisabled()
        }
        .searchable(text: $text, prompt: "Games")
        .task(id: "\(query)#\(attempt)") {
            failed = false
            let asked = query
            guard asked.count >= 2 else {
                results = []
                answered = nil
                return
            }
            // Wait for a pause in typing before asking.
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            let found = await app.search(asked)
            // A newer keystroke cancels this request; its answer must not replace anything.
            if Task.isCancelled || asked != query { return }
            if let found {
                results = found
                answered = asked
            } else {
                failed = true
            }
        }
    }
}

// MARK: Detail

struct DetailView: View {
    let game: Game
    let close: () -> Void
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings
    @State private var confirming = false
    @FocusState private var focus: String?

    var body: some View {
        let running = app.session(for: game)
        ZStack(alignment: .bottomLeading) {
            TVColor.canvas.ignoresSafeArea()
            TVBackdrop(source: game.tvHero)
            VStack(alignment: .leading, spacing: TVTokens.group) {
                TVHeroBlock(
                    title: game.title,
                    eyebrow: running != nil ? "Still running" : nil,
                    metadata: game.metadataLine,
                    summary: game.summary
                ) {
                    Button { player.play(game) } label: {
                        Label(running != nil ? "Resume" : "Play", systemImage: "play.fill")
                    }
                    .focused($focus, equals: "play")
                    .accessibilityIdentifier("detail-play")
                    if running != nil {
                        Button { confirming = true } label: { Label("End Game", systemImage: "xmark") }
                            .focused($focus, equals: "end")
                            .accessibilityIdentifier("detail-end")
                    }
                }
                if running == nil {
                    Text("\(settings.mode.label) \u{00B7} \(settings.codec.label)")
                        .font(TVType.detail)
                        .foregroundStyle(TVColor.tertiary)
                }
            }
            // The system's 80 pt safe area already insets this screen; no second inset.
            .padding(.bottom, TVTokens.safeY)
            .tvPageEntrance(rise: 32, veil: false)
        }
        .defaultFocus($focus, "play")
        .onBack(perform: close)
        .endSessionConfirmation(
            isPresented: $confirming, title: game.title,
            onCancel: { focus = "end" },
            onEnd: {
                if let running { player.quit(running) }
                focus = "play"
            }
        )
        // `.contain` first, so the identifier names the page and doesn't replace the
        // buttons' own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-\(game.id)")
    }
}
