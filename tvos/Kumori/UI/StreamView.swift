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

/// Everything drawn over the video: progress, notices, stats and the menu.
struct StreamOverlay: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ZStack {
            if let phase = player.phase, phase != .live {
                StreamBackdrop(url: player.game?.hero ?? player.game?.banner).transition(.opacity)
            }
            switch player.phase {
            case .starting(let text), .connecting(let text):
                waiting(text, detail: nil).transition(.opacity)
            case .queued(let position):
                waiting("In the queue", detail: "\(position)").transition(.opacity)
            case .ended(let message, let error):
                ended(message, error: error).transition(.opacity.combined(with: .offset(y: 20)))
            case .live, .none:
                EmptyView()
            }
            if player.phase == .live {
                if settings.showStats && !player.menuOpen { statsBar.transition(.opacity.combined(with: .offset(y: -16))) }
                if let notice = player.notice, !player.menuOpen { noticeBar(notice) }
                if player.menuOpen {
                    StreamMenu().transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 120)),
                        removal: .opacity.combined(with: .offset(x: 80))
                    ))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.glide, value: player.menuOpen)
        .animation(Motion.fade, value: player.phase)
        .animation(Motion.snappy, value: player.notice)
        .animation(Motion.snappy, value: settings.showStats)
    }

    /// How far along the way to a picture: rig, queue, connection, video.
    private var progress: CGFloat {
        switch player.phase {
        case .starting: return 0.06
        case .queued: return 0.3
        case .connecting(let step): return step.contains("video") || step.contains("Negotiating") ? 0.8 : 0.5
        default: return 1
        }
    }

    private func waiting(_ text: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text(player.game?.title ?? "")
                .font(.kumori(76, .bold)).foregroundStyle(Palette.text)
                .lineLimit(2).minimumScaleFactor(0.7)
                .frame(maxWidth: 1200, alignment: .leading)
                .reveal(0)
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(text)
                    .id(text)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity.combined(with: .offset(y: -12))))
                if let detail {
                    Text(detail).font(.kumori(30, .bold)).foregroundStyle(Palette.text).contentTransition(.numericText())
                }
            }
            .font(.kumori(30)).foregroundStyle(Palette.secondary)
            .padding(.top, 16)
            .reveal(1)
            // A slim bar that fills as each step is reached, with light running along it.
            ProgressLine(value: progress)
                .frame(width: 560, height: 6)
                .padding(.top, 34)
                .reveal(2)
            Button("Cancel") { player.cancel() }
                .buttonStyle(PillButtonStyle(icon: "xmark"))
                .padding(.top, 50)
                .reveal(3)
        }
        .padding(.leading, Layout.inset)
        .padding(.bottom, 100)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .animation(Motion.snappy, value: text)
        .animation(Motion.snappy, value: detail)
        .onExitCommand { player.cancel() }
    }

    private func ended(_ message: String, error: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text(error ? "Couldn't play \(player.game?.title ?? "the game")" : "Session over")
                .font(.kumori(64, .bold)).foregroundStyle(Palette.text)
                .lineLimit(2).minimumScaleFactor(0.7)
                .frame(maxWidth: 1300, alignment: .leading)
                .reveal(0)
            Text(message)
                .font(.kumori(30)).foregroundStyle(Palette.secondary)
                .frame(maxWidth: 1100, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
                .reveal(1)
            HStack(spacing: 24) {
                if error { Button("Try again") { player.retry() }.buttonStyle(PillButtonStyle(prominent: true, icon: "arrow.clockwise")) }
                Button("Close") { player.dismiss() }.buttonStyle(PillButtonStyle(icon: "xmark"))
            }
            .padding(.top, 50)
            .reveal(2)
        }
        .padding(.leading, Layout.inset)
        .padding(.bottom, 100)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .onExitCommand { player.dismiss() }
    }

    private var statsBar: some View {
        let s = player.stats
        let parts = [
            s.width > 0 ? "\(s.width) × \(s.height)" : nil,
            s.fps.map { String(format: "%.0f fps", $0) },
            s.codec,
            s.bitrateMbps.map { String(format: "%.1f Mbps", $0) },
            s.rttMs.map { String(format: "%.0f ms", $0) },
            s.lossPct.map { String(format: "%.1f%% loss", $0) },
            s.decodeMs.map { String(format: "decode %.1f ms", $0) },
        ].compactMap { $0 }
        return Text(parts.joined(separator: "   "))
            .font(.system(size: 20, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 22).padding(.vertical, 12)
            .glass(Capsule(), tint: .black.opacity(0.4))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 60).padding(.top, 44)
    }

    private func noticeBar(_ text: String) -> some View {
        Text(text)
            .font(.kumori(25, .medium)).foregroundStyle(Palette.text)
            .padding(.horizontal, 30).padding(.vertical, 16)
            .glass(Capsule(), tint: .black.opacity(0.4))
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 50)
            .transition(.opacity.combined(with: .offset(y: -30)).combined(with: .scale(scale: 0.96, anchor: .top)))
            .task(id: text) {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if !Task.isCancelled, player.notice == text { player.notice = nil }
            }
    }
}

/// The game's art behind the waiting and ended screens, drifting slowly under a dark veil.
private struct StreamBackdrop: View {
    let url: String?

    var body: some View {
        ZStack {
            Color.black
            KenBurns(url: url).opacity(0.55)
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

/// A thin track that fills to `value`, with a soft light sweeping along the filled part.
private struct ProgressLine: View {
    /// The step reached so far, from 0 to 1. The bar itself moves the same way the whole
    /// time: a bright segment glides across the full track and back, easing at each end.
    let value: CGFloat

    var body: some View {
        TimelineView(.animation) { ctx in
            let period = 1.6
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period * 2) / period
            // There and back, eased so it slows at the ends.
            let x = t < 1 ? t : 2 - t
            let eased = CGFloat(x * x * (3 - 2 * x))
            GeometryReader { geo in
                let w = geo.size.width
                let seg = w * 0.32
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule().fill(Color.white).frame(width: seg).offset(x: (w - seg) * eased)
                }
                .clipShape(Capsule())
            }
        }
    }
}

/// The in-stream menu, on glass at the right. Hold Menu on a controller, or press Back on
/// the Siri Remote. A new resolution is asked for when the menu closes.
private struct StreamMenu: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel
    @State private var confirmEnd = false
    @State private var mode: StreamMode?
    @FocusState private var onResume: Bool

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(spacing: 22) {
                        Art(url: player.game?.boxArt ?? player.game?.banner, title: "", width: 240)
                            .frame(width: 90, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(player.game?.title ?? "Game").font(.kumori(34, .bold)).foregroundStyle(Palette.text).lineLimit(2)
                            if let t = player.playingFor {
                                Text("Playing for \(Self.duration(t))").font(.kumori(23)).foregroundStyle(Palette.secondary)
                            }
                        }
                    }
                    .reveal(0, dx: 30, dy: 0)

                    VStack(spacing: 6) {
                        Button { close() } label: { MenuLabel(icon: "play.fill", text: "Resume") }.focused($onResume)
                        ModeRow(selection: mode ?? player.playing ?? settings.mode, membership: app.membership) { mode = $0 }
                        ValueRow(label: "Stats", icon: "chart.bar.xaxis", options: [false, true], title: { $0 ? "On" : "Off" }, selection: settings.showStats) { settings.showStats = $0 }
                        ValueRow(label: "Sound", icon: "speaker.wave.2.fill", options: [true, false], title: { $0 ? "On" : "Off" }, selection: !player.muted) { player.muted = !$0 }
                        Button { player.refreshPicture() } label: { MenuLabel(icon: "sparkles.tv", text: "Refresh picture") }
                        Button { player.leave() } label: { MenuLabel(icon: "rectangle.portrait.and.arrow.right", text: "Leave it running") }
                        Button {
                            if confirmEnd { player.quit() } else { withAnimation(Motion.snappy) { confirmEnd = true } }
                        } label: {
                            MenuLabel(icon: confirmEnd ? "exclamationmark.circle.fill" : "power", text: confirmEnd ? "Press again to end" : "End session")
                        }
                    }
                    .buttonStyle(RowButtonStyle())
                    .padding(12)
                    .glassCard(34)
                    .reveal(1, dx: 30, dy: 0)
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 60)
            }
            .scrollClipDisabled()
            .frame(width: 860)
            .background {
                Rectangle().fill(.clear).glass(Rectangle(), tint: .black.opacity(0.5)).ignoresSafeArea()
            }
        }
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .leading, endPoint: .trailing).ignoresSafeArea())
        .ignoresSafeArea()
        .onExitCommand { close() }
        .onAppear { onResume = true }
    }

    private func close() {
        if let m = mode, m != (player.playing ?? settings.mode) {
            player.changeMode(m)
        } else {
            player.menuOpen = false
        }
    }

    private static func duration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return m < 60 ? "\(max(m, 1)) min" : "\(m / 60) h \(m % 60) min"
    }
}

private struct MenuLabel: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 24, weight: .semibold)).frame(width: 36)
            Text(text)
        }
    }
}
