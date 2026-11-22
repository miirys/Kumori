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

    static func show(player: Player, settings: Settings, app: AppModel, tries: Int = 0) {
        guard shown == nil, player.active else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        guard var top = window?.rootViewController else {
            retry(player: player, settings: settings, app: app, tries: tries)
            return
        }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        // The last stream (or a detail page) may still be animating away. Presenting on top
        // of it fails without a word, which used to leave a launch running with no screen.
        if top.isBeingDismissed || top.presentedViewController != nil {
            retry(player: player, settings: settings, app: app, tries: tries)
            return
        }
        let c = StreamController(player: player, settings: settings, app: app)
        c.modalPresentationStyle = .fullScreen
        c.modalTransitionStyle = .crossDissolve
        shown = c
        top.present(c, animated: true) { player.presented(true) }
    }

    private static func retry(player: Player, settings: Settings, app: AppModel, tries: Int) {
        guard tries < 8 else {
            player.presented(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            show(player: player, settings: settings, app: app, tries: tries + 1)
        }
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
    private let videoView = PictureView(frame: .zero)
    private let overlay: UIHostingController<AnyView>
    private var track: LKRTCVideoTrack?
    private var watching = Set<AnyCancellable>()
    /// Kept from when the window was there, so the TV's mode can be put back after the
    /// window is gone.
    private weak var heldDisplayManager: AVDisplayManager?

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
            let own = InputOwner.forStream(live: phase == .live, menuOpen: menu) == .interface
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

    /// The window's display manager, where this tvOS still has one. Version 1.2.1 asked for
    /// it without checking, and on the reported Apple TV that selector was missing, which ended
    /// the app the moment Play was pressed. Every use goes through `StreamDisplay.manager`.
    private var displayManager: AVDisplayManager? {
        if let m = StreamDisplay.manager(of: view.window) { heldDisplayManager = m }
        return heldDisplayManager
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
        guard manager.isDisplayCriteriaMatchingEnabled, manager.preferredDisplayCriteria == nil else { return }
        let fps = player.safeAttempt ? 60 : settings.mode.fps
        // Never ask the TV for more than it can show; a faster stream still fills each refresh.
        if let criteria = StreamDisplay.criteria(fps: min(fps, Capabilities.displayHz)) {
            manager.preferredDisplayCriteria = criteria
        }
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
        heldDisplayManager?.preferredDisplayCriteria = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func show(_ t: LKRTCVideoTrack?) {
        guard t !== track else { return }
        track?.remove(videoView.feed)
        track = t
        videoView.feed.reset()
        guard let t else { return }
        let p = player
        // The first frame handed to the screen is the first moment there is a picture to see.
        videoView.feed.onFirst = { p.frameShown() }
        t.add(videoView.feed)
    }
}

/// The TV's display mode while streaming, in one place so the lookup is always guarded.
@MainActor
enum StreamDisplay {
    /// The window's `avDisplayManager`, or nil where this tvOS doesn't answer to it.
    static func manager(of window: UIWindow?) -> AVDisplayManager? {
        let key = "avDisplayManager"
        guard let window, window.responds(to: NSSelectorFromString(key)) else { return nil }
        return window.value(forKey: key) as? AVDisplayManager
    }

    /// SDR, 1080p H.264 at the given rate: what a GeForce NOW stream looks like to the TV.
    static func criteria(fps: Int) -> AVDisplayCriteria? {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: 1920, height: 1080, extensions: nil, formatDescriptionOut: &format
        )
        guard let format else { return nil }
        return AVDisplayCriteria(refreshRate: Float(fps), formatDescription: format)
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
                    StreamMenu().transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(TVMotion.panel(reduced: reduced), value: player.menuOpen)
        .animation(reduced ? TVMotion.reducedFade : .easeInOut(duration: 0.25), value: player.phase)
        .animation(TVMotion.panel(reduced: reduced), value: player.notice)
        .animation(TVMotion.panel(reduced: reduced), value: settings.showStats)
        .animation(TVMotion.panel(reduced: reduced), value: settings.statsDetailed)
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
            // The system's 80 pt safe area already insets this screen; no second inset.
            .padding(.bottom, TVTokens.safeY)
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
        ZStack {
            StreamBackdrop(game: player.game)
            // One pane of glass in the middle of the game's art.
            VStack(spacing: 0) {
                if !error {
                    TVPowerGlyph(size: 88, tint: TVColor.primary)
                        .padding(.bottom, 32)
                }
                if let title = player.game?.title {
                    Text(title)
                        .font(TVType.callout.weight(.semibold))
                        .foregroundStyle(TVColor.secondary)
                        .lineLimit(1)
                        .padding(.bottom, 8)
                }
                Text(error ? "The stream stopped" : "Session ended")
                    .font(TVType.title)
                    .foregroundStyle(TVColor.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(TVType.body)
                    .foregroundStyle(TVColor.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .accessibilityIdentifier("stream-ended-message")
                if error, let t = player.trace {
                    // Enough to tell one failure from another in a photo of the screen.
                    Text("\(t.lastGood?.label ?? "Play pressed") \u{00B7} \(String(format: "%.0f", t.elapsed)) s \u{00B7} launch \(t.id) \u{00B7} \(BuildInfo.current.display)")
                        .font(TVType.detail.monospacedDigit())
                        .foregroundStyle(TVColor.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 14)
                        .accessibilityIdentifier("stream-launch-trace")
                }
                HStack(spacing: 20) {
                    if error {
                        Button { player.retry() } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                            .focused($focus, equals: "retry")
                            .accessibilityIdentifier("stream-retry")
                    }
                    if error, player.offerSafeRetry {
                        Button { player.retrySafe() } label: { Text("Try 1080p60 H.264") }
                            .focused($focus, equals: "safe")
                            .accessibilityIdentifier("stream-retry-safe")
                    }
                    if error, player.holdsSession {
                        // The game may still be running in the cloud. End it in one press,
                        // rather than leaving it to block the next launch.
                        Button(role: .destructive) { player.quit() } label: { Text("End Session") }
                            .buttonStyle(TVActionStyle(role: .destructive, shape: .capsule, alignment: .center))
                            .focused($focus, equals: "end")
                            .accessibilityIdentifier("stream-end-session")
                    }
                    Button { player.dismiss() } label: { Text(error ? "Close" : "Done") }
                        .focused($focus, equals: "close")
                        .accessibilityIdentifier("stream-close")
                }
                .buttonStyle(TVActionStyle(shape: .capsule, alignment: .center))
                .fixedSize()
                .padding(.top, 44)
                .focusSection()
            }
            .padding(.horizontal, 64)
            .padding(.top, 52)
            .padding(.bottom, 56)
            .frame(width: 1000)
            .tvLiquidGlass(radius: 48)
            .shadow(color: .black.opacity(0.5), radius: 60, y: 30)
            .tvAppear()
        }
        .defaultFocus($focus, error ? "retry" : "close")
        .onExitCommand { player.dismiss() }
    }
}

/// The optional stats line, top trailing inside the safe area. Only measured values are
/// shown: a number that hasn't arrived is left out, never shown as zero. Not focusable.
private struct StreamStatsLine: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings

    /// GeForce NOW's own overlay, in the same top-right corner, on Liquid Glass. Compact is
    /// one line: picture, rate, latency and loss. Detailed adds bandwidth, codec, decoding
    /// and input. A value turns amber, then red, only when it's bad enough to feel.
    var body: some View {
        Group {
            if settings.statsDetailed { detailed } else { compact }
        }
        // The overlay sits inside the system safe area, so no extra inset here.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stream-stats")
    }

    private var s: StreamStats { player.stats }

    private var picture: String {
        guard s.width > 0 else { return "Measuring\u{2026}" }
        return "\(Resolution.allCases.min { abs($0.height - s.height) < abs($1.height - s.height) }?.label ?? "\(s.height)p")"
            + (s.fps.map { String(format: " \u{00B7} %.0f FPS", $0) } ?? "")
    }

    private var compact: some View {
        HStack(spacing: 18) {
            Text(picture).foregroundStyle(TVColor.primary)
            value(s.rttMs.map { String(format: "%.0f ms", $0) }, level: latencyLevel)
            value(s.lossPct.map { String(format: "%.1f%%", $0) }, level: lossLevel)
        }
        .font(TVType.detail.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .tvLiquidGlassCapsule()
    }

    private var detailed: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(s.width > 0 ? "\(s.width) \u{00D7} \(s.height)" + (s.fps.map { String(format: "  %.0f FPS", $0) } ?? "") : "Measuring\u{2026}")
                .font(TVType.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(TVColor.primary)
                .padding(.bottom, 4)
            row("Latency", s.rttMs.map { String(format: "%.0f ms", $0) }, level: latencyLevel)
            row("Packet Loss", s.lossPct.map { String(format: "%.1f%%", $0) }, level: lossLevel)
            row("Bandwidth", s.bitrateMbps.map { String(format: "%.1f Mbps", $0) })
            row("Codec", s.codec.map { $0 == "H265" ? "H.265" : $0 == "H264" ? "H.264" : $0 })
            row("Decode", s.decodeMs.map { String(format: "%.1f ms", $0) }, level: s.decodeMs.map { $0 > 16 ? 2 : $0 > 8 ? 1 : 0 } ?? 0)
            row("Input", player.inputStats.version.map { _ in player.inputStats.rejected > 0 ? "\(player.inputStats.rejected) refused" : "OK" } ?? "Waiting")
        }
        .font(TVType.detail.monospacedDigit())
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .frame(width: 380, alignment: .leading)
        .tvLiquidGlass(radius: 28)
    }

    private var latencyLevel: Int { s.rttMs.map { $0 > 80 ? 2 : $0 > 40 ? 1 : 0 } ?? 0 }
    private var lossLevel: Int { s.lossPct.map { $0 > 2 ? 2 : $0 > 0.5 ? 1 : 0 } ?? 0 }

    private func value(_ text: String?, level: Int) -> some View {
        Text(text ?? "\u{2014}")
            .foregroundStyle(level == 2 ? TVColor.danger : level == 1 ? Color(red: 1, green: 0.78, blue: 0.3) : TVColor.secondary)
            .lineLimit(1)
    }

    private func row(_ name: String, _ text: String?, level: Int = 0) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(TVColor.secondary)
            Spacer(minLength: 16)
            Text(text ?? "\u{2014}")
                .foregroundStyle(level == 2 ? TVColor.danger : level == 1 ? Color(red: 1, green: 0.78, blue: 0.3) : TVColor.primary)
                .lineLimit(1)
        }
    }
}

/// A passing message at the bottom of the picture. It goes by itself after eight seconds.
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
            // Bottom centre: the stats line owns the top trailing corner.
            .padding(.bottom, TVTokens.group)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
            .accessibilityIdentifier("stream-notice")
            .task(id: text) {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled, player.notice == text { player.notice = nil }
            }
    }
}

/// The in-game menu. Hold Menu on a controller, or press Back on the Siri Remote. The game
/// stays on screen behind frosted glass; on the left, the game and what to do with it
/// (Resume has focus first); on the right, the stream's settings on a glass panel. Back
/// closes it. A new resolution is chosen first and applied with one press, so the stream
/// reconnects once.
struct StreamMenu: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel
    @Environment(\.tvReduceTransparency) private var opaque
    @State private var confirmEnd = false
    @State private var staged: StreamMode?
    @FocusState private var focus: String?

    var body: some View {
        let active = player.playing ?? settings.mode
        let chosen = staged ?? active
        ZStack {
            veil
            // Both columns sized to what they hold, tops level, the pair centred on the
            // screen, so there is no empty glass and no slab of nothing under the buttons.
            HStack(alignment: .top, spacing: 80) {
                gameColumn
                    .frame(width: 600, alignment: .leading)
                    .focusSection()
                streamPanel(active: active, chosen: chosen)
                    .focusSection()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tvPageEntrance(rise: 28, veil: false)
        }
        .defaultFocus($focus, "resume")
        .onExitCommand { player.menuOpen = false }
        .endSessionConfirmation(
            isPresented: $confirmEnd, title: player.game?.title ?? "this game",
            onCancel: { focus = "end" },
            onEnd: { player.quit() }
        )
        // `.contain` first, so the identifier names the menu and doesn't replace the
        // identifiers of the buttons inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stream-menu")
    }

    /// The paused game behind frosted glass, darker at the bottom.
    private var veil: some View {
        ZStack {
            if opaque {
                Color.black.opacity(0.86)
            } else {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: [.black.opacity(0.38), .black.opacity(0.66)], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: The game

    private var gameColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let game = player.game {
                TVArtwork(source: game.tvArt, title: game.title, shape: .landscape)
                    .frame(width: 352)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                    .padding(.bottom, 32)
            }
            Text(player.game?.title ?? "Game")
                .font(TVType.title)
                .foregroundStyle(TVColor.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            if let line = statusLine {
                Text(line)
                    .font(TVType.callout)
                    .foregroundStyle(TVColor.secondary)
                    .lineLimit(1)
                    .padding(.top, 10)
            }

            VStack(spacing: 14) {
                Button { player.menuOpen = false } label: { Label("Resume", systemImage: "play.fill") }
                    .focused($focus, equals: "resume")
                    .accessibilityIdentifier("menu-resume")
                Button { player.leave() } label: { Label("Leave Game Running", systemImage: "rectangle.portrait.and.arrow.right") }
                    .accessibilityIdentifier("menu-leave")
                // Third from the top, so ending a game is two presses down, not the
                // whole menu's length.
                Button(role: .destructive) { confirmEnd = true } label: { Label("End Game", systemImage: "power") }
                    .buttonStyle(TVActionStyle(role: .destructive, height: 80))
                    .focused($focus, equals: "end")
                    .accessibilityIdentifier("menu-end")
            }
            .buttonStyle(TVActionStyle(height: 80))
            .padding(.top, 44)
        }
    }

    /// "Playing for 45 min · 2560×1440 · HEVC"
    private var statusLine: String? {
        let s = player.stats
        let parts = [
            player.playingFor.map { "Playing for \(Self.duration($0))" },
            s.width > 0 ? "\(s.width)\u{00D7}\(s.height)" : nil,
            s.codec,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  \u{00B7}  ")
    }

    // MARK: The stream

    private func streamPanel(active: StreamMode, chosen: StreamMode) -> some View {
        VStack(alignment: .leading, spacing: 34) {
            group("Resolution") {
                HStack(spacing: 14) {
                    ForEach(Resolution.allCases, id: \.self) { r in
                        let mode = Self.mode(r, preferring: chosen.fps, membership: app.membership)
                        Button { stage(mode, active: active) } label: {
                            Text(r.label).monospacedDigit()
                        }
                        .buttonStyle(TVActionStyle(shape: .capsule, selected: r == chosen.resolution, alignment: .center))
                        .disabled(mode == nil)
                        .accessibilityAddTraits(r == chosen.resolution ? .isSelected : [])
                        .accessibilityIdentifier("menu-res-\(r.rawValue)")
                    }
                }
            }
            group("Frame Rate") {
                HStack(spacing: 14) {
                    ForEach(StreamMode.rates, id: \.self) { fps in
                        let mode = StreamMode(resolution: chosen.resolution, fps: fps)
                        Button { stage(mode, active: active) } label: {
                            Text("\(fps) fps").monospacedDigit()
                        }
                        .buttonStyle(TVActionStyle(shape: .capsule, selected: fps == chosen.fps, alignment: .center))
                        .disabled(Capabilities.check(mode, membership: app.membership).blocked)
                        .accessibilityAddTraits(fps == chosen.fps ? .isSelected : [])
                        .accessibilityIdentifier("menu-fps-\(fps)")
                    }
                    // Two chips over the width of four, so each lines up under a resolution.
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            }

            Group {
                if let staged, staged != active {
                    Button { player.changeMode(staged); self.staged = nil } label: {
                        Label("Switch to \(staged.label)", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(TVActionStyle(selected: true))
                    .accessibilityIdentifier("menu-apply-mode")
                } else {
                    Text(modeNote(active))
                        .font(TVType.detail)
                        .foregroundStyle(TVColor.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                }
            }

            group("Options") {
                VStack(spacing: 10) {
                    Button { settings.cycleStats() } label: {
                        optionRow("Stats", "chart.bar.xaxis", value: settings.statsLabel)
                    }
                    .accessibilityValue(settings.statsLabel)
                    .accessibilityIdentifier("menu-stats")
                    Button { player.muted.toggle() } label: {
                        optionRow("Sound", "speaker.wave.2.fill", value: player.muted ? "Off" : "On")
                    }
                    .accessibilityValue(player.muted ? "Off" : "On")
                    .accessibilityIdentifier("menu-sound")
                    Button { player.refreshPicture() } label: {
                        optionRow("Refresh Picture", "sparkles.tv", value: nil)
                    }
                    .accessibilityIdentifier("menu-refresh")
                }
                .buttonStyle(TVActionStyle())
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .tvGlass(radius: 40)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(TVType.caption.weight(.semibold))
                .foregroundStyle(TVColor.tertiary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func optionRow(_ title: String, _ icon: String, value: String?) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer(minLength: TVTokens.group)
            if let value {
                Text(value).opacity(0.62)
            }
        }
    }

    /// Choosing the mode already playing un-stages any change.
    private func stage(_ mode: StreamMode?, active: StreamMode) {
        guard let mode else { return }
        staged = mode == active ? nil : mode
    }

    /// `r` at the rate already chosen if this Apple TV and the membership allow it, otherwise
    /// at 60. Nil if `r` can't be played at all.
    private static func mode(_ r: Resolution, preferring fps: Int, membership: Membership?) -> StreamMode? {
        for rate in [fps, 60] {
            let m = StreamMode(resolution: r, fps: rate)
            if !Capabilities.check(m, membership: membership).blocked { return m }
        }
        return nil
    }

    /// What is playing now.
    private func modeNote(_ active: StreamMode) -> String {
        "Streaming at \(active.label)"
    }

    private static func duration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return m < 60 ? "\(max(m, 1)) min" : "\(m / 60) h \(m % 60) min"
    }
}
