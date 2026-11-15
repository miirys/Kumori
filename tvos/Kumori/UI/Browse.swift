import SwiftUI

/// A landscape tile for rails.
struct GameTile: View {
    let game: Game
    var width: CGFloat = 400
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Art(url: game.banner ?? game.hero, title: game.title).frame(width: width, height: width * 9 / 16)
        }
        .buttonStyle(CardButtonStyle())
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
        .buttonStyle(CardButtonStyle())
    }
}

private struct Rail: View {
    let title: String
    let games: [Game]
    let open: (Game) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.kumori(31, .semibold)).foregroundStyle(Palette.blush).padding(.leading, 80)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 34) {
                    ForEach(games) { g in GameTile(game: g) { open(g) } }
                }
                .padding(.horizontal, 80).padding(.vertical, 30)
            }
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
            LazyVStack(alignment: .leading, spacing: 26) {
                if let problem = app.problem {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(problem).font(.kumori(27)).foregroundStyle(Palette.secondary)
                        Button("Try again") { Task { await app.load() } }.buttonStyle(PillButtonStyle())
                    }
                    .padding(.horizontal, 80)
                }
                if !app.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Still running").font(.kumori(31, .semibold)).foregroundStyle(Palette.blush)
                        ForEach(app.sessions) { s in
                            HStack(spacing: 20) {
                                Text(app.game(for: s)?.title ?? "A game").font(.kumori(29, .medium)).foregroundStyle(Palette.blush)
                                Spacer()
                                Button("Resume") { player.resume(s, game: app.game(for: s)) }.buttonStyle(PillButtonStyle(prominent: true))
                                Button("End") { player.quit(s) }.buttonStyle(PillButtonStyle())
                            }
                            .padding(26)
                            .background(Palette.glass, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 80).reveal(0)
                }
                if !app.recent.isEmpty {
                    Rail(title: "Jump back in", games: Array(app.recent.prefix(12)), open: open).reveal(1)
                }
                ForEach(Array(app.shelves.enumerated()), id: \.element.id) { i, shelf in
                    Rail(title: shelf.title.isEmpty ? "More to play" : shelf.title, games: shelf.games, open: open).reveal(2 + i)
                }
                if app.recent.isEmpty && app.shelves.isEmpty && app.problem == nil {
                    Text("Your games will show up here.").font(.kumori(29)).foregroundStyle(Palette.secondary).padding(80)
                }
            }
            .padding(.vertical, 40)
        }
    }
}

struct LibraryView: View {
    let open: (Game) -> Void
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView {
            if app.library.isEmpty {
                Text("No games in your library yet. Add them in GeForce NOW and they appear here.")
                    .font(.kumori(29)).foregroundStyle(Palette.secondary).padding(80)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(250), spacing: 40), count: 6), spacing: 50) {
                ForEach(Array(app.library.enumerated()), id: \.element.id) { i, g in
                    // Rows arrive one after another, tiles in a row together.
                    BoxTile(game: g) { open(g) }.reveal(i / 6)
                }
            }
            .padding(.horizontal, 80).padding(.vertical, 50)
        }
    }
}

struct SearchView: View {
    let open: (Game) -> Void
    @EnvironmentObject private var app: AppModel
    @State private var text = ""
    @State private var results: [Game] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(400), spacing: 40), count: 4), spacing: 50) {
                ForEach(results) { g in GameTile(game: g) { open(g) } }
            }
            .padding(.horizontal, 80).padding(.vertical, 50)
            if results.isEmpty && text.count >= 2 {
                Text("Nothing found for \u{201C}\(text)\u{201D}.").font(.kumori(27)).foregroundStyle(Palette.secondary)
            }
        }
        .searchable(text: $text, prompt: "Search GeForce NOW")
        .task(id: text) {
            guard text.count >= 2 else {
                results = []
                return
            }
            // Wait for a pause in typing before asking.
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { results = await app.search(text) }
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
            Art(url: game.hero ?? game.banner, title: "").ignoresSafeArea()
            LinearGradient(colors: [Palette.night.opacity(0.96), Palette.night.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing).ignoresSafeArea()
            LinearGradient(colors: [Palette.night, .clear], startPoint: .bottom, endPoint: .center).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text(game.title).font(.kumori(66, .bold)).foregroundStyle(Palette.blush).lineLimit(2).reveal(0)
                Text(([game.store] + game.genres.prefix(3).map(Optional.some)).compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.kumori(25, .medium)).foregroundStyle(Palette.secondary).reveal(1)
                if let s = game.summary {
                    Text(s).font(.kumori(27)).foregroundStyle(Palette.secondary).lineLimit(4).frame(maxWidth: 900, alignment: .leading).reveal(2)
                }
                HStack(spacing: 22) {
                    let running = app.session(for: game)
                    Button(running == nil ? "Play" : "Resume") { player.play(game) }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    if let running {
                        Button("End session") { player.quit(running) }.buttonStyle(PillButtonStyle())
                    }
                }
                .padding(.top, 12).reveal(3)
                Text("Starts at \(settings.mode.label)").font(.kumori(22)).foregroundStyle(Palette.tertiary).reveal(4)
            }
            .padding(90)
        }
        .onExitCommand(perform: close)
    }
}
