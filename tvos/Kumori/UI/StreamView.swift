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
        guard let c = shown else { return }
        shown = nil
        // Ask the screen underneath. Asked of the stream itself while it had the keyboard or
        // the End Game question up, UIKit took down only that, and left the stream on screen
        // with nothing in it.
        if let below = c.presentingViewController, below.presentedViewController === c {
            below.dismiss(animated: true)
        } else {
            c.dismiss(animated: true)
        }
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
    /// The rate the display criteria were last set for.
    private var matchedFps: Int?

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

        // The native receiver draws into the same view, without a WebRTC track.
        player.screen = videoView.feed
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
            Awake.shared.stream(phase != nil && !over)
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
        // While Kumori holds the TV at 120 Hz itself, the system's matching would only fight it.
        guard on, !HDMIMode.holding else {
            manager.preferredDisplayCriteria = nil
            matchedFps = nil
            return
        }
        // The rate of the stream really playing, once it is known: a resumed session keeps its
        // own mode, which can differ from the one in Settings.
        let wanted = player.safeAttempt ? 60 : (player.playing?.fps ?? settings.mode.fps)
        // A fast stream on a box that offers 120 Hz is HDMIMode's to switch. Asked for 60 Hz
        // SDR here as well, the system's switch (out of HDR, say) landed on top of HDMIMode's
        // and the TV stayed at 60 Hz.
        if wanted > 60, (HDMIMode.fastestRate ?? 0) >= wanted {
            if manager.preferredDisplayCriteria != nil { manager.preferredDisplayCriteria = nil }
            matchedFps = nil
            return
        }
        // Never ask the system for more than tvOS itself reports; HDMIMode handles 120 Hz.
        let fps = min(wanted, max(60, UIScreen.main.maximumFramesPerSecond))
        guard manager.isDisplayCriteriaMatchingEnabled, manager.preferredDisplayCriteria == nil || matchedFps != fps else { return }
        if let criteria = StreamDisplay.criteria(fps: fps) {
            manager.preferredDisplayCriteria = criteria
            matchedFps = fps
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The window only exists from here on.
        var over = false
        if case .some(.ended) = player.phase { over = true }
        matchDisplay(player.phase != nil && !over)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Hand the controllers back to the interface before this screen goes. Left off, a
        // stream that ended while live kept this controller swallowing button presses after
        // it was gone, so A did nothing on the game pages until the app was restarted.
        controllerUserInteractionEnabled = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        controllerUserInteractionEnabled = true
        show(nil)
        heldDisplayManager?.preferredDisplayCriteria = nil
        matchedFps = nil
        Awake.shared.stream(false)
        HDMIMode.streamScreenClosed()
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
                if let left = player.idleLeft, !player.menuOpen {
                    StreamIdleWarning(secondsLeft: left)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let notice = player.notice, !player.menuOpen {
                    StreamNotice(text: notice)
                        .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.94, anchor: .bottom)))
                }
                if player.menuOpen {
                    StreamMenu().transition(.asymmetric(
                        insertion: .identity,
                        removal: .modifier(active: MenuExit(on: true), identity: MenuExit(on: false))
                    ))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(TVMotion.panel(reduced: reduced), value: player.menuOpen)
        .animation(reduced ? TVMotion.reducedFade : .easeInOut(duration: 0.25), value: player.phase)
        .animation(TVMotion.panel(reduced: reduced), value: player.notice)
        .animation(TVMotion.panel(reduced: reduced), value: settings.showStats)
        .animation(TVMotion.panel(reduced: reduced), value: settings.statsDetailed)
        .animation(TVMotion.panel(reduced: reduced), value: player.idleLeft == nil)
        .animation(TVMotion.panel(reduced: reduced), value: player.belowTarget)
    }
}

/// Two minutes before the idle timer ends a session: what will happen, when, and how to
/// stop it. Any button on any controller does.
private struct StreamIdleWarning: View {
    let secondsLeft: Double
    @EnvironmentObject private var settings: Settings

    var body: some View {
        HStack(spacing: 28) {
            Image(systemName: "hourglass")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(TVColor.primary)
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Still playing?")
                    .font(TVType.callout.weight(.semibold))
                    .foregroundStyle(TVColor.primary)
                Text("Press any button to keep playing")
                    .font(TVType.caption)
                    .foregroundStyle(TVColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Self.clock(secondsLeft))
                .font(.system(size: 54, weight: .bold).monospacedDigit())
                .foregroundStyle(TVColor.primary)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: Int(secondsLeft))
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
        .frame(maxWidth: 1180)
        .tvLiquidGlass(radius: 36)
        .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
        .padding(.bottom, TVTokens.group)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stream-idle-warning")
    }

    /// "1:52".
    static func clock(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.up)))
        return String(format: "%d:%02d", t / 60, t % 60)
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
                        .contentTransition(.opacity)
                        .id(stage)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .move(edge: .top).combined(with: .opacity)))
                        .accessibilityIdentifier("stream-stage")
                }
                Button { player.cancel() } label: { Label("Cancel", systemImage: "xmark") }
                    .buttonStyle(TVActionStyle(shape: .capsule, alignment: .center))
                    .fixedSize()
                    .focused($cancelFocused)
                    .accessibilityIdentifier("stream-cancel")
                    .padding(.top, TVTokens.small)
            }
            .frame(maxWidth: TVTokens.heroTextWidth, alignment: .leading)
            // The system's 80 pt safe area already insets this screen; no second inset.
            .padding(.bottom, TVTokens.safeY)
            .animation(.spring(duration: 0.45, bounce: 0.1), value: stage)
            .animation(.spring(duration: 0.45, bounce: 0.1), value: position)
        }
        .defaultFocus($cancelFocused, true)
        .task {
            // Cancel is the only thing here. If the focus engine hasn't put it there by
            // itself (the screen changed under it), Back would find nothing and leave the app.
            for wait in [30, 150, 400] {
                try? await Task.sleep(for: .milliseconds(wait))
                if Task.isCancelled || cancelFocused { return }
                cancelFocused = true
            }
        }
        .onBack { player.cancel() }
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
                    Text("\(t.lastGood?.label ?? "Play pressed"), \(String(format: "%.0f", t.elapsed)) s. Launch \(t.id). Build \(BuildInfo.current.display).")
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
        .task {
            // Arrives as the stream goes, while the controller is handed back to the interface,
            // so the focus engine may not land on it by itself. Every button here is tagged, so
            // nil means nothing here has focus.
            for wait in [30, 150, 400] {
                try? await Task.sleep(for: .milliseconds(wait))
                if Task.isCancelled || focus != nil { return }
                focus = error ? "retry" : "close"
            }
        }
        .onBack { player.dismiss() }
    }
}

/// The optional stats line, top trailing inside the safe area. Only measured values are
/// shown: a number that hasn't arrived is left out, never shown as zero. Not focusable.
private struct StreamStatsLine: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings
    @Environment(\.tvReduceMotion) private var reduced
    /// The below-target card on show. It comes in when the stream drops under its target,
    /// stays a few seconds, and glides back out even if the rate is still low (a heavy scene
    /// can hold it there for minutes); the FPS figure stays amber meanwhile. It comes back
    /// for a new drop at most once a minute.
    @State private var flash: BelowTargetReason?
    @State private var flashedAt: Date?

    /// GeForce NOW's own overlay, in the same top-right corner, on Liquid Glass. Compact is
    /// one line: picture, rate, latency and loss. Detailed adds bandwidth, codec, decoding
    /// and input. A value turns amber, then red, only when it's bad enough to feel.
    var body: some View {
        VStack(alignment: .trailing, spacing: 14) {
            if settings.statsDetailed { detailed } else { compact }
            if let reason = flash, !settings.statsDetailed {
                warning(reason)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.92, anchor: .topTrailing)),
                        removal: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .topTrailing))))
            }
        }
        .onChange(of: player.belowTarget) { _, now in
            guard let now, flash == nil else { return }
            if let t = flashedAt, Date().timeIntervalSince(t) < 60 { return }
            flashedAt = Date()
            withAnimation(reduced ? TVMotion.reducedFade : .spring(response: 0.5, dampingFraction: 0.78)) { flash = now }
        }
        .task(id: flashedAt) {
            guard flashedAt != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(reduced ? TVMotion.reducedFade : .spring(response: 0.55, dampingFraction: 0.9)) { flash = nil }
        }
        // Tucked into the top-right corner past the safe area's edge. On the whole column, so
        // the below-target card stays right-aligned under the compact line instead of hanging
        // in from it.
        .offset(x: settings.statsDetailed ? 50 : 44, y: settings.statsDetailed ? -32 : -26)
        // The overlay sits inside the system safe area, so no extra inset here.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stream-stats")
    }

    private var s: StreamStats { player.stats }

    /// The stream's target, as asked of the rig.
    private var target: Int { s.targetFps ?? 60 }

    /// Amber while the stream stays below its target.
    private var fpsLevel: Int { player.belowTarget == nil ? 0 : 1 }

    /// "Below 60 fps" and the reason, in words a person can act on.
    private func warning(_ reason: BelowTargetReason) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Self.ink(1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Below \(target) fps")
                    .font(TVType.caption.weight(.semibold))
                    .foregroundStyle(TVColor.primary)
                Text(FrameHealth.words(reason, target: target, shown: s.shownFps, decoded: s.decodedFps, refresh: s.refreshHz))
                    .font(TVType.detail)
                    .foregroundStyle(TVColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
        .frame(maxWidth: 560, alignment: .leading)
        .tvLiquidGlass(radius: 28)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stream-below-target")
    }

    // MARK: Compact

    /// One capsule: rate, latency, loss and picture, each a number with its unit beside it.
    private var compact: some View {
        HStack(spacing: 22) {
            metric(s.fps.map { String(format: "%.0f", $0) }, "FPS", level: fpsLevel, small: true)
            metric(s.rttMs.map { String(format: "%.0f", $0) }, "ms", level: latencyLevel, small: true)
            metric(s.lossPct.map { String(format: "%.1f%%", $0) }, "loss", level: lossLevel, small: true)
            if s.height > 0 { metric(Self.lines(s.height), nil, small: true) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .tvLiquidGlassCapsule()
    }

    private func metric(_ value: String?, _ unit: String?, level: Int = 0, small: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: small ? 4 : 6) {
            Text(value ?? "\u{2014}")
                .font((small ? TVType.caption : TVType.callout).weight(.semibold).monospacedDigit())
                .foregroundStyle(Self.ink(level))
            if let unit {
                Text(unit)
                    .font(TVType.detail.weight(.semibold))
                    .foregroundStyle(TVColor.tertiary)
            }
        }
        .lineLimit(1)
    }

    // MARK: Detailed

    /// The frame rate large, the picture beside it, then the network, the video and input
    /// as labelled groups of exact measurements.
    private var detailed: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(s.fps.map { String(format: "%.0f", $0) } ?? "\u{2014}")
                        .font(.system(size: 46, weight: .bold).monospacedDigit())
                        .foregroundStyle(Self.ink(fpsLevel))
                        .contentTransition(.numericText())
                        .animation(.snappy, value: s.fps.map { Int($0) })
                    Text("of \(target) FPS")
                        .font(Self.rowFont.weight(.semibold))
                        .foregroundStyle(TVColor.tertiary)
                }
                Spacer(minLength: 20)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(s.width > 0 ? "\(s.width) \u{00D7} \(s.height)" : "Measuring")
                        .font(.system(size: 23, weight: .semibold).monospacedDigit())
                        .foregroundStyle(TVColor.primary)
                    Text(Self.codecName(s.codec) ?? "Codec pending")
                        .font(Self.rowFont)
                        .foregroundStyle(TVColor.secondary)
                }
            }
            if let reason = player.belowTarget {
                Text(FrameHealth.words(reason, target: target, shown: s.shownFps, decoded: s.decodedFps, refresh: s.refreshHz))
                    .font(Self.rowFont)
                    .foregroundStyle(Self.ink(1))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            group("Frames") {
                row("On Screen", s.shownFps.map { String(format: "%.1f fps", $0) }, level: fpsLevel)
                row("Decoded", s.decodedFps.map { String(format: "%.1f fps", $0) })
                row("Target", "\(target) fps")
                row("TV Refresh", s.refreshHz.map { FrameHealth.hz($0) })
                row("Dropped Here", s.framesDroppedHere.map { $0.formatted() })
            }
            group("Network") {
                row("Latency", s.rttMs.map { String(format: "%.0f ms", $0) }, level: latencyLevel)
                row("Jitter", s.jitterMs.map { String(format: "%.1f ms", $0) })
                row("Packets Lost", packetsLost, level: lossLevel)
                if let resent = s.packetsResent { row("Packets Resent", resent.formatted()) }
                row("Bandwidth", s.bitrateMbps.map { String(format: "%.1f Mbps", $0) })
                if let t = s.transport { row("Transport", t) }
            }
            group("Video") {
                row("Codec", Self.codecName(s.codec))
                if let d = s.codecDetail { row("Format", d) }
                if let hw = s.hardwareDecode { row("Decoder", hw ? "Hardware" : "Software") }
                row("Decode Time", s.decodeMs.map { String(format: "%.1f ms", $0) },
                    level: s.decodeMs.map { $0 > 16 ? 2 : $0 > 8 ? 1 : 0 } ?? 0)
                if let failed = s.framesFailed { row("Frames Failed", failed.formatted()) }
                if let dropped = s.framesDropped { row("Frames Dropped", dropped.formatted()) }
                if let audio = s.audio { row("Audio", audio) }
            }
            group("Input") {
                row("Status", player.inputStats.version.map { _ in player.inputStats.rejected > 0 ? "\(player.inputStats.rejected) refused" : "Connected" } ?? "Waiting")
                if KumoriLink.shared.status == .connected {
                    row("Kumori Link", KumoriLink.shared.roundTripMs.map { String(format: "%.1f ms", $0) } ?? "Connected")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(width: 400, alignment: .leading)
        .tvLiquidGlass(radius: 28)
    }

    /// "12 (0.04%)": the count first, the share after it.
    private var packetsLost: String? {
        switch (s.packetsLost, s.lossPct) {
        case let (count?, pct?): return "\(count.formatted()) (\(String(format: "%.2f", pct))%)"
        case let (count?, nil): return count.formatted()
        case let (nil, pct?): return String(format: "%.2f%%", pct)
        default: return nil
        }
    }

    private func group<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 15, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(TVColor.tertiary)
            VStack(alignment: .leading, spacing: 3) { rows() }
        }
    }

    private func row(_ name: String, _ text: String?, level: Int = 0) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(TVColor.secondary)
            Spacer(minLength: 16)
            Text(text ?? "\u{2014}")
                .foregroundStyle(Self.ink(level))
                .lineLimit(1)
        }
        .font(Self.rowFont.monospacedDigit())
    }

    /// The detailed panel's row size: small enough that all four groups fit a 1080-line screen.
    private static let rowFont = Font.system(size: 19)

    private var latencyLevel: Int { s.rttMs.map { $0 > 80 ? 2 : $0 > 40 ? 1 : 0 } ?? 0 }
    private var lossLevel: Int { s.lossPct.map { $0 > 2 ? 2 : $0 > 0.5 ? 1 : 0 } ?? 0 }

    private static func ink(_ level: Int) -> Color {
        level == 2 ? TVColor.danger : level == 1 ? Color(red: 1, green: 0.78, blue: 0.3) : TVColor.primary
    }

    /// The codec the stream negotiated, by its common name.
    static func codecName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw.uppercased() {
        case "H265", "HEVC": return "HEVC (H.265)"
        case "H264", "AVC": return "H.264"
        case "AV1": return "AV1"
        default: return raw
        }
    }

    /// 1440 → "1440p", 2160 → "4K".
    private static func lines(_ height: Int) -> String {
        Resolution.allCases.min { abs($0.height - height) < abs($1.height - height) }?.label ?? "\(height)p"
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
/// (Resume has focus first); on the right, the stream's settings, each a button of glass. Back
/// closes it. A new resolution is chosen first and applied with one press, so the stream
/// reconnects once.
struct StreamMenu: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel
    @Environment(\.tvReduceTransparency) private var opaque
    @State private var confirmEnd = false
    @State private var typing = false
    @State private var staged: StreamMode?
    /// Drives the menu's arrival: the game frosts over, then the glass comes into focus.
    @State private var shown = false
    @FocusState private var focus: String?

    var body: some View {
        let active = player.playing ?? settings.mode
        let chosen = staged ?? active
        ZStack {
            veil
            // Both columns sized to what they hold, tops level, the pair centred on the
            // screen, so there is no empty glass and no slab of nothing under the buttons.
            // Centred on each other, so the settings panel sits on the screen's middle line
            // rather than hanging from the top of the game column.
            HStack(alignment: .center, spacing: 80) {
                gameColumn
                    .frame(width: 600, alignment: .leading)
                    .focusSection()
                    .modifier(GlassReveal(shown: shown, delay: 0.04))
                streamPanel(active: active, chosen: chosen)
                    .focusSection()
                    .modifier(GlassReveal(shown: shown, delay: 0.1))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { shown = true }
        .defaultFocus($focus, "resume")
        .task {
            // The controller hands the remote to this menu in the same moment it appears, so
            // the focus engine may not take Resume straight away. With nothing focused, Back
            // would leave the app. Ask until something in the menu has focus.
            for wait in [30, 150, 400] {
                try? await Task.sleep(for: .milliseconds(wait))
                if Task.isCancelled || focus != nil || confirmEnd || typing { return }
                focus = "resume"
            }
        }
        .onBack { player.menuOpen = false }
        .endSessionConfirmation(
            isPresented: $confirmEnd, title: player.game?.title ?? "this game",
            onCancel: { focus = "end" },
            onEnd: { player.quit() }
        )
        .fullScreenCover(isPresented: $typing, onDismiss: { focus = "type" }) {
            StreamKeyboard { typing = false }
                .presentationBackground(.clear)
        }
        // `.contain` first, so the identifier names the menu and doesn't replace the
        // identifiers of the buttons inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stream-menu")
    }

    /// The paused game behind frosted glass, darker at the bottom.
    private var veil: some View {
        // The game frosts over first: the glass fades up over the moving picture, so the
        // blur itself arrives rather than a flat dim.
        ZStack {
            if opaque {
                Color.black.opacity(0.86)
            } else {
                Rectangle().fill(.ultraThinMaterial)
                // Lighter than before, so the glass panel has the game's colour to bend.
                LinearGradient(colors: [.black.opacity(0.22), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .opacity(shown ? 1 : 0)
        .animation(.easeOut(duration: 0.32), value: shown)
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
            StreamTimeCard()
                .padding(.top, 28)

            VStack(spacing: 14) {
                Button { player.menuOpen = false } label: { Label("Resume", systemImage: "play.fill") }
                    .focused($focus, equals: "resume")
                    .accessibilityIdentifier("menu-resume")
                Button { player.leave() } label: { Label("Leave Game Running", systemImage: "rectangle.portrait.and.arrow.right") }
                    .focused($focus, equals: "leave")
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

    /// "Playing for 45 min". The picture and codec are in the stats.
    private var statusLine: String? {
        player.playingFor.map { "Playing for \(Self.duration($0))" }
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
                        .focused($focus, equals: "res-\(r.rawValue)")
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
                        .focused($focus, equals: "fps-\(fps)")
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
                    .focused($focus, equals: "apply")
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
                // Four tiles in a 2 × 2 grid, each with its icon, name and current value,
                // instead of a stack of look-alike bars.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    Button { settings.cycleStats() } label: {
                        optionTile("Stats", "chart.bar.xaxis", value: settings.statsLabel)
                    }
                    .accessibilityValue(settings.statsLabel)
                    .focused($focus, equals: "stats")
                    .accessibilityIdentifier("menu-stats")
                    Button { player.muted.toggle() } label: {
                        optionTile("Sound", player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", value: player.muted ? "Off" : "On")
                    }
                    .accessibilityValue(player.muted ? "Off" : "On")
                    .focused($focus, equals: "sound")
                    .accessibilityIdentifier("menu-sound")
                    Button { typing = true } label: {
                        optionTile("Type in the Game", "keyboard", value: "Keyboard")
                    }
                    .focused($focus, equals: "type")
                    .accessibilityIdentifier("menu-type")
                    Button { player.refreshPicture() } label: {
                        optionTile("Refresh Picture", "sparkles.tv", value: "New Frame")
                    }
                    .focused($focus, equals: "refresh")
                    .accessibilityIdentifier("menu-refresh")
                }
                .buttonStyle(TVActionStyle(height: 132))
            }
        }
        // The buttons float on their own, each a drop of glass over the frosted game, the
        // same as Stream Settings on a game's page. A glass panel under glass buttons only
        // clouded both into flat grey.
        .padding(48)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.uppercased())
                .font(TVType.detail.weight(.semibold))
                .tracking(1.6)
                .foregroundStyle(TVColor.tertiary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// An option as a tile: the icon at the top, the name, and what it is set to now.
    private func optionTile(_ title: String, _ icon: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .semibold))
                .frame(height: 36, alignment: .leading)
                .accessibilityHidden(true)
            Spacer(minLength: 14)
            Text(title)
                .font(TVType.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(TVType.detail)
                .opacity(0.62)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// The in-game menu's clock: play time left on the membership, counting down while the
/// game runs, and when the idle timer would end the session.
private struct StreamTimeCard: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(alignment: .top, spacing: 0) {
                cell("Time Left", player.timeLeft?.label ?? "Unavailable",
                     note: player.timeLeft?.unlimited == true ? "On your plan" : "This month",
                     low: (player.timeLeft.map { !$0.unlimited && $0.seconds < 3600 }) ?? false)
                Rectangle()
                    .fill(TVColor.primary.opacity(0.14))
                    .frame(width: 1)
                    .padding(.vertical, 6)
                cell("Idle Timer", idleValue, note: idleNote, low: player.idleLeft != nil)
            }
            .padding(.vertical, 22)
            .frame(width: 600, alignment: .leading)
            .tvGlass(radius: 28)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("menu-time")
    }

    private var idleValue: String {
        guard settings.idleMinutes > 0 else { return "Off" }
        guard let left = player.idleSecondsLeft else { return IdleClock.label(settings.idleMinutes) }
        let m = Int(left.rounded(.up)) / 60
        return m >= 1 ? "\(m) min" : "Under a minute"
    }

    private var idleNote: String {
        settings.idleMinutes > 0 ? "Without input" : "Settings, Stream"
    }

    private func cell(_ title: String, _ value: String, note: String, low: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TVType.detail.weight(.semibold))
                .foregroundStyle(TVColor.tertiary)
            Text(value)
                .font(TVType.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(low ? Color(red: 1, green: 0.78, blue: 0.3) : TVColor.primary)
                .contentTransition(.numericText(countsDown: true))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(note)
                .font(TVType.detail)
                .foregroundStyle(TVColor.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
