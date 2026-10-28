import SwiftUI
import UIKit

// 暖暖廚房 × 冰冰 — the kitchen palette from the web prototype v0.9.0 (CSS custom properties),
// light = warm kitchen, dark = night kitchen. Every token resolves per trait collection.

extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1, darkAlpha: CGFloat? = nil) -> UIColor {
        let la = alpha, da = darkAlpha ?? alpha
        return UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark, alpha: da) : UIColor(rgb: light, alpha: la)
        }
    }
}

extension Color {
    init(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1, darkAlpha: CGFloat? = nil) {
        self.init(uiColor: .dynamic(light, dark, alpha: alpha, darkAlpha: darkAlpha))
    }

    init(_ c: RGBColor) {
        self.init(red: c.r, green: c.g, blue: c.b)
    }

    init(hex: String) {
        self.init(RGBColor(hex: hex) ?? RGBColor(r: 0.5, g: 0.5, b: 0.5))
    }
}

enum Palette {
    // Kitchen wall + fridge
    static let wall = Color(0xFCEBD2, 0x1E2340)
    static let wallMotif = Color(0xF3D6AB, 0x283058)
    static let title = Color(0x4A2F24, 0xF6EFE4)
    static let door = Color(0x8ED3C0, 0x33766F)
    static let doorHi = Color(0xB9E7DA, 0x4F9890)
    static let doorLo = Color(0x5DB4A0, 0x24585A)
    static let doorSeam = Color(0x6CC0AC, 0x2A625D)
    static let doorInk = Color(0x173A31, 0xFFFFFF)
    static let doorMuted = Color(0x22564A, 0xE2F6F1)

    // Surfaces + text
    static let surface = Color(0xFFFBF4, 0x272C4E)
    static let surface2 = Color(0xF6E8D3, 0x323862)
    static let ink = Color(0x4A2F24, 0xF4EEE4)
    static let muted = Color(0x7A5A48, 0xC9C1D9)
    static let faint = Color(0xA08470, 0x9C95B5)
    static let line = Color(0xEBD7BB, 0x3B426E)

    // Placards / notes / bubbles stay creamy at night
    static let card = Color(0xFFF8EA, 0xEFE4CF)
    static let cardInk = Color(0x3B2A20, 0x2E2118)
    static let cardMuted = Color(0x7A5A48, 0x6B5444)
    static let cardLine = Color(0xEFDDBF, 0xD8C9AE)
    static let note = Color(0xFFE8A3, 0xE6D17E)
    static let noteInk = Color(0x4A3A10, 0x2C2711)
    static let bubble = Color(0xFFFDF8, 0xF6EFE4)
    static let bubbleInk = Color(0x4A2F24, 0x2E2118)

    // Crayons
    static let red = Color(0xE5543C, 0xFF7A62)
    static let orange = Color(0xF08A3C, 0xFF9C4A)
    static let yellow = Color(0xF8C14A, 0xFFD45A)
    static let blue = Color(0x3F6FD6, 0x8AA8FF)
    static let green = Color(0x2E9C6A, 0x4FD39A)
    static let pink = Color(0xEC7FA2, 0xFF9CC0)
    static let purple = Color(0x8E5CC7, 0xB99AF2)
    static let placardRed = Color(0xC9432D, 0xB8361F)

    // Controls
    static let primary = Color(0xC9432D, 0xF07A62)
    static let primaryInk = Color(0xFFFFFF, 0x2A0F08)
    static let primaryDeep = Color(0xA8341F, 0xC4563F)
    static let track = Color(0x2E9C86, 0x4FC3A8)
    static let teal = Color(0x227F6E, 0x4FC3A8)
    static let tealInk = Color(0x1F6E60, 0x8FE3CF)
    static let tealSoft = Color(0xD5EFE7, 0x234A48)
    static let switchOff = Color(0xE6D6BF, 0x444A7A)
    static let warn = Color(0xB8361F, 0xFFAB8A)

    // Counter dock
    static let counter = Color(0xFFF4E4, 0x262B4E)
    static let counter2 = Color(0xF3E1C8, 0x1D2240)
    static let wood = Color(0xEDB985, 0x6E4C36)
    static let woodDeep = Color(0xC98A52, 0x4E3424)
    static let dockRaise = Color(0xFFFFFF, 0x363C6A)

    // Misc
    static let chip = Color(0x3A241A, 0x0E1022, alpha: 0.78)
    static let print = Color.white
    static let shadow = Color(0x5A3214, 0x000000, alpha: 0.16, darkAlpha: 0.4)
    static let printShadow = Color(0x3C2814, 0x000000, alpha: 0.32, darkAlpha: 0.6)
    static let mark = Color(red: 1, green: 0xD6 / 255, blue: 0x0A / 255)
    static let markEdge = Color(0x141630, 0x00000A, alpha: 0.6, darkAlpha: 0.7)

    static func color(for kind: ArtworkKind) -> Color { kind == .flat ? blue : red }

    /// Child profile colours (crayon box).
    static let avatarHexes = ["#3F6FD6", "#E5543C", "#F8C14A", "#2E9C6A", "#EC7FA2", "#8E5CC7", "#00A7C4", "#F08A3C"]

    // Back-compat names used by older views.
    static let paper = wall
    static let coral = red
}

// MARK: Fonts — Huninn (display) + Chiron GoRound TC (body), both bundled under the OFL.

enum FMFont {
    static let display = "Huninn-Regular"
    static let regular = "ChironGoRoundTC-Regular"
    static let bold = "ChironGoRoundTC-Bold"
}

extension Font {
    /// Huninn — headlines, placard titles, crayon headers.
    static func fmDisplay(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
        .custom(FMFont.display, size: size, relativeTo: style)
    }

    /// Chiron GoRound TC — everything else.
    static func fm(_ size: CGFloat, bold: Bool = false, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(bold ? FMFont.bold : FMFont.regular, size: size, relativeTo: style)
    }
}

enum Metrics {
    static let gutter: CGFloat = 16
    static let doorRadius: CGFloat = 34
}

/// Centered aspect-fit rect of an image inside a box.
func fitRect(_ image: CGSize, in box: CGSize) -> CGRect {
    guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return .zero }
    let s = min(box.width / image.width, box.height / image.height)
    let w = image.width * s, h = image.height * s
    return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
}

/// Stable small pseudo-random number in -1...1 from an id (so prints hang slightly crooked, but always the same way).
func wobble(_ id: UUID, salt: Int = 0) -> Double {
    var h: UInt64 = 1469598103934665603
    for b in withUnsafeBytes(of: id.uuid, Array.init) + [UInt8(truncatingIfNeeded: salt)] {
        h = (h ^ UInt64(b)) &* 1099511628211
    }
    return Double(h % 2001) / 1000 - 1
}
