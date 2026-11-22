import SwiftUI

// Settings (U07–U09), laid out for the whole screen the way the best TV apps do it: the
// categories down the left, and the chosen category's page on a glass pane to the right.
// Moving along the categories shows each page at once; Select or Right goes into it, Back
// comes out. A choice opens its own page inside the pane, sliding in from the right.

/// Every page Settings can show. Fixtures open a page directly by passing a path.
enum SettingsRoute: Hashable {
    case stream, dlss, controllers, account, about, debug
    case mode, fps, codec, bitrate, region
    case dlssModel, dlssQuality, dlssRays, dlssFrames
    case launchLog
}

/// What Settings moves focus to by itself: a category on the left, or a row that opens a page.
enum SettingsFocus: Hashable {
    case rail(SettingsRoute)
    case row(SettingsRoute)
    /// A choice on a choice page, by position.
    case choice(Int)
}

struct SettingsView: View {
    /// The category whose page is on the pane.
    @State private var category: SettingsRoute
    /// Pages opened inside the category, deepest last.
    @State private var path: [SettingsRoute]
    @State private var motion = PaneMotion.category(down: true)
    /// While a page slides in or out, focus briefly lands wherever the engine puts it; that
    /// mustn't count as choosing a category.
    @State private var settling = false
    @State private var startInPane: Bool
    @FocusState private var focus: SettingsFocus?
    @Namespace private var pane
    /// The soft fill behind the category on show glides from one category to the next.
    @Namespace private var railGlide
    @Environment(\.resetFocus) private var resetFocus
    @Environment(\.tvReduceMotion) private var reduced
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var controllers: ControllerCenter
    @ObservedObject private var link = KumoriLink.shared

    init(path: [SettingsRoute] = []) {
        _category = State(initialValue: path.first ?? .stream)
        _path = State(initialValue: Array(path.dropFirst()))
        _startInPane = State(initialValue: !path.isEmpty)
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsMetrics.paneGap) {
            rail
                .frame(width: SettingsMetrics.railWidth, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .top)
                .focusSection()
                // Left from the pane lands on the category on show.
                .defaultFocus($focus, .rail(category), priority: .userInitiated)

            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.paneRadius, style: .continuous))
                .tvGlass(radius: SettingsMetrics.paneRadius, tint: SettingsMetrics.glassTint)
                .focusScope(pane)
                .focusSection()
                .onBack(perform: back)
        }
        .padding(.top, SettingsMetrics.top)
        // Down from the tab bar lands on the category on show, never somewhere in the pane.
        .defaultFocus($focus, .rail(category), priority: .userInitiated)
        .environment(\.settingsNav, SettingsNav(open: open, focus: $focus, pane: pane))
        .onChange(of: focus) { _, now in
            guard case .rail(let route)? = now, route != category, !settling else { return }
            show(category: route)
        }
        .task {
            // Fixtures that open a page start with focus on it.
            guard startInPane else { return }
            startInPane = false
            for wait in [300, 300, 400] {
                try? await Task.sleep(for: .milliseconds(wait))
                if case .rail? = focus {} else if focus != nil { return }
                enterPane()
            }
        }
    }

    /// The categories on their own pane of glass, in three groups: what the stream looks
    /// like, what plays it, and the app. Each shows what it's set to under its name.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            railGroup("Streaming", first: true) {
                link(.stream, "Stream", "play.tv", value: streamSummary)
                link(.dlss, "DLSS", "sparkles", value: dlssSummary)
            }
            railGroup("Input") {
                link(.controllers, "Controllers", "gamecontroller", value: controllerSummary)
            }
            railGroup("General") {
                link(.account, "Account", "person.crop.circle", value: app.profile?.name)
                link(.about, "About", "info.circle", value: "Version \(BuildInfo.current.version)")
                link(.debug, "Debug", "ladybug", value: nil)
            }
        }
        .padding(SettingsMetrics.railInset)
        .padding(.bottom, 4)
        // As tall as its categories, so the glass doesn't run on empty below them.
        .tvGlass(radius: SettingsMetrics.paneRadius, tint: SettingsMetrics.glassTint)
    }

    private func railGroup<Links: View>(_ title: String, first: Bool = false,
                                        @ViewBuilder links: () -> Links) -> some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.railGroupGap) {
            Text(title)
                .font(TVType.caption.weight(.semibold))
                .foregroundStyle(TVColor.tertiary)
                .padding(.leading, SettingsMetrics.railItemInset)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            links()
        }
        .padding(.top, first ? 8 : SettingsMetrics.railGroupBreak)
    }

    private var current: SettingsRoute { path.last ?? category }

    private var paneContent: some View {
        ZStack(alignment: .topLeading) {
            SettingsDestination(route: current)
                .id(PaneKey(category: category, path: path))
                .transition(motion.transition(reduced: reduced))
        }
    }

    private var dlssSummary: String {
        settings.dlssModel == .game && settings.dlssQuality == .game && !settings.dlssRays && settings.dlssFrames == .game
            ? "Game\u{2019}s choice" : "Custom"
    }

    private var streamSummary: String {
        settings.mode.label
    }

    private var controllerSummary: String {
        let names = (link.status == .connected ? Array(repeating: "Kumori Link", count: link.controllers) : [])
            + controllers.pads.filter { !$0.isRemote }.map(\.name)
        switch names.count {
        case 0: return "None connected"
        case 1: return names[0]
        default: return "\(names.count) connected"
        }
    }

    /// A category, with what its page is set to under the name.
    private func link(_ route: SettingsRoute, _ title: String, _ icon: String, value: String?) -> some View {
        Button { enterPane() } label: { SettingsRailItem(title: title, icon: icon, value: value) }
            .buttonStyle(SettingsRailStyle(selected: category == route, glide: railGlide))
            .accessibilityAddTraits(category == route ? .isSelected : [])
            .accessibilityValue(value ?? "")
            .focused($focus, equals: .rail(route))
            .accessibilityIdentifier("settings-\(route)")
    }

    // MARK: Moving around

    private var paneAnimation: Animation { reduced ? TVMotion.reducedFade : TVMotion.settingsPage }

    /// Focus moved to another category: its page replaces the pane's, rising a little from
    /// the side focus came from.
    private func show(category route: SettingsRoute) {
        change(.category(down: route.railOrder >= category.railOrder)) {
            category = route
            path = []
        }
    }

    /// Select (or Right) on a category: into its page, on the first row that opens something.
    private func enterPane() {
        if let first = Self.firstRow[current] {
            focus = .row(first)
        } else {
            resetFocus(in: pane)
        }
    }

    private func open(_ route: SettingsRoute) {
        // The choice page puts focus on the choice in use itself, once it is on screen.
        change(.push) { path.append(route) }
        settle {}
    }

    /// Back inside the pane: out of a choice page to the row that opened it, or from a
    /// category's page to the category.
    private func back() {
        guard let last = path.last else {
            focus = .rail(category)
            return
        }
        change(.pop) { path.removeLast() }
        settle { focus = .row(last) }
    }

    /// Sets the motion first, so the page leaving takes the right exit too, then changes.
    private func change(_ m: PaneMotion, _ update: @escaping () -> Void) {
        motion = m
        DispatchQueue.main.async {
            withAnimation(paneAnimation, update)
        }
    }

    /// Holds category changes off while a page slides, and puts focus where it belongs once
    /// the new page is there.
    private func settle(_ land: @escaping () -> Void) {
        settling = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            land()
            try? await Task.sleep(for: .milliseconds(140))
            land()
            try? await Task.sleep(for: .milliseconds(400))
            settling = false
        }
    }

    /// Where Select on a category puts focus.
    private static let firstRow: [SettingsRoute: SettingsRoute] = [.stream: .mode, .dlss: .dlssModel, .debug: .debug]
}

extension SettingsRoute {
    /// Where a category sits on the rail, top first.
    fileprivate var railOrder: Int {
        switch self {
        case .stream: return 0
        case .dlss: return 1
        case .controllers: return 2
        case .account: return 3
        case .about: return 4
        case .debug: return 5
        default: return 2
        }
    }
}

private struct PaneKey: Hashable {
    let category: SettingsRoute
    let path: [SettingsRoute]
}

/// How the pane's page changes.
private enum PaneMotion {
    case category(down: Bool)
    case push
    case pop

    /// The page coming in comes into focus (blur clearing, a breath of scale) while the one
    /// leaving softens and goes. Its rows then arrive one after another (`SettingsReveal`).
    func transition(reduced: Bool) -> AnyTransition {
        if reduced { return .opacity }
        switch self {
        case .category(let down):
            return .asymmetric(
                insertion: .pane(y: down ? 22 : -22, scale: 0.985, blur: 18),
                removal: .pane(y: down ? -14 : 14, scale: 1, blur: 12).animation(.easeIn(duration: 0.26))
            )
        case .push:
            return .asymmetric(insertion: .pane(x: 96, scale: 0.99, blur: 14),
                               removal: .pane(x: -72, scale: 0.98, blur: 10))
        case .pop:
            return .asymmetric(insertion: .pane(x: -96, scale: 0.99, blur: 14),
                               removal: .pane(x: 72, scale: 0.98, blur: 10))
        }
    }
}

private struct PaneState: ViewModifier {
    let opacity: Double
    let x: CGFloat
    let y: CGFloat
    let scale: CGFloat
    let blur: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .scaleEffect(scale, anchor: .top)
            .offset(x: x, y: y)
            .opacity(opacity)
    }
}

private extension AnyTransition {
    static func pane(x: CGFloat = 0, y: CGFloat = 0, scale: CGFloat, blur: CGFloat) -> AnyTransition {
        .modifier(active: PaneState(opacity: 0, x: x, y: y, scale: scale, blur: blur),
                  identity: PaneState(opacity: 1, x: 0, y: 0, scale: 1, blur: 0))
    }
}

/// A row arriving on a page that has just come in: a moment after the one above it, it
/// fades up out of a soft blur. Ten rows in, the rest arrive together.
private struct SettingsReveal: ViewModifier {
    let order: Int
    @Environment(\.tvReduceMotion) private var reduced
    @State private var shown = false

    func body(content: Content) -> some View {
        let on = shown || reduced
        content
            // Never quite invisible, so focus can land on a row while it arrives.
            .opacity(on ? 1 : 0.02)
            .blur(radius: on ? 0 : 8)
            .offset(y: on ? 0 : 14)
            .onAppear {
                guard !reduced, !shown else { return }
                let delay = 0.1 + Double(min(order, 10)) * 0.045
                withAnimation(TVMotion.settingsRow.delay(delay)) { shown = true }
            }
    }
}

extension View {
    fileprivate func settingsReveal(_ order: Int) -> some View { modifier(SettingsReveal(order: order)) }
}

/// What a page inside the pane needs from Settings: a way to open another page, and focus.
struct SettingsNav {
    let open: (SettingsRoute) -> Void
    let focus: FocusState<SettingsFocus?>.Binding
    let pane: Namespace.ID
}

private struct SettingsNavKey: EnvironmentKey {
    static let defaultValue: SettingsNav? = nil
}

extension EnvironmentValues {
    var settingsNav: SettingsNav? {
        get { self[SettingsNavKey.self] }
        set { self[SettingsNavKey.self] = newValue }
    }
}

// MARK: Rail

/// One category on the left: its symbol, its name, and what it's set to.
private struct SettingsRailItem: View {
    let title: String
    let icon: String
    let value: String?

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: icon)
                .font(TVType.callout.weight(.semibold))
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                if let value, !value.isEmpty {
                    Text(value)
                        .font(TVType.detail.weight(.medium))
                        .opacity(0.62)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// How a category moves: quiet at rest, a soft fill while its page is on show (so it's
/// clear which page focus is in), and the white platter under focus, on the same spring as
/// every other row.
private struct SettingsRailStyle: ButtonStyle {
    let selected: Bool
    let glide: Namespace.ID

    func makeBody(configuration: Configuration) -> some View {
        RailBody(configuration: configuration, selected: selected, glide: glide)
    }

    private struct RailBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let glide: Namespace.ID
        @Environment(\.isFocused) private var focused
        @Environment(\.tvReduceMotion) private var reduced

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: SettingsMetrics.railRadius, style: .continuous)
            let lifted = focused && !reduced
            configuration.label
                .font(TVType.body.weight(focused || selected ? .semibold : .regular))
                .foregroundStyle(focused ? TVColor.ink : (selected ? TVColor.primary : TVColor.secondary))
                .padding(.horizontal, SettingsMetrics.railItemInset)
                .frame(maxWidth: .infinity, minHeight: SettingsMetrics.railRowHeight, alignment: .leading)
                .background {
                    ZStack {
                        // One fill, handed from category to category, so it slides down
                        // the rail under focus instead of blinking out and in.
                        if selected {
                            shape.fill(Color.white.opacity(0.12))
                                .matchedGeometryEffect(id: "selection", in: glide)
                        }
                        shape.fill(TVColor.platter)
                            .opacity(focused ? 1 : 0)
                            .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: lifted ? 26 : 0, y: lifted ? 14 : 0)
                    }
                }
                .contentShape(shape)
                .scaleEffect(lifted ? (configuration.isPressed ? 1.0 : 1.05) : 1)
                .zIndex(focused ? 1 : 0)
                .animation(reduced ? TVMotion.reducedFade : TVMotion.lift, value: focused)
                .animation(reduced ? nil : .spring(duration: 0.2, bounce: 0), value: configuration.isPressed)
        }
    }
}

// MARK: Layout

/// One Settings page, as it sits on the pane: its name and a line about it at the top, then
/// its groups. Every text edge (title, group headers, row titles, notes) lines up; a focused
/// row's platter reaches past that edge on both sides, as the system's rows do.
struct SettingsPage<Content: View>: View {
    /// The page's SF Symbol. Pages still name one, but it isn't drawn.
    let symbol: String?
    let title: String
    var summary: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(tvOS 18.0, *) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SettingsMetrics.groupGap) {
                    header.settingsReveal(0)
                    Group(sections: content()) { sections in
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            // Each group starts its rows a beat after the previous group's
                            // first row, so a long page doesn't wait on its first group.
                            SettingsGroupView(section: section, firstOrder: 1 + index * 2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsMetrics.paneInsetX)
                .padding(.top, SettingsMetrics.paneInsetTop)
                .padding(.bottom, SettingsMetrics.paneInsetTop)
            }
            .scrollClipDisabled()
            .buttonStyle(SettingsRowStyle())
        } else {
            List {
                header.listRowBackground(Color.clear)
                content()
            }
            .buttonStyle(SettingsRowStyle())
        }
    }

    @ViewBuilder private var header: some View {
        if !title.isEmpty || summary != nil {
            VStack(alignment: .leading, spacing: 12) {
                if !title.isEmpty {
                    Text(title)
                        .font(TVType.section)
                        .foregroundStyle(TVColor.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                }
                if let summary {
                    Text(summary)
                        .font(TVType.callout)
                        .foregroundStyle(TVColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The measurements Settings shares, at the 1920 × 1080 point stage. Inside the safe area
/// the categories' glass takes 460 points, then a gap, then the pane's glass fills the rest
/// (1260 points), with its text column 64 points in from each side.
enum SettingsMetrics {
    /// The categories' pane, glass included.
    static let railWidth: CGFloat = 460
    /// From the categories' glass to the platters inside it.
    static let railInset: CGFloat = 20
    /// From a platter's edge to its symbol.
    static let railItemInset: CGFloat = 22
    static let railRowHeight: CGFloat = 84
    /// A category's platter, concentric with the glass around it.
    static let railRadius: CGFloat = 24
    /// Between the categories of one group.
    static let railGroupGap: CGFloat = 6
    /// Above every group after the first.
    static let railGroupBreak: CGFloat = 30
    /// How much graphite lies over the blur on Settings' glass, so the light behind shows.
    static let glassTint: Double = 0.58
    static let paneGap: CGFloat = 40
    static let paneRadius: CGFloat = 44
    static let paneInsetX: CGFloat = 64
    static let paneInsetTop: CGFloat = 52
    /// How far a focused row's platter reaches past the text edge on each side.
    static let platterOutset: CGFloat = 28
    static let rowHeight: CGFloat = 80
    static let rowGap: CGFloat = 4
    static let groupGap: CGFloat = 44
    /// Below the tab bar.
    static let top: CGFloat = 24
    static let radius: CGFloat = 18
}

/// One group of a page: its header, its rows and its note, all on the column's text edge.
@available(tvOS 18.0, *)
private struct SettingsGroupView: View {
    let section: SectionConfiguration
    var firstOrder = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !section.header.isEmpty {
                ForEach(section.header) { $0 }
                    .font(TVType.caption.weight(.semibold))
                    .foregroundStyle(TVColor.tertiary)
                    .textCase(nil)
                    .padding(.bottom, 12)
                    .settingsReveal(firstOrder)
            }
            VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
                ForEach(Array(section.content.enumerated()), id: \.element.id) { index, row in
                    row
                        .font(TVType.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .settingsReveal(firstOrder + index)
                }
            }
            if !section.footer.isEmpty {
                ForEach(section.footer) { $0 }
                    .font(TVType.detail)
                    .foregroundStyle(TVColor.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How every Settings row moves, the way a focused row moves in tvOS Settings. The row's
/// text stays on the column's text edge. Under focus, a light platter lifts out past that
/// edge on both sides with a soft shadow under it, the whole row grows a little, and the
/// text turns dark with the platter. The row losing focus settles back on the same spring,
/// so focus travels down a page as one continuous motion. A press pushes the row in.
struct SettingsRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsRowBody(configuration: configuration)
    }
}

private struct SettingsRowBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.tvReduceMotion) private var reduced

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.radius, style: .continuous)
        let lifted = focused && !reduced
        configuration.label
            .font(TVType.body.weight(focused ? .semibold : .regular))
            .foregroundStyle(focused ? TVColor.ink : TVColor.primary)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.rowHeight, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.platterOutset)
            .background {
                ZStack {
                    // At rest, a row is a faint band on the glass, so a page reads as a list.
                    shape.fill(Color.white.opacity(0.05))
                    shape.fill(TVColor.platter)
                        .opacity(focused ? 1 : 0)
                        .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: lifted ? 26 : 0, y: lifted ? 14 : 0)
                }
            }
            .contentShape(shape)
            .scaleEffect(lifted ? (configuration.isPressed ? 1.0 : 1.03) : 1)
            // The platter reaches past the text edge; the text stays on it.
            .padding(.horizontal, -SettingsMetrics.platterOutset)
            .zIndex(focused ? 1 : 0)
            .opacity(enabled ? 1 : 0.4)
            .animation(reduced ? TVMotion.reducedFade : TVMotion.lift, value: focused)
            .animation(reduced ? nil : .spring(duration: 0.2, bounce: 0), value: configuration.isPressed)
    }
}

extension View {
    /// Lets Settings move focus to this row, to put it back here after Back.
    func settingsFocus(_ target: SettingsFocus) -> some View {
        modifier(SettingsFocusModifier(target: target))
    }
}

private struct SettingsFocusModifier: ViewModifier {
    let target: SettingsFocus
    @Environment(\.settingsNav) private var nav

    func body(content: Content) -> some View {
        if let nav {
            content.focused(nav.focus, equals: target)
        } else {
            content
        }
    }
}

/// A list row: an optional symbol, a title, and the current value at the end.
struct SettingsRow: View {
    let title: String
    var icon: String?
    var value: String?
    var detail: String?
    /// For a row that opens another page.
    var chevron = false

    var body: some View {
        HStack(spacing: TVTokens.group) {
            if let icon {
                Image(systemName: icon).frame(width: 44).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let detail {
                    Text(detail).font(TVType.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: TVTokens.group)
            if let value {
                Text(value).foregroundStyle(.secondary).lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.forward")
                    .font(TVType.callout.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A setting that is on or off, as a row that says which, the way tvOS Settings does.
struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            SettingsRow(title: title, value: isOn ? "On" : "Off")
        }
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A row that shows a value and can't be selected.
private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TVTokens.group) {
            Text(title).foregroundStyle(TVColor.secondary)
            Spacer(minLength: TVTokens.group)
            Text(value).foregroundStyle(TVColor.primary).multilineTextAlignment(.trailing)
        }
        .font(TVType.body)
        .frame(minHeight: SettingsMetrics.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// A list of choices with a checkmark on the one in use. Choosing one keeps the list open,
/// so the person sees it took; Back returns to the row that opened it.
struct ChoiceList<Value: Hashable>: View {
    let symbol: String
    let title: String
    let options: [Value]
    let label: (Value) -> String
    /// A word or two at the end of a choice's row, such as "Software". Keep it short: it's a
    /// tag, not an explanation.
    var detail: (Value) -> String? = { _ in nil }
    /// Why a choice can't be used here, in a few words at the end of its row. Blocked
    /// choices can't be focused.
    var blocked: (Value) -> String? = { _ in nil }
    @Binding var selection: Value
    @Environment(\.settingsNav) private var nav

    var body: some View {
        SettingsPage(symbol: symbol, title: title) {
            Section {
                ForEach(Array(options.enumerated()), id: \.element) { index, option in
                    let reason = blocked(option)
                    Button {
                        selection = option
                    } label: {
                        HStack(spacing: TVTokens.medium) {
                            Text(label(option))
                            Spacer(minLength: TVTokens.group)
                            if let note = reason ?? detail(option) {
                                Text(note)
                                    .font(TVType.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .opacity(option == selection ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                    }
                    .disabled(reason != nil)
                    .accessibilityAddTraits(option == selection ? .isSelected : [])
                    .settingsFocus(.choice(index))
                }
            }
        }
        .task {
            // The choice in use has focus when the page opens. Asked a few times, because
            // the page is still sliding in and the focus engine may not take it at once.
            guard let nav, let target = landing else { return }
            for wait in [80, 160, 320, 400] {
                try? await Task.sleep(for: .milliseconds(wait))
                if case .choice? = nav.focus.wrappedValue { return }
                nav.focus.wrappedValue = .choice(target)
            }
        }
    }

    /// Where focus lands: the choice in use, or the first one that can be chosen.
    private var landing: Int? {
        options.firstIndex { $0 == selection && blocked($0) == nil }
            ?? options.firstIndex { blocked($0) == nil }
    }
}

// MARK: Pages

private struct SettingsDestination: View {
    let route: SettingsRoute
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @State private var signingOut = false

    var body: some View {
        switch route {
        case .stream: streamPage
        case .dlss: dlssPage
        case .controllers: ControllerStatusView()
        case .account: accountPage
        case .about: aboutPage
        case .mode:
            ChoiceList(
                symbol: "rectangle.on.rectangle", title: "Resolution",
                options: Resolution.allCases, label: { $0.label },
                detail: { r in
                    // One note at most: where the picture is shown smaller than asked.
                    if settings.mode.fps > 60, let fast = Capabilities.fastLines, r.height > (Int(fast.dropLast()) ?? 0) {
                        return "Shown at \(fast) 120 Hz"
                    }
                    let lines = Settings.nativeResolution.height
                    return lines < r.height ? "Shown at \(lines)p" : nil
                },
                // Judged at 60 fps; a faster rate that doesn't fit drops back to 60 below.
                blocked: { r in
                    let v = Capabilities.check(StreamMode(resolution: r, fps: 60), membership: app.membership)
                    return v.blocked ? v.note ?? "Unavailable" : nil
                },
                selection: Binding(
                    get: { settings.mode.resolution },
                    set: { r in
                        let wanted = StreamMode(resolution: r, fps: settings.mode.fps)
                        let fits = !Capabilities.check(wanted, membership: app.membership).blocked
                        settings.mode = fits ? wanted : StreamMode(resolution: r, fps: 60)
                    }
                )
            )
        case .fps:
            ChoiceList(
                symbol: "speedometer", title: "Frame Rate",
                options: Array(StreamMode.rates.reversed()), label: { "\($0) fps" },
                detail: { fps in
                    fps > 60 ? Capabilities.check(StreamMode(resolution: settings.mode.resolution, fps: fps), membership: app.membership).note : nil
                },
                blocked: { fps in
                    let v = Capabilities.check(StreamMode(resolution: settings.mode.resolution, fps: fps), membership: app.membership)
                    return v.blocked ? v.note ?? "Unavailable" : nil
                },
                selection: Binding(
                    get: { settings.mode.fps },
                    set: { settings.mode = StreamMode(resolution: settings.mode.resolution, fps: $0) }
                )
            )
        case .codec:
            ChoiceList(
                symbol: "film.stack", title: "Video Codec",
                options: CodecChoice.allCases, label: \.label,
                detail: { $0 == .av1 && !HardwareDecoders.av1Hardware ? "Software" : nil },
                selection: $settings.codec
            )
        case .bitrate:
            ChoiceList(
                symbol: "speedometer", title: "Bitrate",
                options: Settings.bitrates, label: { "\($0) Mbps" },
                selection: $settings.bitrateMbps
            )
        case .region:
            ChoiceList(
                symbol: "globe", title: "Server Location",
                options: [""] + app.regions.map(\.name), label: { $0.isEmpty ? "Automatic" : $0 },
                selection: $settings.region
            )
        case .dlssModel:
            ChoiceList(symbol: "cpu", title: "DLSS Model", options: DlssModel.allCases, label: \.label,
                       selection: $settings.dlssModel)
        case .dlssQuality:
            ChoiceList(symbol: "dial.medium", title: "DLSS Quality", options: DlssQuality.allCases, label: \.label,
                       selection: $settings.dlssQuality)
        case .dlssRays:
            ChoiceList(symbol: "light.max", title: "Ray Reconstruction", options: [false, true],
                       label: { $0 ? "Recommended model" : "Game\u{2019}s choice" },
                       detail: { $0 ? "Performance or Ultimate" : nil },
                       selection: $settings.dlssRays)
        case .dlssFrames:
            ChoiceList(symbol: "square.stack.3d.up", title: "Frame Generation", options: DlssFrames.allCases, label: \.label,
                       detail: { $0.multiplier > 0 ? "Ultimate, RTX 5080" : nil },
                       selection: $settings.dlssFrames)
        case .debug:
            DebugPage()
        case .launchLog:
            LaunchLogPage()
        }
    }

    /// How this page's rows open their pages (set by `SettingsView`).
    @Environment(\.settingsNav) private var nav

    private func link(_ route: SettingsRoute, _ title: String, value: String) -> some View {
        Button { nav?.open(route) } label: { SettingsRow(title: title, value: value, chevron: true) }
            .settingsFocus(.row(route))
            .accessibilityIdentifier("settings-\(route)")
    }

    @ViewBuilder private var streamPage: some View {
        SettingsPage(symbol: "play.tv", title: "Stream") {
            Section("Picture") {
                link(.mode, "Resolution", value: settings.mode.resolution.label)
                link(.fps, "Frame Rate", value: "\(settings.mode.fps) fps")
                link(.codec, "Video Codec", value: settings.codec.label)
                link(.bitrate, "Bitrate", value: "\(settings.bitrateMbps) Mbps")
                Button { settings.cycleStats() } label: {
                    SettingsRow(title: "Stats While Playing", value: settings.statsLabel)
                }
                .accessibilityValue(settings.statsLabel)
                    .accessibilityIdentifier("settings-show-stats")
            }
            if !app.regions.isEmpty {
                Section("Server") {
                    link(.region, "Location", value: settings.region.isEmpty ? "Automatic" : settings.region)
                }
            }
        }
    }

    @ViewBuilder private var dlssPage: some View {
        SettingsPage(symbol: "sparkles", title: "DLSS") {
            Section {
                link(.dlssModel, "Model", value: settings.dlssModel.label)
                link(.dlssQuality, "Quality", value: settings.dlssQuality.label)
                link(.dlssRays, "Ray Reconstruction", value: settings.dlssRays ? "Recommended model" : "Game\u{2019}s choice")
                link(.dlssFrames, "Frame Generation", value: settings.dlssFrames.label)
            }
        }
    }

    @ViewBuilder private var accountPage: some View {
        SettingsPage(symbol: "person.crop.circle", title: app.profile?.name ?? "Account",
                     summary: app.profile?.email) {
            Section("Membership") {
                InfoRow(title: "Plan", value: app.membership?.tier ?? app.profile?.tier ?? "Unavailable")
                InfoRow(title: "Time left this month", value: timeLeft)
            }
            Section {
                Button { Task { await app.load() } } label: { SettingsRow(title: "Reload Library") }
                Button { signingOut = true } label: { SettingsRow(title: "Sign Out") }
                    .accessibilityIdentifier("settings-sign-out")
            }
        }
        .alert("Sign out of GeForce NOW?", isPresented: $signingOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) { app.signOut() }
        } message: {
            Text("Any game still running keeps running.")
        }
    }

    private var timeLeft: String {
        guard let m = app.membership else { return "Unavailable" }
        if m.unlimited { return "Unlimited" }
        guard let h = m.hoursLeft else { return "Unavailable" }
        return String(format: "%.0f hours", h)
    }

    /// The app, the build, and what this Apple TV can do for a stream. Nothing else.
    @ViewBuilder private var aboutPage: some View {
        SettingsPage(symbol: nil, title: "") {
            Section {
                AboutHeader()
            }
            Section("This Apple TV") {
                InfoRow(title: "Display", value: DisplayInfo.summary)
                InfoRow(title: "Hardware Decoding", value: HardwareDecoders.describe)
            }
            Section {
                Text("Not affiliated with NVIDIA.")
                    .font(TVType.detail)
                    .foregroundStyle(TVColor.tertiary)
            }
        }
    }
}

/// The top of About: the icon, the name and the version.
private struct AboutHeader: View {
    var body: some View {
        HStack(spacing: 32) {
            Image("Icon")
                .resizable()
                .scaledToFill()
                .frame(width: 136, height: 136)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Kumori")
                    .font(TVType.section)
                    .foregroundStyle(TVColor.primary)
                    .accessibilityAddTraits(.isHeader)
                Text("Version \(BuildInfo.current.version) (\(BuildInfo.current.build)) \u{00B7} \(BuildInfo.current.commit)")
                    .font(TVType.callout)
                    .foregroundStyle(TVColor.secondary)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// "4K · 60 Hz" for the output this Apple TV is set to.
enum DisplayInfo {
    static var summary: String {
        let lines = Int(UIScreen.main.nativeBounds.height)
        let name: String
        switch lines {
        case 2160...: name = "4K"
        case 1440..<2160: name = "1440p"
        case 1080..<1440: name = "1080p"
        default: name = "\(lines)p"
        }
        return "\(name) \u{00B7} \(UIScreen.main.maximumFramesPerSecond) Hz"
    }
}

/// "1.3.0 (10300)", from the bundle.
enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}
