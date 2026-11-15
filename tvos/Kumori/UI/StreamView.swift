import Combine
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
    private let videoView = LKRTCMTLVideoView()
    private let overlay: UIHostingController<AnyView>
    private var track: LKRTCVideoTrack?
    private var watching = Set<AnyCancellable>()

    init(player: Player, settings: Settings, app: AppModel) {
        self.player = player
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
            self?.controllerUserInteractionEnabled = phase != .live || menu
        }.store(in: &watching)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        show(nil)
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
                waiting(text, detail: nil)
            case .queued(let position):
                waiting("In the queue", detail: "Position \(position)")
            case .ended(let message, let error):
                ended(message, error: error)
            case .live, .none:
                EmptyView()
            }
            if player.phase == .live {
                if settings.showStats && !player.menuOpen { statsBar }
                if let notice = player.notice, !player.menuOpen { noticeBar(notice) }
                if player.menuOpen { StreamMenu().transition(.opacity.combined(with: .offset(x: -40))) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.arrive, value: player.menuOpen)
        .animation(.easeInOut(duration: 0.3), value: player.phase)
        .animation(.easeInOut(duration: 0.3), value: player.notice)
    }

    private func waiting(_ text: String, detail: String?) -> some View {
        ZStack {
            backdrop
            VStack(spacing: 22) {
                ProgressView().scaleEffect(1.4)
                Text(player.game?.title ?? "").font(.kumori(44, .bold)).foregroundStyle(Palette.blush)
                Text(text).font(.kumori(27)).foregroundStyle(Palette.secondary).id(text).transition(.opacity)
                if let detail { Text(detail).font(.kumori(34, .semibold)).foregroundStyle(Palette.pink) }
                Button("Cancel") { player.quit() }.buttonStyle(PillButtonStyle()).padding(.top, 20)
            }
            .animation(.easeInOut(duration: 0.25), value: text)
        }
        .onExitCommand { player.quit() }
    }

    private func ended(_ message: String, error: Bool) -> some View {
        ZStack {
            backdrop
            VStack(spacing: 22) {
                Text(error ? "The stream stopped" : "Session over").font(.kumori(44, .bold)).foregroundStyle(Palette.blush)
                Text(message).font(.kumori(27)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).frame(maxWidth: 900)
                HStack(spacing: 20) {
                    if error { Button("Try again") { player.retry() }.buttonStyle(PillButtonStyle(prominent: true)) }
                    Button("Close") { player.dismiss() }.buttonStyle(PillButtonStyle())
                }
                .padding(.top, 20)
            }
        }
        .onExitCommand { player.dismiss() }
    }

    private var backdrop: some View {
        ZStack {
            Palette.night
            Art(url: player.game?.hero, title: "").opacity(0.25).blur(radius: 30)
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
            s.decodeMs.map { String(format: "decode %.1f ms", $0) },
        ].compactMap { $0 }
        return Text(parts.joined(separator: "  ·  "))
            .font(.system(size: 20, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.blush)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(40)
    }

    private func noticeBar(_ text: String) -> some View {
        Text(text)
            .font(.kumori(24, .medium)).foregroundStyle(Palette.blush)
            .padding(.horizontal, 26).padding(.vertical, 14)
            .background(Palette.plum.opacity(0.92), in: Capsule())
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 50)
            .transition(.opacity.combined(with: .offset(y: -20)))
            .task(id: text) {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if !Task.isCancelled, player.notice == text { player.notice = nil }
            }
    }
}

/// The in-stream menu. Hold Menu on a controller, or press Back on the Siri Remote.
private struct StreamMenu: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel
    @State private var confirmEnd = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(player.game?.title ?? "Game").font(.kumori(40, .bold)).foregroundStyle(Palette.blush).reveal(0, dx: -24, dy: 0)
                    HStack(spacing: 16) {
                        Button("Resume") { player.menuOpen = false }.buttonStyle(PillButtonStyle(prominent: true))
                        Button("Leave running") { player.leave() }.buttonStyle(PillButtonStyle())
                    }
                    .padding(.vertical, 14).reveal(1, dx: -24, dy: 0)

                    Text("RESOLUTION AND FRAME RATE").font(.kumori(19, .bold)).kerning(1.6).foregroundStyle(Palette.tertiary).reveal(2, dx: -24, dy: 0)
                    ModePicker(chosen: settings.mode, active: player.playing ?? settings.mode, membership: app.membership) { player.changeMode($0) }
                        .padding(.vertical, 8).reveal(3, dx: -24, dy: 0)

                    Group {
                        Button { settings.showStats.toggle() } label: { row("Stats", settings.showStats ? "On" : "Off") }
                        Button { player.muted.toggle() } label: { row("Sound", player.muted ? "Muted" : "On") }
                        Button { player.refreshPicture() } label: { row("Refresh picture", "") }
                        Button {
                            if confirmEnd { player.quit() } else { confirmEnd = true }
                        } label: { row(confirmEnd ? "Press again to end" : "End session", "") }
                    }
                    .buttonStyle(RowButtonStyle())
                    .reveal(4, dx: -24, dy: 0)
                }
                .padding(50)
            }
            .frame(width: 760)
            .background(Palette.night.opacity(0.94))
            Spacer()
        }
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing))
        .ignoresSafeArea()
        .onExitCommand { player.menuOpen = false }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).opacity(0.7)
        }
    }
}
