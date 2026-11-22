#if DEBUG
import SwiftUI

/// The debug-only fixture harness (T01).
///
/// Launch a Debug build with `-fixture <name>` and the app shows one synthetic screen built
/// from the design system and `CatalogueFixtures`, instead of signing in. No network, no
/// account. Release builds compile none of this, so the arguments do nothing there.
///
/// Other arguments:
///   -focus <id>               put focus on this item first (a game ID or a button ID)
///   -typeSize <size>          default | large | xxxl | ax1 … ax5
///   -reduceMotion 1           behave as if Reduce Motion is on
///   -reduceTransparency 1     behave as if Reduce Transparency is on
///   -safeFrame 1              draw the 80/60 pt safe region on top
///   -linkScript a,b,…         once settled, feed these Kumori Link presses (up, down, left,
///                             right, a, b) to LinkNavigator, one a second, then show
///                             `link-done` and the navigator's trace in `link-trace`
///   -linkDelay <seconds>      wait this long after settling before the script (default 1)
///
/// When the screen has settled it shows an invisible accessibility element called
/// `ready-<name>`; UI tests wait for it before taking a screenshot.
struct FixtureConfig: Equatable {
    var name: String
    var focus: String?
    var typeSize: DynamicTypeSize = .large
    var reduceMotion = false
    var reduceTransparency = false
    var safeFrame = false
    var linkScript: [String] = []
    var linkDelay = 1.0

    /// The fixture the process was launched with, or nil for a normal launch.
    static let launched: FixtureConfig? = parse(ProcessInfo.processInfo.arguments)

    static func parse(_ args: [String]) -> FixtureConfig? {
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: "-" + key), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        guard let name = value("fixture") else { return nil }
        var c = FixtureConfig(name: name)
        c.focus = value("focus")
        c.typeSize = typeSize(value("typeSize")) ?? .large
        c.reduceMotion = value("reduceMotion") == "1"
        c.reduceTransparency = value("reduceTransparency") == "1"
        c.safeFrame = value("safeFrame") == "1"
        c.linkScript = value("linkScript")?.split(separator: ",").map(String.init) ?? []
        c.linkDelay = value("linkDelay").flatMap(Double.init) ?? 1
        return c
    }

    static func typeSize(_ s: String?) -> DynamicTypeSize? {
        switch s {
        case "default", "large": return .large
        case "xl": return .xLarge
        case "xxl": return .xxLarge
        case "xxxl": return .xxxLarge
        case "ax1": return .accessibility1
        case "ax2": return .accessibility2
        case "ax3": return .accessibility3
        case "ax4": return .accessibility4
        case "ax5": return .accessibility5
        default: return nil
        }
    }

    /// How long a fixture needs before it is ready to photograph.
    var settle: Duration {
        if name == "art-load" { return .milliseconds(2600) }
        // The real screens go through TabView, NavigationStack and lists before they settle.
        return name.hasPrefix("app-") ? .milliseconds(2000) : .milliseconds(1200)
    }
}

/// Every fixture the harness knows. UI tests and scripts/capture-fixtures.sh use these names.
enum FixtureName {
    static let all = [
        "gallery", "home", "home-loading", "home-error", "shelves", "art-load",
        "library", "library-empty", "restore", "detail", "detail-long", "detail-running",
        "confirm-end", "materials",
    ] + AppScreenNames.all
}

struct FixtureRoot: View {
    let config: FixtureConfig
    @State private var ready = false
    @State private var linkDone = false
    @ObservedObject private var link = LinkNavigator.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            TVColor.canvas.ignoresSafeArea()
            screen
            if config.safeFrame { SafeFrameOverlay() }
            if ready {
                // Invisible, unfocusable, but present in the accessibility tree.
                Text("ready")
                    .font(.system(size: 4))
                    .foregroundStyle(Color.clear)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("ready-" + config.name)
            }
            if !config.linkScript.isEmpty {
                Text(link.trace.joined(separator: " | "))
                    .font(.system(size: 4))
                    .foregroundStyle(Color.clear)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("link-trace")
                if linkDone {
                    Text("done")
                        .font(.system(size: 4))
                        .foregroundStyle(Color.clear)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("link-done")
                }
            }
        }
        .environment(\.fixtureFocus, config.focus)
        .dynamicTypeSize(config.typeSize)
        .tvAccessibilityBridge(
            reduceMotion: config.reduceMotion ? true : nil,
            reduceTransparency: config.reduceTransparency ? true : nil
        )
        .preferredColorScheme(.dark)
        .task {
            try? await Task.sleep(for: config.settle)
            ready = true
            guard !config.linkScript.isEmpty else { return }
            try? await Task.sleep(for: .seconds(config.linkDelay))
            for step in config.linkScript {
                var r = PadReport()
                switch step {
                case "up": r.buttons = InputEncoder.up
                case "down": r.buttons = InputEncoder.down
                case "left": r.buttons = InputEncoder.left
                case "right": r.buttons = InputEncoder.right
                case "a": r.buttons = InputEncoder.a
                case "b": r.buttons = InputEncoder.b
                case "stick-right": r.lx = 30000
                default: break
                }
                LinkNavigator.shared.handle(r)
                try? await Task.sleep(for: .milliseconds(120))
                LinkNavigator.shared.handle(.neutral)
                try? await Task.sleep(for: .seconds(1))
            }
            linkDone = true
        }
    }

    @ViewBuilder private var screen: some View {
        switch config.name {
        case "gallery": FixtureGallery()
        case "home": FixtureHome(state: .full)
        case "home-loading": FixtureHome(state: .loading)
        case "home-error": FixtureHome(state: .error)
        case "shelves": FixtureShelves(lateArt: false)
        case "art-load": FixtureShelves(lateArt: true)
        case "library": FixtureLibrary(empty: false)
        case "library-empty": FixtureLibrary(empty: true)
        case "restore": FixtureRestore()
        case "detail": FixtureDetail(game: CatalogueFixtures.game(id: "fx-lanternfall"))
        case "detail-long": FixtureDetail(game: CatalogueFixtures.game(id: "fx-long-title"))
        case "detail-running": FixtureDetail(game: CatalogueFixtures.game(id: "fx-tidebreaker"))
        case "confirm-end": FixtureConfirmEnd()
        case "materials": FixtureMaterials()
        case let name where name.hasPrefix("app-"):
            AppScreenFixture(name: name)
        default:
            TVStatusView(kind: .error, title: "No fixture called \u{201C}\(config.name)\u{201D}",
                         message: "Known fixtures: " + FixtureName.all.joined(separator: ", "))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The safe region drawn on top, to check alignment by eye.
private struct SafeFrameOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let inset = CGRect(x: TVTokens.safeX, y: TVTokens.safeY,
                               width: geo.size.width - 2 * TVTokens.safeX, height: geo.size.height - 2 * TVTokens.safeY)
            Path { p in p.addRect(inset) }
                .stroke(Color.red.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [12, 8]))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: Initial focus

private struct FixtureFocusKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The `-focus` argument, for the fixture screen to apply once it has laid out.
    var fixtureFocus: String? {
        get { self[FixtureFocusKey.self] }
        set { self[FixtureFocusKey.self] = newValue }
    }
}
#endif
