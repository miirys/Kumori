import SwiftUI
import UIKit
import XCTest
@testable import Kumori

/// D01 and D03: the grid matches Apple's published widths, columns shrink with bigger text,
/// and every text colour clears the project's contrast gate.
final class DesignTokenTests: XCTestCase {
    func testFullSafeWidthGivesApplesPublishedTileWidths() {
        let layout = TVLayout.reference
        XCTAssertEqual(layout.contentWidth, 1760)
        XCTAssertEqual(TVTokens.tileWidth(available: 1760, columns: 2), 860)
        XCTAssertEqual(TVTokens.tileWidth(available: 1760, columns: 3), 560)
        XCTAssertEqual(TVTokens.tileWidth(available: 1760, columns: 4), 410)
        XCTAssertEqual(TVTokens.tileWidth(available: 1760, columns: 5), 320)
        XCTAssertEqual(TVTokens.tileWidth(available: 1760, columns: 6), 260)
        XCTAssertEqual(layout.tileWidth(.landscape, at: .large), 410)
        XCTAssertEqual(layout.tileWidth(.poster, at: .large), 260)
    }

    func testTilesFillTheSafeWidthExactly() {
        for columns in 2...6 {
            let w = TVTokens.tileWidth(available: 1760, columns: columns)
            XCTAssertEqual(w * CGFloat(columns) + TVTokens.gutter * CGFloat(columns - 1), 1760, "columns \(columns)")
        }
    }

    func testLargerTextMeansFewerColumns() {
        XCTAssertEqual(TVTokens.columns(.poster, at: .large), 6)
        XCTAssertLessThanOrEqual(TVTokens.columns(.poster, at: .accessibility1), 4)
        XCTAssertLessThanOrEqual(TVTokens.columns(.poster, at: .accessibility5), 3)
        XCTAssertEqual(TVTokens.columns(.landscape, at: .large), 4)
        XCTAssertLessThanOrEqual(TVTokens.columns(.landscape, at: .accessibility3), 2)
        var last = Int.max
        for size in DynamicTypeSize.allCases {
            let n = TVTokens.columns(.poster, at: size)
            XCTAssertLessThanOrEqual(n, last, "\(size)")
            last = n
        }
    }

    func testNarrowerPaneGivesNarrowerTiles() {
        // A sidebar takes width: tiles shrink rather than spill past the safe edge.
        let pane = TVLayout(width: 1400)
        let w = pane.tileWidth(.landscape, at: .large)
        XCTAssertLessThan(w, 410)
        XCTAssertLessThanOrEqual(w * 4 + TVTokens.gutter * 3, pane.contentWidth)
    }

    func testTextColoursClearTheContrastGate() {
        let backgrounds = [("canvas", TVColor.canvas), ("panel", TVColor.panel)]
        let texts = [("primary", TVColor.primary), ("secondary", TVColor.secondary), ("tertiary", TVColor.tertiary)]
        for (bn, b) in backgrounds {
            for (tn, t) in texts {
                let ratio = Contrast.ratio(t, b)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(tn) on \(bn) is \(ratio)")
            }
        }
        XCTAssertGreaterThanOrEqual(Contrast.ratio(TVColor.accent, TVColor.canvas), 4.5)
    }

    func testScrimKeepsWhiteTextReadableOnTheBrightestArt() {
        // The brightest fixture ground is close to white. White text over it at the scrim's
        // near opacity must still clear 4.5:1.
        let bright = UIColor(red: 1.0, green: 0.97, blue: 0.90, alpha: 1)
        let composited = Contrast.composite(black: TVColor.scrimNear, over: bright)
        XCTAssertGreaterThanOrEqual(Contrast.ratio(UIColor.white, composited), 4.5)
    }
}

/// WCAG 2 relative luminance and contrast ratio.
enum Contrast {
    static func ratio(_ a: Color, _ b: Color) -> Double { ratio(UIColor(a), UIColor(b)) }

    static func ratio(_ a: UIColor, _ b: UIColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ c: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// Black at `opacity` laid over `color`.
    static func composite(black opacity: Double, over color: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let k = CGFloat(1 - opacity)
        return UIColor(red: r * k, green: g * k, blue: b * k, alpha: 1)
    }
}
