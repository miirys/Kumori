import SwiftUI

/// The power symbol, drawn rather than taken from SF Symbols: an open ring and a stem with
/// round ends, in white, over a soft glow in `tint`. No circle behind it, no outline.
struct TVPowerGlyph: View {
    var size: CGFloat = 92
    var tint: Color = TVColor.danger
    @Environment(\.tvReduceMotion) private var reduced
    @State private var lit = false

    var body: some View {
        let line = size * 0.075
        ZStack {
            // The glow, breathing once as the glyph appears.
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.55), tint.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: size * 0.95))
                .frame(width: size * 1.9, height: size * 1.9)
                .opacity(lit ? 1 : 0.4)
                .scaleEffect(lit ? 1 : 0.8)
            PowerShape()
                .stroke(Color.white, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .frame(width: size * 0.62, height: size * 0.62)
                .shadow(color: tint.opacity(0.8), radius: size * 0.12)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(reduced ? nil : .easeOut(duration: 0.9)) { lit = true }
        }
        .accessibilityHidden(true)
    }
}

/// A ring open at the top, and a stem down into the opening.
private struct PowerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.04)
        let r = min(rect.width, rect.height) * 0.46
        var p = Path()
        // 0° is to the right and angles run clockwise on screen; the gap sits around -90°.
        p.addArc(center: c, radius: r, startAngle: .degrees(-58), endAngle: .degrees(238), clockwise: false)
        p.move(to: CGPoint(x: c.x, y: rect.minY - rect.height * 0.02))
        p.addLine(to: CGPoint(x: c.x, y: c.y - r * 0.08))
        return p
    }
}
