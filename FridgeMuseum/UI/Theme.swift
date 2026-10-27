import SwiftUI
import UIKit

/// Five-crayon palette from the web prototype: blue = 平面畫作, coral = 立體勞作,
/// and each edit tool owns a crayon (裁切 blue, 調整 yellow, 筆刷 pink, 資料 green).
enum Palette {
    static let paper = Color(red: 0xFB / 255, green: 0xF8 / 255, blue: 0xF3 / 255)
    static let surface = Color.white
    static let ink = Color(red: 0x1D / 255, green: 0x21 / 255, blue: 0x40 / 255)
    static let muted = Color(red: 0x59 / 255, green: 0x5E / 255, blue: 0x78 / 255)
    static let line = Color(red: 0xE6 / 255, green: 0xE1 / 255, blue: 0xD8 / 255)
    static let blue = Color(red: 0x2F / 255, green: 0x5B / 255, blue: 1)
    static let coral = Color(red: 1, green: 0x5B / 255, blue: 0x3A / 255)
    static let yellow = Color(red: 1, green: 0xC9 / 255, blue: 0x29 / 255)
    static let green = Color(red: 0x13 / 255, green: 0xA6 / 255, blue: 0x74 / 255)
    static let pink = Color(red: 1, green: 0x7F / 255, blue: 0xB1 / 255)

    static func color(for kind: ArtworkKind) -> Color { kind == .flat ? blue : coral }

    static let avatarHexes = ["#2F5BFF", "#FF5B3A", "#FFC929", "#13A674", "#FF7FB1", "#8E5CF7", "#00A7C4", "#7A5A3A"]
}

extension Color {
    init(_ c: RGBColor) {
        self.init(red: c.r, green: c.g, blue: c.b)
    }

    init(hex: String) {
        self.init(RGBColor(hex: hex) ?? RGBColor(r: 0.5, g: 0.5, b: 0.5))
    }
}

/// Centered aspect-fit rect of an image inside a box.
func fitRect(_ image: CGSize, in box: CGSize) -> CGRect {
    guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return .zero }
    let s = min(box.width / image.width, box.height / image.height)
    let w = image.width * s, h = image.height * s
    return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
}

struct AvatarDot: View {
    var hex: String
    var name: String
    var size: CGFloat = 26

    var body: some View {
        Circle()
            .fill(Color(hex: hex))
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.prefix(1)))
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }
}

struct Chip: View {
    var title: String
    var systemImage: String?
    var selected: Bool
    var tint: Color = Palette.blue
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Color.white : Palette.ink)
            .background(Capsule().fill(selected ? tint : Palette.surface))
            .overlay(Capsule().stroke(selected ? Color.clear : Palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Thumbnail tile with status, favorite and kind badges.
struct ArtworkThumb: View {
    let artwork: Artwork
    var processing: Bool = false

    var body: some View {
        let image = ThumbnailCache.shared.image(for: artwork)
        RoundedRectangle(cornerRadius: 10)
            .fill(Palette.surface)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                // Overlay on a fixed square so a scaledToFill image can't change the cell size.
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if artwork.processingState == .failed {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.coral)
                } else {
                    ProgressView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if artwork.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.yellow)
                    .padding(5)
                    .shadow(radius: 1)
            }
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 4) {
                Circle().fill(Palette.color(for: artwork.kind)).frame(width: 7, height: 7)
                if processing && image != nil { ProgressView().controlSize(.mini) }
            }
            .padding(6)
        }
        .accessibilityLabel("\(artwork.displayTitle)，\(artwork.kind.longLabel)")
    }
}
