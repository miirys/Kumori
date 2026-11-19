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
            switch player.phase {
            case .starting(let text), .connecting(let text):
                waiting(text, detail: nil).transition(.opacity)
            case .queued(let position):
                waiting("In the queue", detail: "Position \(position)").transition(.opacity)
            case .ended(let message, let error):
                ended(message, error: error).transition(.opacity.combined(with: .scale(scale: 1.03)))
            case .live, .none:
                EmptyView()
            }
            if player.phase == .live {
                if settings.showStats && !player.menuOpen { statsBar.transition(.opacity.combined(with: .offset(y: -16))) }
                if let notice = player.notice, !player.menuOpen { noticeBar(notice) }
                if player.menuOpen {
                    StreamMenu().transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: -80)),
                        removal: .opacity.combined(with: .offset(x: -50))
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

    private var phaseIndex: Int {
        switch player.phase {
        case .starting: return 0
        case .queued: return 1
        case .connecting(let step): return step.contains("video") || step.contains("Negotiating") ? 3 : 2
        default: return 3
        }
    }

    private func waiting(_ text: String, detail: String?) -> some View {
        ZStack {
            backdrop
            VStack(spacing: 30) {
                Spinner()
                VStack(spacing: 12) {
                    Text(player.game?.title ?? "").font(.kumori(52, .bold)).foregroundStyle(Palette.blush).multilineTextAlignment(.center)
                    Text(text).font(.kumori(28)).foregroundStyle(Palette.secondary)
                        .id(text)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity.combined(with: .offset(y: -14))))
                    if let detail {
                        Text(detail).font(.kumori(40, .bold)).foregroundStyle(Palette.pink).contentTransition(.numericText())
                    }
                }
                steps
                Button("Cancel") { player.cancel() }.buttonStyle(PillButtonStyle(icon: "xmark")).padding(.top, 8)
            }
            .padding(.horizontal, 80).padding(.vertical, 60)
            .glassCard(48)
            .frame(maxWidth: 1100)
            .animation(Motion.snappy, value: text)
            .animation(Motion.snappy, value: detail)
        }
        .onExitCommand { player.cancel() }
    }

    /// Four dots for the way to a picture: rig, queue, connection, video.
    private var steps: some View {
        HStack(spacing: 14) {
            ForEach(0..<4) { i in
                Capsule()
                    .fill(i <= phaseIndex ? Palette.pink : Palette.blush.opacity(0.18))
                    .frame(width: i == phaseIndex ? 56 : 16, height: 10)
            }
        }
        .animation(Motion.glide, value: phaseIndex)
    }

    private func ended(_ message: String, error: Bool) -> some View {
        ZStack {
            backdrop
            VStack(spacing: 24) {
                Image(systemName: error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(error ? Palette.pink : Palette.blush)
                Text(error ? "The stream stopped" : "Session over").font(.kumori(48, .bold)).foregroundStyle(Palette.blush)
                Text(message).font(.kumori(27)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).frame(maxWidth: 860)
                HStack(spacing: 22) {
                    if error { Button("Try again") { player.retry() }.buttonStyle(PillButtonStyle(prominent: true, icon: "arrow.clockwise")) }
                    Button("Close") { player.dismiss() }.buttonStyle(PillButtonStyle())
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 80).padding(.vertical, 60)
            .glassCard(48)
        }
        .onExitCommand { player.dismiss() }
    }

    private var backdrop: some View {
        ZStack {
            Aurora()
            KenBurns(url: player.game?.hero).opacity(0.38).blur(radius: 24)
            LinearGradient(colors: [.clear, Palette.deep.opacity(0.8)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
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
            player.inputStats.summary,
        ].compactMap { $0 }
        return Text(parts.joined(separator: "  ·  "))
            .font(.system(size: 20, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.blush)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .glass(Capsule(), tint: .black.opacity(0.3))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(40)
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "info.circle.fill").foregroundStyle(Palette.pink)
            Text(text)
        }
        .font(.kumori(24, .medium)).foregroundStyle(Palette.blush)
        .padding(.horizontal, 28).padding(.vertical, 16)
        .glass(Capsule(), tint: Palette.plum.opacity(0.5))
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 50)
        .transition(.opacity.combined(with: .offset(y: -30)).combined(with: .scale(scale: 0.94, anchor: .top)))
        .task(id: text) {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled, player.notice == text { player.notice = nil }
        }
    }
}

/// Artwork that drifts and zooms very slowly, for backdrops.
struct KenBurns: View {
    let url: String?
    @State private var moving = false

    var body: some View {
        Art(url: url, title: "")
            .scaleEffect(moving ? 1.12 : 1.0)
            .offset(x: moving ? -30 : 20, y: moving ? -12 : 8)
            .onAppear { withAnimation(.easeInOut(duration: 24).repeatForever(autoreverses: true)) { moving = true } }
            .clipped()
    }
}

/// The in-stream menu. Hold Menu on a controller, or press Back on the Siri Remote.
private struct StreamMenu: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel
    @State private var confirmEnd = false
    @FocusState private var onResume: Bool

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 18) {
                        Art(url: player.game?.boxArt ?? player.game?.banner, title: "")
                            .frame(width: 84, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(player.game?.title ?? "Game").font(.kumori(36, .bold)).foregroundStyle(Palette.blush).lineLimit(2)
                            if let t = player.playingFor {
                                Text("Playing for \(Self.duration(t))").font(.kumori(22)).foregroundStyle(Palette.secondary)
                            }
                        }
                    }
                    .reveal(0, dx: -30, dy: 0)

                    HStack(spacing: 16) {
                        Button("Resume") { player.menuOpen = false }.buttonStyle(PillButtonStyle(prominent: true, icon: "play.fill")).focused($onResume)
                        Button("Leave running") { player.leave() }.buttonStyle(PillButtonStyle(icon: "rectangle.portrait.and.arrow.right"))
                    }
                    .padding(.vertical, 14).reveal(1, dx: -30, dy: 0)

                    SectionTitle(text: "Resolution").padding(.leading, 6).reveal(2, dx: -30, dy: 0)
                    ModeScroller(chosen: settings.mode, active: player.playing ?? settings.mode, membership: app.membership) { player.changeMode($0) }
                        .reveal(3, dx: -30, dy: 0)

                    VStack(spacing: 4) {
                        Toggle(isOn: $settings.showStats) { MenuLabel(icon: "chart.bar.xaxis", text: "Stats") }
                        Toggle(isOn: Binding(get: { !player.muted }, set: { player.muted = !$0 })) { MenuLabel(icon: "speaker.wave.2.fill", text: "Sound") }
                        Button { player.refreshPicture() } label: { MenuLabel(icon: "sparkles.tv", text: "Refresh picture") }
                        Button {
                            if confirmEnd { player.quit() } else { withAnimation(Motion.snappy) { confirmEnd = true } }
                        } label: {
                            MenuLabel(icon: confirmEnd ? "exclamationmark.circle.fill" : "power", text: confirmEnd ? "Press again to end the session" : "End session")
                        }
                    }
                    .toggleStyle(GlassToggleStyle())
                    .buttonStyle(RowButtonStyle())
                    .padding(10)
                    .glassCard(32)
                    .padding(.top, 10)
                    .reveal(4, dx: -30, dy: 0)
                }
                .padding(50)
            }
            .scrollClipDisabled()
            .frame(width: 820)
            .background(alignment: .leading) {
                Rectangle().fill(.clear).glass(Rectangle(), tint: Palette.deep.opacity(0.55)).ignoresSafeArea()
            }
            Spacer()
        }
        .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing).ignoresSafeArea())
        .ignoresSafeArea()
        .onExitCommand { player.menuOpen = false }
        .onAppear { onResume = true }
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
            Image(systemName: icon).font(.system(size: 24, weight: .semibold)).frame(width: 34)
            Text(text)
        }
    }
}
