import SwiftUI

/// A landscape tile for rails. The title slides in underneath when it has focus.
struct GameTile: View {
    let game: Game
    var width: CGFloat = 400
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: action) {
                Art(url: game.banner ?? game.hero, title: game.title).frame(width: width, height: width * 9 / 16)
            }
            .buttonStyle(CardButtonStyle())
            .focused($focused)
            Text(game.title)
                .font(.kumori(23, .semibold)).foregroundStyle(Palette.blush).lineLimit(1)
                .frame(width: width, alignment: .leading)
                .opacity(focused ? 1 : 0)
                .offset(y: focused ? 10 : -6)
                .animation(Motion.focus, value: focused)
        }
    }
}

/// A portrait tile for the library grid.
struct BoxTile: View {
    let game: Game
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Art(url: game.boxArt ?? game.banner, title: game.title).frame(width: 250, height: 334)
        }
        .buttonStyle(CardButtonStyle(radius: 24))
    }
}

private struct Rail: View {
    let title: String
    let games: [Game]
    let open: (Game) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.kumori(32, .bold)).foregroundStyle(Palette.blush).padding(.leading, 80)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 40) {
                    ForEach(games) { g in GameTile(game: g) { open(g) } }
                }
                .padding(.horizontal, 80).padding(.top, 34).padding(.bottom, 20)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// The big picture at the top of Home: the game played last, ready to go again.
private struct Hero: View {
    let game: Game
    let open: (Game) -> Void
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            KenBurns(url: game.hero ?? game.banner)
                .frame(maxWidth: .infinity)
                .frame(height: 620)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .mask(LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .black, location: 0.5)], startPoint: .leading, endPoint: .trailing))
            VStack(alignment: .leading, spacing: 18) {
                Text("JUMP BACK IN").font(.kumori(20, .bold)).kerning(2).foregroundStyle(Palette.pink)
                Text(game.title).font(.kumori(64, .bold)).foregroundStyle(Palette.blush).lineLimit(2).frame(maxWidth: 1000, alignment: .leading)
                if let s = game.store {
                    Text(([s] + game.genres.prefix(2)).joined(separator: "  ·  ")).font(.kumori(24, .medium)).foregroundStyle(Palette.secondary)
                }
                HStack(spacing: 22) {
                    let running = app.session(for: game)
                    Button(running == nil ? "Play" : "Resume") { player.play(game) }
                        .buttonStyle(PillButtonStyle(prominent: true, icon: "play.fill"))
                    Button("Details") { open(game) }
                        .buttonStyle(PillButtonStyle(icon: "info.circle"))
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 80).padding(.bottom, 30)
        }
        .focusSection()
    }
}

struct HomeView: View {
    let open: (Game) -> Void
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                if let problem = app.problem {
                    HStack(spacing: 24) {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 36, weight: .semibold)).foregroundStyle(Palette.pink)
                        Text(problem).font(.kumori(27)).foregroundStyle(Palette.secondary)
                        Spacer()
                        Button("Try again") { Task { await app.load() } }.buttonStyle(PillButtonStyle(icon: "arrow.clockwise"))
                    }
                    .padding(30)
                    .glassCard(36)
                    .padding(.horizontal, 80)
                    .reveal(0)
                }
                if let first = app.recent.first {
                    Hero(game: first, open: open).reveal(0, dy: 0)
                }
                if !app.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Still running").font(.kumori(32, .bold)).foregroundStyle(Palette.blush)
                        ForEach(app.sessions) { s in
                            HStack(spacing: 22) {
                                Circle().fill(Palette.pink).frame(width: 14, height: 14).shadow(color: Palette.pink, radius: 8)
                                Text(app.game(for: s)?.title ?? "A game").font(.kumori(29, .semibold)).foregroundStyle(Palette.blush)
                                Spacer()
                                Button("Resume") { player.resume(s, game: app.game(for: s)) }.buttonStyle(PillButtonStyle(prominent: true, icon: "play.fill"))
                                Button("End") { player.quit(s) }.buttonStyle(PillButtonStyle(icon: "xmark"))
                            }
                            .padding(.horizontal, 30).padding(.vertical, 22)
                            .glassCard(34)
                        }
                    }
                    .padding(.horizontal, 80).reveal(1)
                    .focusSection()
                }
                if app.recent.count > 1 {
                    Rail(title: "Recently played", games: Array(app.recent.dropFirst().prefix(12)), open: open).reveal(2)
                }
                ForEach(Array(app.shelves.enumerated()), id: \.element.id) { i, shelf in
                    Rail(title: shelf.title.isEmpty ? "More to play" : shelf.title, games: shelf.games, open: open).reveal(3 + i)
                }
                if app.recent.isEmpty && app.shelves.isEmpty && app.problem == nil {
                    VStack(spacing: 18) {
                        Spinner(size: 60)
                        Text("Your games will show up here.").font(.kumori(29)).foregroundStyle(Palette.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(120)
                }
            }
            .padding(.bottom, 60)
        }
        .scrollClipDisabled()
        .animation(Motion.glide, value: app.sessions)
    }
}

struct LibraryView: View {
    let open: (Game) -> Void
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView {
            if app.library.isEmpty {
                VStack(spacing: 18) {
                    Image(systemName: "square.stack.3d.up.slash").font(.system(size: 60, weight: .semibold)).foregroundStyle(Palette.tertiary)
                    Text("No games in your library yet. Add them in GeForce NOW and they appear here.")
                        .font(.kumori(29)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(100)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(250), spacing: 40), count: 6), spacing: 50) {
                ForEach(Array(app.library.enumerated()), id: \.element.id) { i, g in
                    // Rows arrive one after another, tiles in a row together.
                    BoxTile(game: g) { open(g) }.reveal(i / 6)
                }
            }
            .padding(.horizontal, 80).padding(.vertical, 50)
        }
        .scrollClipDisabled()
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

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(400), spacing: 40), count: 4), spacing: 40) {
                ForEach(Array(results.enumerated()), id: \.element.id) { i, g in GameTile(game: g) { open(g) }.reveal(i / 4) }
            }
            .padding(.horizontal, 80).padding(.vertical, 50)
            if failed {
                Text("The search couldn't reach GeForce NOW. Check the network and try again.")
                    .font(.kumori(27)).foregroundStyle(Palette.secondary)
            } else if results.isEmpty && text.count >= 2 && answered == text {
                Text("Nothing found for \u{201C}\(text)\u{201D}.").font(.kumori(27)).foregroundStyle(Palette.secondary)
            }
        }
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
                results = found
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
    @EnvironmentObject private var settings: Settings

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Aurora(paused: player.active)
            KenBurns(url: game.hero ?? game.banner).ignoresSafeArea()
            LinearGradient(colors: [Palette.deep.opacity(0.92), Palette.deep.opacity(0.4), .clear], startPoint: .leading, endPoint: .trailing).ignoresSafeArea()
            LinearGradient(colors: [Palette.deep, .clear], startPoint: .bottom, endPoint: .center).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                Text(game.title).font(.kumori(70, .bold)).foregroundStyle(Palette.blush).lineLimit(2).reveal(0)
                HStack(spacing: 12) {
                    ForEach(([game.store] + game.genres.prefix(3).map(Optional.some)).compactMap { $0 }, id: \.self) { tag in
                        Text(tag).font(.kumori(22, .semibold)).foregroundStyle(Palette.blush)
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .glass(Capsule())
                    }
                }
                .reveal(1)
                if let s = game.summary {
                    Text(s).font(.kumori(27)).foregroundStyle(Palette.secondary).lineLimit(4).frame(maxWidth: 900, alignment: .leading).reveal(2)
                }
                HStack(spacing: 22) {
                    let running = app.session(for: game)
                    Button(running == nil ? "Play" : "Resume") { player.play(game) }
                        .buttonStyle(PillButtonStyle(prominent: true, icon: "play.fill"))
                    if let running {
                        Button("End session") { player.quit(running) }.buttonStyle(PillButtonStyle(icon: "xmark"))
                    }
                }
                .padding(.top, 12).reveal(3)
                HStack(spacing: 10) {
                    Image(systemName: "sparkles.tv")
                    Text("Starts at \(settings.mode.label) · \(settings.codec.label)")
                }
                .font(.kumori(22)).foregroundStyle(Palette.tertiary).reveal(4)
            }
            .padding(90)
        }
        .onExitCommand(perform: close)
    }
}
