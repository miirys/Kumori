import SwiftUI

/// The power symbol, drawn rather than taken from SF Symbols: an open ring and a stem with
/// round ends, in plain white on a disc of glass. No glow. As it appears the ring draws
/// itself round from the gap, then the stem drops in.
struct TVPowerGlyph: View {
    var size: CGFloat = 92
    /// Kept for callers; the symbol is white whatever it's for.
    var tint: Color = TVColor.danger
    @Environment(\.tvReduceMotion) private var reduced
    @State private var drawn = false

    var body: some View {
        let line = size * 0.07
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: size * 1.45, height: size * 1.45)
            Ring()
                .trim(from: 0, to: drawn || reduced ? 1 : 0)
                .stroke(Color.white, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .frame(width: size * 0.6, height: size * 0.6)
            Stem()
                .trim(from: 0, to: drawn || reduced ? 1 : 0)
                .stroke(Color.white, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .frame(width: size * 0.6, height: size * 0.6)
                .animation(reduced ? nil : .easeOut(duration: 0.3).delay(0.38), value: drawn)
        }
        .frame(width: size * 1.45, height: size * 1.45)
        .animation(reduced ? nil : .easeInOut(duration: 0.55).delay(0.1), value: drawn)
        .onAppear { drawn = true }
        .accessibilityHidden(true)
    }
}

/// A ring open at the top.
private struct Ring: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.04)
        let r = min(rect.width, rect.height) * 0.46
        var p = Path()
        // 0° is to the right and angles run clockwise on screen; the gap sits around -90°.
        p.addArc(center: c, radius: r, startAngle: .degrees(-58), endAngle: .degrees(238), clockwise: false)
        return p
    }
}

/// The stem, from the top down into the ring's opening.
private struct Stem: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.04)
        let r = min(rect.width, rect.height) * 0.46
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: rect.minY - rect.height * 0.02))
        p.addLine(to: CGPoint(x: c.x, y: c.y - r * 0.08))
        return p
    }
}
