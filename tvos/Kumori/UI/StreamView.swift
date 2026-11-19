import AVKit
import Combine
import CoreMedia
import GameController
import LiveKitWebRTC
import SwiftUI
import UIKit

/// Puts the stream on screen above everything else, and takes it down again.
@MainActor
enum StreamPresenter {
    private static weak var shown: StreamController?

    static func show(player: Player, settings: Settings, app: AppModel) {
        guard shown == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let c = StreamController(player: player, settings: settings, app: app)
        c.modalPresentationStyle = .fullScreen
        c.modalTransitionStyle = .crossDissolve
        top.present(c, animated: true)
        shown = c
    }

    static func hide() {
        shown?.dismiss(animated: true)
        shown = nil
    }
}

/// Hosts the video and what is drawn over it. While a game is being played, controller
/// presses go to the game only, so B doesn't back out of the stream.
final class StreamController: GCEventViewController {
    private let player: Player
    private let settings: Settings
    private let videoView = LKRTCMTLVideoView()
    private let overlay: UIHostingController<AnyView>
    private var track: LKRTCVideoTrack?
    private var watching = Set<AnyCancellable>()

    init(player: Player, settings: Settings, app: AppModel) {
        self.player = player
        self.settings = settings
        overlay = UIHostingController(rootView: AnyView(
            StreamOverlay().environmentObject(player).environmentObject(settings).environmentObject(app)
        ))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        videoView.videoContentMode = .scaleAspectFit
        for v in [videoView, overlay.view!] {
            v.frame = view.bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        view.addSubview(videoView)
        addChild(overlay)
        overlay.view.backgroundColor = .clear
        view.addSubview(overlay.view)
        overlay.didMove(toParent: self)

        player.$video.receive(on: RunLoop.main).sink { [weak self] t in self?.show(t) }.store(in: &watching)
        player.$phase.combineLatest(player.$menuOpen).receive(on: RunLoop.main).sink { [weak self] phase, menu in
            // The remote and controller drive Kumori's own screens until the picture is up,
            // and again whenever the menu is open.
            guard let self else { return }
            let own = phase != .live || menu
            if self.controllerUserInteractionEnabled != own {
                self.controllerUserInteractionEnabled = own
                // Hand focus to whatever is on screen now. Without this the menu can come up
                // with nothing focused, and Back would then leave the app.
                self.setNeedsFocusUpdate()
                self.updateFocusIfNeeded()
            }
            // Only a stream keeps the screen awake. The "stream stopped" screen may sit
            // there unattended, so it lets the screen saver start.
            var over = false
            if case .some(.ended) = phase { over = true }
            UIApplication.shared.isIdleTimerDisabled = phase != nil && !over
            self.matchDisplay(phase != nil && !over)
        }.store(in: &watching)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [overlay] }

    /// The window's display manager, where this tvOS still has one. tvOS 27 dropped the
    /// window's `avDisplayManager`, and asking for it there ends the app, so check first.
    private var displayManager: AVDisplayManager? {
        guard let window = view.window, window.responds(to: NSSelectorFromString("avDisplayManager")) else { return nil }
        return window.value(forKey: "avDisplayManager") as? AVDisplayManager
    }

    /// Asks the TV for SDR at the stream's frame rate while a stream is up. An Apple TV left
    /// at 50 Hz would judder, and one left in HDR would tone-map the picture. The system only
    /// switches if "Match Content" is on in its settings.
    private func matchDisplay(_ on: Bool) {
        guard let manager = displayManager else { return }
        guard on else {
            manager.preferredDisplayCriteria = nil
            return
        }
        guard manager.preferredDisplayCriteria == nil else { return }
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: 1920, height: 1080, extensions: nil, formatDescriptionOut: &format
        )
        let rate = Float(min(settings.mode.fps, Capabilities.maxFps))
        if let format { manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: rate, formatDescription: format) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The window only exists from here on.
        var over = false
        if case .some(.ended) = player.phase { over = true }
        matchDisplay(player.phase != nil && !over)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        show(nil)
        displayManager?.preferredDisplayCriteria = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func show(_ t: LKRTCVideoTrack?) {
        guard t !== track else { return }
        track?.remove(videoView)
        track = t
        t?.add(videoView)
    }
}

/// Everything drawn over the video (U10–U12): the way to a picture, the end of a session,
/// the stats line, a passing notice and the in-game menu.
struct StreamOverlay: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings
    @Environment(\.tvReduceMotion) private var reduced

    var body: some View {
        ZStack {
            switch player.phase {
            case .starting(let text), .connecting(let text):
                StreamWaiting(stage: text, position: nil).transition(.opacity)
            case .queued(let position):
                StreamWaiting(stage: "Waiting for a free rig", position: position).transition(.opacity)
            case .ended(let message, let error):
                StreamEnded(message: message, error: error).transition(.opacity)
            case .live, .none:
                EmptyView()
            }
            if player.phase == .live {
                if settings.showStats && !player.menuOpen { StreamStatsLine().transition(.opacity) }
                if let notice = player.notice, !player.menuOpen { StreamNotice(text: notice).transition(.opacity) }
                if player.menuOpen {
                    StreamMenu().transition(reduced ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(TVMotion.panel(reduced: reduced), value: player.menuOpen)
        .animation(reduced ? TVMotion.reducedFade : .easeInOut(duration: 0.25), value: player.phase)
        .animation(TVMotion.panel(reduced: reduced), value: player.notice)
        .animation(TVMotion.panel(reduced: reduced), value: settings.showStats)
    }
}

/// The game's own art behind the waiting and ended screens, held still and dimmed, so the
/// screen reads as "this game" without competing with the words on it. The same left edge
/// and bottom block as the detail screen it came from.
private struct StreamBackdrop: View {
    let game: Game?

    var body: some View {
        ZStack {
            TVColor.canvas
            if let game {
                TVArtwork(source: game.tvHero, title: "", titleOnPlaceholder: false, fill: true)
                    .opacity(0.55)
            }
            TVScrim(edge: .leading)
            LinearGradient(colors: [.clear, TVColor.canvas.opacity(0.9)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// From Play to the first picture: the game, one line that says what is happening now, and
/// Cancel. No made-up progress.
private struct StreamWaiting: View {
    let stage: String
    /// Place in the queue, when GeForce NOW says.
    let position: Int?
    @EnvironmentObject private var player: Player
    @FocusState private var cancelFocused: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            StreamBackdrop(game: player.game)
            VStack(alignment: .leading, spacing: TVTokens.group) {
                Text(player.game?.title ?? "Starting your game")
                    .font(TVType.title)
                    .foregroundStyle(TVColor.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .accessibilityAddTraits(.isHeader)
                if let position {
                    Text(position == 1 ? "You\u{2019}re next in the queue" : "Number \(position) in the queue")
                        .font(TVType.shelf)
                        .foregroundStyle(TVColor.primary)
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("stream-queue-position")
                }
                HStack(spacing: TVTokens.medium) {
                    ProgressView()
                    Text(stage)
                        .font(TVType.body)
                        .foregroundStyle(TVColor.secondary)
                        .accessibilityIdentifier("stream-stage")
                }
                Button { player.cancel() } label: { Label("Cancel", systemImage: "xmark") }
                    .focused($cancelFocused)
                    .accessibilityIdentifier("stream-cancel")
                    .padding(.top, TVTokens.small)
            }
            .frame(maxWidth: TVTokens.heroTextWidth, alignment: .leading)
            .padding(.leading, TVTokens.safeX)
            .padding(.bottom, TVTokens.safeY + 40)
        }
        .defaultFocus($cancelFocused, true)
        .onExitCommand { player.cancel() }
    }
}

/// The end of a session, or a stream that stopped. Says which, says why, and offers the
/// useful next step first.
private struct StreamEnded: View {
    let message: String
    let error: Bool
    @EnvironmentObject private var player: Player
    @FocusState private var focus: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            StreamBackdrop(game: player.game)
            VStack(alignment: .leading, spacing: TVTokens.group) {
                if let title = player.game?.title {
                    Text(title)
                        .font(TVType.callout.weight(.semibold))
                        .foregroundStyle(TVColor.secondary)
                        .lineLimit(1)
                }
                Text(error ? "The stream stopped" : "Session ended")
                    .font(TVType.title)
                    .foregroundStyle(TVColor.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(TVType.body)
                    .foregroundStyle(TVColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("stream-ended-message")
                HStack(spacing: TVTokens.group) {
                    if error {
                        Button { player.retry() } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                            .focused($focus, equals: "retry")
                            .accessibilityIdentifier("stream-retry")
                    }
                    Button { player.dismiss() } label: { Text(error ? "Close" : "Done") }
                        .focused($focus, equals: "close")
                        .accessibilityIdentifier("stream-close")
                }
                .padding(.top, TVTokens.small)
                .focusSection()
            }
            .frame(maxWidth: TVTokens.heroTextWidth, alignment: .leading)
            .padding(.leading, TVTokens.safeX)
            .padding(.bottom, TVTokens.safeY + 40)
        }
        .defaultFocus($focus, error ? "retry" : "close")
        .onExitCommand { player.dismiss() }
    }
}

/// The optional stats line, top trailing inside the safe area. Only measured values are
/// shown: a number that hasn't arrived is left out, never shown as zero. Not focusable.
private struct StreamStatsLine: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        let s = player.stats
        let parts = [
            s.width > 0 ? "\(s.width)×\(s.height)" : nil,
            s.fps.map { String(format: "%.0f fps", $0) },
            s.codec,
            s.bitrateMbps.map { String(format: "%.1f Mbps", $0) },
            s.rttMs.map { String(format: "%.0f ms", $0) },
            s.lossPct.map { String(format: "%.1f%% loss", $0) },
            s.decodeMs.map { String(format: "decode %.1f ms", $0) },
        ].compactMap { $0 }
        Text(parts.isEmpty ? "Measuring\u{2026}" : parts.joined(separator: "   "))
            .font(TVType.detail.monospacedDigit())
            .foregroundStyle(TVColor.primary)
            .padding(.horizontal, TVTokens.medium)
            .padding(.vertical, TVTokens.small)
            .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.trailing, TVTokens.safeX)
            .padding(.top, TVTokens.safeY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .allowsHitTesting(false)
            .accessibilityIdentifier("stream-stats")
    }
}

/// A passing message at the top of the picture. It goes by itself after eight seconds.
private struct StreamNotice: View {
    let text: String
    @EnvironmentObject private var player: Player

    var body: some View {
        Text(text)
            .font(TVType.callout)
            .foregroundStyle(TVColor.primary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, TVTokens.group)
            .padding(.vertical, TVTokens.medium)
            .frame(maxWidth: 1100)
            .tvSurface(.overlay, radius: 20)
            .padding(.top, TVTokens.safeY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .accessibilityIdentifier("stream-notice")
            .task(id: text) {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled, player.notice == text { player.notice = nil }
            }
    }
}

/// The in-game menu: a drawer on the trailing edge. Hold Menu on a controller, or press Back
/// on the Siri Remote. Resume has focus first; Back closes it. A new resolution is chosen
/// first and applied with one press, so the stream reconnects once.
struct StreamMenu: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel
    @State private var confirmEnd = false
    @State private var staged: StreamMode?
    @FocusState private var focus: String?

    var body: some View {
        let active = player.playing ?? settings.mode
        let chosen = staged ?? active
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: TVTokens.group) {
                    header
                    VStack(spacing: TVTokens.medium) {
                        Button { player.menuOpen = false } label: { row("Resume", "play.fill") }
                            .focused($focus, equals: "resume")
                            .accessibilityIdentifier("menu-resume")
                        Button { player.leave() } label: { row("Leave Game Running", "rectangle.portrait.and.arrow.right") }
                            .accessibilityIdentifier("menu-leave")
                    }

                    heading("Resolution")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: TVTokens.medium), GridItem(.flexible())],
                              spacing: TVTokens.medium) {
                        ForEach(Array(StreamMode.all.reversed())) { m in
                            let blocked = Capabilities.check(m, membership: app.membership).blocked
                            Button { staged = m == active ? nil : m } label: {
                                HStack {
                                    Text("\(m.resolution.label) · \(m.fps)").monospacedDigit()
                                    Spacer(minLength: 0)
                                    Image(systemName: "checkmark").opacity(m == chosen ? 1 : 0)
                                }
                                .font(TVType.callout)
                            }
                            .disabled(blocked)
                            .accessibilityIdentifier("menu-mode-\(m.id)")
                        }
                    }
                    if let staged, staged != active {
                        Button { player.changeMode(staged); self.staged = nil } label: {
                            row("Switch to \(staged.label)", "arrow.triangle.2.circlepath")
                        }
                        .accessibilityIdentifier("menu-apply-mode")
                    } else {
                        Text("Playing at \(active.label).")
                            .font(TVType.detail)
                            .foregroundStyle(TVColor.tertiary)
                    }

                    heading("Options")
                    VStack(spacing: TVTokens.medium) {
                        Toggle(isOn: $settings.showStats) { Label("Stats", systemImage: "chart.bar.xaxis") }
                        Toggle(isOn: Binding(get: { !player.muted }, set: { player.muted = !$0 })) {
                            Label("Sound", systemImage: "speaker.wave.2.fill")
                        }
                        Button { player.refreshPicture() } label: { row("Refresh Picture", "sparkles.tv") }
                        Button { confirmEnd = true } label: { row("End Game", "power") }
                            .focused($focus, equals: "end")
                            .accessibilityIdentifier("menu-end")
                    }
                }
                .padding(TVTokens.menuInset)
            }
            .scrollClipDisabled()
            .frame(width: TVTokens.menuWidth)
            .tvSurface(.overlay, radius: TVTokens.panelRadius)
            .padding(.vertical, TVTokens.safeY)
            .padding(.trailing, TVTokens.safeX)
            .focusSection()
        }
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .defaultFocus($focus, "resume")
        .onExitCommand { player.menuOpen = false }
        .endSessionConfirmation(
            isPresented: $confirmEnd, title: player.game?.title ?? "this game",
            onCancel: { focus = "end" },
            onEnd: { player.quit() }
        )
        .accessibilityIdentifier("stream-menu")
    }

    private var header: some View {
        HStack(spacing: TVTokens.group) {
            if let game = player.game {
                TVArtwork(source: game.tvArt, title: game.title, shape: .landscape)
                    .frame(width: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(player.game?.title ?? "Game")
                    .font(TVType.shelf)
                    .foregroundStyle(TVColor.primary)
                    .lineLimit(2)
                if let t = player.playingFor {
                    Text("Playing for \(Self.duration(t))")
                        .font(TVType.detail)
                        .foregroundStyle(TVColor.secondary)
                }
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(TVType.callout.weight(.semibold))
            .foregroundStyle(TVColor.secondary)
            .padding(.top, TVTokens.small)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func duration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return m < 60 ? "\(max(m, 1)) min" : "\(m / 60) h \(m % 60) min"
    }
}
