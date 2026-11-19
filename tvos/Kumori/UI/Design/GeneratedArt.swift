import SwiftUI

/// Stand-in key art for fixtures and screenshots: a painted scene (mountain ranges, sea,
/// a city at dusk, dunes, a planet, a misty forest) with the game's title set as a logo, the
/// way real game key art carries its own title treatment. Everything is drawn on the device
/// from a seed, so captures are identical run to run and ship nobody's artwork.
struct GeneratedArt: View {
    let seed: Int
    /// The title drawn on the art as a logo. Empty for backdrops, where the page sets the title.
    var title: String = ""

    /// One palette in eight is deliberately bright, to test text and focus over light art.
    static func isBright(seed: Int) -> Bool { abs(seed) % ScenePalette.all.count == ScenePalette.all.count - 1 }

    var body: some View {
        let palette = ScenePalette.all[abs(seed) % ScenePalette.all.count]
        let bright = Self.isBright(seed: seed)
        let kind = bright ? SceneKind.dunes : SceneKind.allCases[abs(seed) % SceneKind.allCases.count]
        ZStack(alignment: .bottomLeading) {
            Canvas { context, size in
                var painter = ScenePainter(palette: palette, rng: SeededRandom(seed))
                painter.paint(kind, in: &context, size: size)
            }
            if !title.isEmpty {
                GeometryReader { geo in
                    ZStack(alignment: .bottomLeading) {
                        if !bright {
                            // Real key art darkens under its logo; so does this.
                            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                        }
                        Wordmark(title: title, style: abs(seed / 2) % Wordmark.styles, width: geo.size.width, dark: bright)
                            .padding(.leading, geo.size.width * 0.06)
                            .padding(.trailing, geo.size.width * 0.18)
                            .padding(.bottom, geo.size.height * 0.08)
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Title treatment

private struct Wordmark: View {
    static let styles = 4
    let title: String
    let style: Int
    let width: CGFloat
    let dark: Bool

    var body: some View {
        let base = width * 0.085
        let text: Text = {
            switch style {
            case 0:
                return Text(title).font(.system(size: base * 1.05, weight: .black, design: .serif))
            case 1:
                return Text(title.uppercased()).font(.system(size: base, weight: .heavy).width(.condensed)).tracking(base * 0.04)
            case 2:
                return Text(title.uppercased()).font(.system(size: base * 0.7, weight: .light).width(.expanded)).tracking(base * 0.22)
            default:
                return Text(title).font(.system(size: base, weight: .semibold, design: .serif).italic())
            }
        }()
        text
            .foregroundStyle(dark ? Color(white: 0.12) : Color.white)
            .lineLimit(2)
            .minimumScaleFactor(0.45)
            .shadow(color: .black.opacity(dark ? 0 : 0.45), radius: base * 0.25, y: base * 0.06)
    }
}

// MARK: Scenes

private enum SceneKind: CaseIterable {
    case ranges, sea, city, dunes, planet, forest
}

/// Colours as RGB triples so layers can be blended between them.
private struct RGB {
    let r, g, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    func mix(_ o: RGB, _ t: Double) -> RGB { RGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }
    var color: Color { Color(red: r, green: g, blue: b) }
    func color(_ opacity: Double) -> Color { Color(red: r, green: g, blue: b).opacity(opacity) }
}

private struct ScenePalette {
    let skyTop: RGB
    let horizon: RGB
    let sun: RGB
    let far: RGB
    let near: RGB

    static let all: [ScenePalette] = [
        // Dusk violet
        ScenePalette(skyTop: RGB(0.14, 0.09, 0.28), horizon: RGB(0.96, 0.56, 0.44), sun: RGB(1, 0.86, 0.62), far: RGB(0.52, 0.33, 0.52), near: RGB(0.09, 0.05, 0.13)),
        // Alpine morning
        ScenePalette(skyTop: RGB(0.30, 0.50, 0.78), horizon: RGB(0.86, 0.91, 0.96), sun: RGB(1, 0.98, 0.92), far: RGB(0.56, 0.66, 0.79), near: RGB(0.09, 0.14, 0.20)),
        // Ember
        ScenePalette(skyTop: RGB(0.18, 0.04, 0.04), horizon: RGB(0.98, 0.46, 0.16), sun: RGB(1, 0.82, 0.42), far: RGB(0.55, 0.20, 0.12), near: RGB(0.07, 0.02, 0.02)),
        // Teal night
        ScenePalette(skyTop: RGB(0.01, 0.05, 0.10), horizon: RGB(0.12, 0.38, 0.44), sun: RGB(0.86, 0.95, 1), far: RGB(0.10, 0.26, 0.32), near: RGB(0.01, 0.03, 0.06)),
        // Rose
        ScenePalette(skyTop: RGB(0.28, 0.17, 0.38), horizon: RGB(0.98, 0.72, 0.70), sun: RGB(1, 0.93, 0.86), far: RGB(0.70, 0.50, 0.62), near: RGB(0.20, 0.11, 0.20)),
        // Jade
        ScenePalette(skyTop: RGB(0.04, 0.16, 0.14), horizon: RGB(0.58, 0.82, 0.62), sun: RGB(0.96, 1, 0.86), far: RGB(0.26, 0.46, 0.36), near: RGB(0.02, 0.09, 0.06)),
        // Deep blue
        ScenePalette(skyTop: RGB(0.01, 0.02, 0.09), horizon: RGB(0.22, 0.32, 0.68), sun: RGB(0.78, 0.87, 1), far: RGB(0.16, 0.21, 0.46), near: RGB(0.02, 0.03, 0.08)),
        // Bright sand (the light one)
        ScenePalette(skyTop: RGB(0.78, 0.87, 0.95), horizon: RGB(1.0, 0.96, 0.88), sun: RGB(1, 1, 0.96), far: RGB(0.95, 0.86, 0.72), near: RGB(0.86, 0.69, 0.49)),
    ]
}

/// SplitMix64: small, fast and the same on every device.
private struct SeededRandom {
    private var state: UInt64

    init(_ seed: Int) { state = UInt64(bitPattern: Int64(seed)) &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678 }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / 9_007_199_254_740_992.0
    }

    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

private struct ScenePainter {
    let palette: ScenePalette
    var rng: SeededRandom

    mutating func paint(_ kind: SceneKind, in ctx: inout GraphicsContext, size: CGSize) {
        let horizonY: Double
        switch kind {
        case .sea: horizonY = rng.range(0.52, 0.6)
        case .planet: horizonY = 1.0
        default: horizonY = rng.range(0.55, 0.7)
        }
        sky(&ctx, size, horizonY: horizonY, stars: kind == .planet || palette.skyTop.r + palette.skyTop.g < 0.12)
        switch kind {
        case .ranges: ranges(&ctx, size, horizonY: horizonY)
        case .sea: sea(&ctx, size, horizonY: horizonY)
        case .city: city(&ctx, size, horizonY: horizonY)
        case .dunes: dunes(&ctx, size, horizonY: horizonY)
        case .planet: planet(&ctx, size)
        case .forest: forest(&ctx, size, horizonY: horizonY)
        }
    }

    // MARK: Sky

    private mutating func sky(_ ctx: inout GraphicsContext, _ s: CGSize, horizonY: Double, stars: Bool) {
        let rect = CGRect(origin: .zero, size: s)
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [
                .init(color: palette.skyTop.color, location: 0),
                .init(color: palette.skyTop.mix(palette.horizon, 0.45).color, location: max(0.05, horizonY * 0.6)),
                .init(color: palette.horizon.color, location: min(1, horizonY)),
            ]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: s.height)))
        if stars {
            for _ in 0..<90 {
                let x = rng.next() * s.width, y = rng.next() * s.height * horizonY * 0.8
                let r = rng.range(0.4, 1.6) * s.width / 900
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)), with: .color(.white.opacity(rng.range(0.25, 0.9))))
            }
        }
        // The sun or moon, with a wide glow.
        let sunX = rng.range(0.45, 0.82) * s.width
        let sunY = (horizonY - rng.range(0.08, 0.22)) * s.height
        let sunR = s.width * rng.range(0.035, 0.06)
        ctx.fill(Path(rect), with: .radialGradient(
            Gradient(colors: [palette.sun.color(0.55), palette.horizon.color(0.0)]),
            center: CGPoint(x: sunX, y: sunY), startRadius: 0, endRadius: s.width * 0.45))
        ctx.fill(Path(ellipseIn: CGRect(x: sunX - sunR, y: sunY - sunR, width: sunR * 2, height: sunR * 2)), with: .color(palette.sun.color(0.95)))
    }

    // MARK: Terrain helpers

    /// A ridge line: summed waves, folded into peaks when `sharp`.
    private mutating func ridge(_ s: CGSize, base: Double, amplitude: Double, sharp: Bool) -> Path {
        let f1 = rng.range(1.2, 2.4), f2 = rng.range(3.5, 6), f3 = rng.range(9, 15)
        let p1 = rng.range(0, 6.28), p2 = rng.range(0, 6.28), p3 = rng.range(0, 6.28)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: s.height))
        let steps = 120
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            func wave(_ f: Double, _ p: Double) -> Double {
                let v = sin(t * f * .pi + p)
                return sharp ? 1 - abs(v) : (v + 1) / 2
            }
            let h = 0.55 * wave(f1, p1) + 0.3 * wave(f2, p2) + 0.15 * wave(f3, p3)
            path.addLine(to: CGPoint(x: t * s.width, y: (base - amplitude * h) * s.height))
        }
        path.addLine(to: CGPoint(x: s.width, y: s.height))
        path.closeSubpath()
        return path
    }

    /// Fills a layer with its colour, fading into haze at its foot so layers read as distance.
    private func layer(_ ctx: inout GraphicsContext, _ path: Path, _ s: CGSize, color: RGB, haze: Double, top: Double) {
        ctx.fill(path, with: .linearGradient(
            Gradient(colors: [color.color, color.mix(palette.horizon, haze).color]),
            startPoint: CGPoint(x: 0, y: top * s.height), endPoint: CGPoint(x: 0, y: s.height)))
    }

    // MARK: Scenes

    private mutating func ranges(_ ctx: inout GraphicsContext, _ s: CGSize, horizonY: Double) {
        let n = 4
        for i in 0..<n {
            let t = Double(i) / Double(n - 1)
            let base = horizonY + t * (1.02 - horizonY) * 0.75
            let path = ridge(s, base: base, amplitude: 0.32 - t * 0.14, sharp: true)
            layer(&ctx, path, s, color: palette.far.mix(palette.near, t), haze: 0.35 * (1 - t), top: base - 0.3)
        }
    }

    private mutating func sea(_ ctx: inout GraphicsContext, _ s: CGSize, horizonY: Double) {
        // A low island on the horizon.
        let island = ridge(s, base: horizonY + 0.005, amplitude: 0.07, sharp: false)
        ctx.fill(island, with: .color(palette.far.mix(palette.near, 0.4).color))
        let water = Path(CGRect(x: 0, y: horizonY * s.height, width: s.width, height: s.height * (1 - horizonY)))
        ctx.fill(water, with: .linearGradient(
            Gradient(colors: [palette.horizon.mix(palette.near, 0.45).color, palette.near.color]),
            startPoint: CGPoint(x: 0, y: horizonY * s.height), endPoint: CGPoint(x: 0, y: s.height)))
        // Light on the water.
        for _ in 0..<38 {
            let y = rng.range(horizonY + 0.01, 0.98) * s.height
            let spread = (y / s.height - horizonY) * 1.4
            let x = rng.range(0.5 - spread * 0.4, 0.75 + spread * 0.2) * s.width
            let w = s.width * rng.range(0.02, 0.09)
            ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: max(1, s.height * 0.004)), cornerRadius: 1),
                     with: .color(palette.sun.color(rng.range(0.15, 0.5))))
        }
    }

    private mutating func city(_ ctx: inout GraphicsContext, _ s: CGSize, horizonY: Double) {
        for layerIndex in 0..<2 {
            let t = Double(layerIndex)
            let color = palette.far.mix(palette.near, 0.45 + 0.55 * t)
            var x = -rng.range(0, 0.04) * s.width
            while x < s.width {
                let w = rng.range(0.035, 0.085) * s.width
                let h = rng.range(0.12, 0.42 - 0.12 * t) * s.height
                let top = (horizonY + 0.08 + 0.16 * t) * s.height - h
                let rect = CGRect(x: x, y: top, width: w, height: s.height - top)
                ctx.fill(Path(rect), with: .color(color.color))
                if layerIndex == 1 {
                    // Lit windows.
                    let cell = max(3, s.width * 0.008)
                    var wy = top + cell
                    while wy < s.height - cell {
                        var wx = x + cell * 0.8
                        while wx < x + w - cell {
                            if rng.next() < 0.22 {
                                ctx.fill(Path(CGRect(x: wx, y: wy, width: cell * 0.55, height: cell * 0.7)),
                                         with: .color(palette.sun.color(rng.range(0.35, 0.85))))
                            }
                            wx += cell * 1.4
                        }
                        wy += cell * 1.6
                    }
                }
                x += w + rng.range(0, 0.01) * s.width
            }
        }
    }

    private mutating func dunes(_ ctx: inout GraphicsContext, _ s: CGSize, horizonY: Double) {
        for i in 0..<4 {
            let t = Double(i) / 3
            let base = horizonY + 0.04 + t * 0.26
            let path = ridge(s, base: base, amplitude: 0.12, sharp: false)
            let lit = palette.far.mix(palette.sun, 0.25 * (1 - t))
            ctx.fill(path, with: .linearGradient(
                Gradient(colors: [lit.color, palette.far.mix(palette.near, 0.4 + 0.6 * t).color]),
                startPoint: CGPoint(x: 0, y: (base - 0.12) * s.height), endPoint: CGPoint(x: s.width * 0.3, y: s.height)))
        }
    }

    private mutating func planet(_ ctx: inout GraphicsContext, _ s: CGSize) {
        let r = s.height * rng.range(0.42, 0.58)
        let c = CGPoint(x: s.width * rng.range(0.6, 0.75), y: s.height * rng.range(0.5, 0.75))
        let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.fill(disc, with: .radialGradient(
            Gradient(colors: [palette.horizon.mix(palette.sun, 0.3).color, palette.far.color, palette.near.color]),
            center: CGPoint(x: c.x - r * 0.45, y: c.y - r * 0.45), startRadius: 0, endRadius: r * 2.1))
        // Bands across the surface.
        var banded = ctx
        banded.clip(to: disc)
        for i in 0..<6 {
            let y = c.y - r + Double(i) * r / 3 + rng.range(-8, 8)
            banded.fill(Path(CGRect(x: c.x - r, y: y, width: r * 2, height: r * rng.range(0.04, 0.12))),
                        with: .color(palette.near.color(0.18)))
        }
        // A ring.
        let ring = Path(ellipseIn: CGRect(x: -r * 1.7, y: -r * 0.32, width: r * 3.4, height: r * 0.64))
            .applying(CGAffineTransform(rotationAngle: -0.28).concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
        ctx.stroke(ring, with: .color(palette.sun.color(0.55)), lineWidth: max(2, r * 0.035))
    }

    private mutating func forest(_ ctx: inout GraphicsContext, _ s: CGSize, horizonY: Double) {
        let hills = ridge(s, base: horizonY, amplitude: 0.12, sharp: false)
        layer(&ctx, hills, s, color: palette.far, haze: 0.4, top: horizonY - 0.12)
        for i in 0..<3 {
            let t = Double(i) / 2
            let color = palette.far.mix(palette.near, 0.35 + 0.65 * t)
            let groundY = (horizonY + 0.1 + t * 0.22) * s.height
            var x = -s.width * 0.02
            var trees = Path()
            while x < s.width * 1.02 {
                let h = rng.range(0.12, 0.26 + 0.12 * t) * s.height
                let w = h * rng.range(0.32, 0.42)
                trees.move(to: CGPoint(x: x, y: groundY - h))
                trees.addLine(to: CGPoint(x: x + w / 2, y: groundY + 2))
                trees.addLine(to: CGPoint(x: x - w / 2, y: groundY + 2))
                trees.closeSubpath()
                x += w * rng.range(0.35, 0.7)
            }
            trees.addRect(CGRect(x: 0, y: groundY, width: s.width, height: s.height - groundY))
            ctx.fill(trees, with: .color(color.color))
            // Mist between rows.
            ctx.fill(Path(CGRect(x: 0, y: groundY - s.height * 0.05, width: s.width, height: s.height * 0.08)),
                     with: .linearGradient(Gradient(colors: [palette.horizon.color(0), palette.horizon.color(0.18 * (1 - t)), palette.horizon.color(0)]),
                                           startPoint: CGPoint(x: 0, y: groundY - s.height * 0.05), endPoint: CGPoint(x: 0, y: groundY + s.height * 0.03)))
        }
    }
}
