import SwiftUI

// Panels and action buttons for the in-game menu, dialogs and Settings: one neutral graphite
// glass, one focus treatment, one destructive colour. Nothing here takes its colour from the
// game's art, so a panel reads the same over a sunset, a night sky or a white menu screen.

extension TVColor {
    /// The glass's own colour: a near-black graphite, laid over a blur of whatever is behind.
    static let glassFill = Color(white: 0.075)
    /// A control at rest on glass or on the page: just enough to read as a button.
    static let control = Color.white.opacity(0.09)
    /// The current choice in a group of chips, when focus is elsewhere.
    static let controlSelected = Color.white.opacity(0.2)
    /// Text on a focused platter. 17:1 on the platter.
    static let ink = Color(white: 0.07)
    /// Ending something, on dark: #FF6B61, 6.9:1 on the glass.
    static let danger = Color(red: 1, green: 0x6B / 255, blue: 0x61 / 255)
    /// Ending something, on the light platter: #C4161C, 5.9:1 on the platter.
    static let dangerInk = Color(red: 0xC4 / 255, green: 0x16 / 255, blue: 0x1C / 255)

    /// The focused platter: white, a touch brighter at the top, as the system's are lit.
    static let platter = LinearGradient(colors: [Color(white: 0.98), Color(white: 0.89)],
                                        startPoint: .top, endPoint: .bottom)
}

private struct TVGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.tvReduceTransparency) private var opaque

    func body(content: Content) -> some View {
        content
            .background {
                if opaque {
                    shape.fill(TVColor.panel)
                } else {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(TVColor.glassFill.opacity(0.74))
                    }
                }
            }
            .overlay {
                // A hairline that catches the light along the top edge, as glass does.
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
    }
}

extension View {
    /// Neutral graphite glass behind content: the in-game menu, dialogs, the Settings pane.
    func tvGlass(radius: CGFloat = TVTokens.panelRadius) -> some View {
        modifier(TVGlass(shape: RoundedRectangle(cornerRadius: radius, style: .continuous)))
    }
}

/// A button that sits on glass or on the page with a quiet fill, and lifts onto a white
/// platter under focus, the text turning dark with it. The same spring as Settings rows, so
/// focus feels the same everywhere.
///
/// - `role: .destructive` draws the label red, on the glass and on the platter.
/// - `selected` marks the current choice in a group (a resolution chip) while focus is
///   elsewhere.
struct TVActionStyle: ButtonStyle {
    enum Shape { case capsule, rounded }

    var role: ButtonRole?
    var shape: Shape = .rounded
    var selected = false
    var height: CGFloat = 76
    /// Text alignment inside the button.
    var alignment: Alignment = .leading

    func makeBody(configuration: Configuration) -> some View {
        TVActionBody(configuration: configuration, style: self)
    }
}

private struct TVActionBody: View {
    let configuration: ButtonStyleConfiguration
    let style: TVActionStyle
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.tvReduceMotion) private var reduced

    var body: some View {
        let lifted = focused && !reduced
        let destructive = style.role == .destructive
        configuration.label
            .font(TVType.body.weight(focused ? .semibold : .medium))
            .labelStyle(TVActionLabelStyle())
            .foregroundStyle(ink(destructive: destructive))
            .lineLimit(1)
            .padding(.horizontal, style.shape == .capsule ? 36 : 28)
            .frame(maxWidth: .infinity, minHeight: style.height, alignment: style.alignment)
            .background { background(lifted: lifted) }
            .contentShape(outline)
            .scaleEffect(lifted ? (configuration.isPressed ? 1.0 : 1.04) : 1)
            .zIndex(focused ? 1 : 0)
            .opacity(enabled ? 1 : 0.38)
            .animation(reduced ? TVMotion.reducedFade : TVMotion.lift, value: focused)
            .animation(reduced ? nil : .spring(duration: 0.2, bounce: 0), value: configuration.isPressed)
    }

    private var outline: AnyShape {
        style.shape == .capsule
            ? AnyShape(Capsule(style: .continuous))
            : AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func ink(destructive: Bool) -> Color {
        if focused { return destructive ? TVColor.dangerInk : TVColor.ink }
        if destructive { return TVColor.danger }
        return TVColor.primary
    }

    @ViewBuilder private func background(lifted: Bool) -> some View {
        ZStack {
            outline.fill(style.selected ? TVColor.controlSelected : TVColor.control)
            if style.selected && !focused {
                outline.stroke(Color.white.opacity(0.34), lineWidth: 1.5)
            }
            outline.fill(TVColor.platter)
                .opacity(focused ? 1 : 0)
                .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: lifted ? 26 : 0, y: lifted ? 14 : 0)
        }
    }
}

/// An action's symbol in a fixed-width column, so the titles of a stack of actions line up.
private struct TVActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 22) {
            configuration.icon
                .font(TVType.callout.weight(.semibold))
                .frame(width: 36)
            configuration.title
        }
    }
}
