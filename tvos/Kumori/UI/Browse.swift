import SwiftUI

/// A landscape tile for rails, with the title underneath. Focus puts its game in the
/// background.
struct GameTile: View {
    let game: Game
    var width: CGFloat = Layout.tileWidth
    let action: () -> Void
    @FocusState private var focused: Bool
    @EnvironmentObject private var spotlight: Spotlight

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: action) {
                Art(url: game.banner ?? game.hero, title: game.title, width: 800).frame(width: width, height: width * 9 / 16)
            }
            .buttonStyle(TileButtonStyle())
            .focused($focused)
            Text(game.title)
                .font(.kumori(23, .medium))
                .foregroundStyle(focused ? Palette.text : Palette.tertiary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
                .offset(y: focused ? 12 : 0)
                .animation(Motion.focus, value: focused)
        }
        .onChange(of: focused) { _, now in if now { spotlight.focus(game) } }
    }
}

/// A portrait tile for the library grid.
struct BoxTile: View {
    let game: Game
    let action: () -> Void
    @FocusState private var focused: Bool
    @EnvironmentObject private var spotlight: Spotlight

    var body: some View {
        Button(action: action) {
            Art(url: game.boxArt ?? game.banner, title: game.title, width: 520).frame(width: 250, height: 334)
        }
        .buttonStyle(TileButtonStyle(radius: 20))
        .focused($focused)
        .onChange(of: focused) { _, now in if now { spotlight.focus(game) } }
    }
}

private struct Rail: View {
    let title: String
    let games: [Game]
    let open: (Game) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: title).padding(.leading, Layout.inset)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Layout.tileSpacing) {
                    ForEach(games) { g in GameTile(game: g) { open(g) } }
                }
                .padding(.horizontal, Layout.inset)
                .padding(.top, 30)
                .padding(.bottom, 26)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// Grey tiles in the shape of a rail, while the library loads.
private struct RailPlaceholder: View {
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Placeholder(radius: 10, index: index).frame(width: 260, height: 30).padding(.leading, Layout.inset)
            HStack(spacing: Layout.tileSpacing) {
                ForEach(0..<5) { i in
                    Placeholder(index: index * 2 + i).frame(width: Layout.tileWidth, height: Layout.tileWidth * 9 / 16)
                }
            }
            .padding(.leading, Layout.inset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

/// The top of Home: the game in the background, its name, and buttons to play it. It
/// follows focus along the rails underneath.
private struct Feature: View {
    let game: Game
    let open: (Game) -> Void
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player

    var body: some View {
        let running = app.session(for: game)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(game.title)
                    .font(.kumori(72, .bold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 1100, alignment: .leading)
                let meta = ([game.store].compactMap { $0 } + game.genres.prefix(2)).joined(separator: "  ·  ")
                if !meta.isEmpty {
                    Text(meta).font(.kumori(25, .medium)).foregroundStyle(Palette.secondary)
                }
            }
            .id(game.id)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 14)).animation(Motion.glide.delay(0.12)),
                removal: .opacity.animation(Motion.leave)
            ))
            .frame(height: 230, alignment: .bottomLeading)

            HStack(spacing: 24) {
                Button(running == nil ? "Play" : "Resume") { player.play(game) }
                    .buttonStyle(PillButtonStyle(prominent: true, icon: "play.fill"))
                Button("Details") { open(game) }
                    .buttonStyle(PillButtonStyle(icon: "info.circle"))
            }
            .padding(.top, 34)
            .focusSection()
        }
        .padding(.leading, Layout.inset)
        .frame(maxWidth: .infinity, minHeight: 560, alignment: .bottomLeading)
    }
}

struct HomeView: View {
    let open: (Game) -> Void
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var spotlight: Spotlight

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                if let g = spotlight.game ?? app.recent.first {
                    Feature(game: g, open: open).reveal(0)
                } else if app.problem == nil {
                    Color.clear.frame(height: 400)
                }
                if let problem = app.problem {
                    HStack(spacing: 24) {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 34, weight: .semibold))
                        Text(problem).font(.kumori(27)).foregroundStyle(Palette.secondary)
                        Spacer()
                        Button("Try again") { Task { await app.load() } }.buttonStyle(PillButtonStyle(icon: "arrow.clockwise"))
                    }
                    .foregroundStyle(Palette.text)
                    .padding(30)
                    .glassCard(34)
                    .padding(.horizontal, Layout.inset)
                    .padding(.top, 60)
                    .reveal(0)
                }
                if !app.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        SectionTitle(text: "Still running")
                        ForEach(app.sessions) { s in
                            HStack(spacing: 22) {
                                Circle().fill(Color.white).frame(width: 12, height: 12)
                                Text(app.game(for: s)?.title ?? "A game").font(.kumori(29, .semibold)).foregroundStyle(Palette.text)
                                Spacer()
                                Button("Resume") { player.resume(s, game: app.game(for: s)) }.buttonStyle(PillButtonStyle(prominent: true, icon: "play.fill"))
                                Button("End") { player.quit(s) }.buttonStyle(PillButtonStyle(icon: "xmark"))
                            }
                            .padding(.leading, 34).padding(.trailing, 20).padding(.vertical, 18)
                            .glassCard(34)
                        }
                    }
                    .padding(.horizontal, Layout.inset)
                    .focusSection()
                    .reveal(1)
                }
                if app.recent.count > 1 {
                    Rail(title: "Recently played", games: Array(app.recent.prefix(14)), open: open).reveal(2)
                }
                ForEach(Array(app.shelves.enumerated()), id: \.element.id) { i, shelf in
                    Rail(title: shelf.title.isEmpty ? "More to play" : shelf.title, games: shelf.games, open: open).reveal(3 + i)
                }
                if app.recent.isEmpty && app.shelves.isEmpty && app.problem == nil {
                    ForEach(0..<2) { i in RailPlaceholder(index: i) }
                }
            }
            .padding(.bottom, 90)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .animation(Motion.glide, value: app.sessions)
    }
}

struct LibraryView: View {
    let open: (Game) -> Void
    @EnvironmentObject private var app: AppModel

    private static let columns = Array(repeating: GridItem(.fixed(250), spacing: 44), count: 6)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                Text("Library").font(.kumori(54, .bold)).foregroundStyle(Palette.text).reveal(0)
                if app.library.isEmpty && app.problem != nil {
                    Text("No games in your library yet. Add them in GeForce NOW and they show up here.")
                        .font(.kumori(28)).foregroundStyle(Palette.secondary)
                } else if app.library.isEmpty {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 50) {
                        ForEach(0..<12) { i in Placeholder(radius: 20, index: i).frame(width: 250, height: 334) }
                    }
                } else {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 50) {
                        ForEach(Array(app.library.enumerated()), id: \.element.id) { i, g in
                            // Rows arrive one after another, tiles in a row together.
                            BoxTile(game: g) { open(g) }.reveal(i < 24 ? 1 + i / 6 : 0, dy: 30)
                        }
                    }
                }
            }
            .padding(.horizontal, Layout.inset)
            .padding(.top, 20)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
    }
}

struct SearchView: View {
    let open: (Game) -> Void
    @EnvironmentObject private var app: AppModel
    @State private var text = ""
    @State private var results: [Game] = []
    /// What the results on screen were searched for, so "nothing found" only shows for an
    /// answer that really came back empty.
    @State private var answered: String?
    @State private var failed = false

    private static let columns = Array(repeating: GridItem(.fixed(Layout.tileWidth), spacing: Layout.tileSpacing), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 50) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, g in GameTile(game: g) { open(g) }.reveal(i / 4) }
                }
                if failed {
                    Text("Couldn't reach GeForce NOW. Check the network and try again.")
                        .font(.kumori(27)).foregroundStyle(Palette.secondary)
                } else if results.isEmpty && text.count >= 2 && answered == text {
                    Text("Nothing found for \u{201C}\(text)\u{201D}.").font(.kumori(27)).foregroundStyle(Palette.secondary)
                }
            }
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollClipDisabled()
        .searchable(text: $text, prompt: "Search GeForce NOW")
        .task(id: text) {
            failed = false
            guard text.count >= 2 else {
                results = []
                answered = nil
                return
            }
            // Wait for a pause in typing before asking.
            let asked = text
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            let found = await app.search(asked)
            // A newer keystroke cancels this request; its answer must not replace anything.
            if Task.isCancelled { return }
            if let found {
                withAnimation(Motion.glide) { results = found }
                answered = asked
            } else {
                failed = true
            }
        }
    }
}

struct DetailView: View {
    let game: Game
    let close: () -> Void
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @State private var shown = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()
            KenBurns(url: game.hero ?? game.banner)
                .ignoresSafeArea()
                .opacity(shown ? 1 : 0)
                .scaleEffect(shown ? 1 : 1.08)
            LinearGradient(stops: [.init(color: .black.opacity(0.92), location: 0), .init(color: .black.opacity(0.45), location: 0.5), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()
            LinearGradient(colors: [.black, .black.opacity(0.4), .clear], startPoint: .bottom, endPoint: .center)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                Text(game.title)
                    .font(.kumori(80, .bold)).foregroundStyle(Palette.text)
                    .lineLimit(2).minimumScaleFactor(0.7)
                    .frame(maxWidth: 1200, alignment: .leading)
                    .reveal(0)
                let meta = ([game.store].compactMap { $0 } + game.genres.prefix(3)).joined(separator: "  ·  ")
                if !meta.isEmpty {
                    Text(meta).font(.kumori(26, .medium)).foregroundStyle(Palette.secondary).reveal(1)
                }
                if let s = game.summary {
                    Text(s).font(.kumori(27)).foregroundStyle(Palette.secondary)
                        .lineLimit(4).frame(maxWidth: 940, alignment: .leading).reveal(2)
                }
                HStack(spacing: 24) {
                    let running = app.session(for: game)
                    Button(running == nil ? "Play" : "Resume") { player.play(game) }
                        .buttonStyle(PillButtonStyle(prominent: true, icon: "play.fill"))
                    if let running {
                        Button("End session") { player.quit(running) }.buttonStyle(PillButtonStyle(icon: "xmark"))
                    }
                }
                .padding(.top, 18)
                .reveal(3)
            }
            .padding(.leading, Layout.inset)
            .padding(.bottom, 90)
            .padding(.trailing, Layout.inset)
        }
        .ignoresSafeArea(edges: .horizontal)
        .onAppear { withAnimation(.easeOut(duration: 1.2)) { shown = true } }
        .onExitCommand(perform: close)
    }
}
