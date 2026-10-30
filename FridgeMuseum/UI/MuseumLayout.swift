import SwiftUI
import UIKit

/// 美術館的顯示方式：大圖（一行一件，像逛展覽）、標準（兩欄掛畫，預設）、小圖（密密的縮圖，快速找作品）.
/// The layout numbers are pure functions so they can be unit-tested (MuseumLayoutTests).
enum MuseumViewMode: String, CaseIterable, Identifiable, Sendable {
    case standard, small, large

    var id: String { rawValue }

    /// UserDefaults key (@AppStorage in MuseumView). The raw values above are the stored contract: don't rename them.
    static let storageKey = "museumViewMode"

    /// The stored value, or 標準 when nothing (or something unknown) is stored.
    init(stored raw: String?) {
        self = raw.flatMap(Self.init(rawValue:)) ?? .standard
    }

    /// Menu order: biggest prints first.
    static let menuOrder: [MuseumViewMode] = [.large, .standard, .small]
    /// Smallest prints first (pinch in → left, pinch out → right).
    static let byDensity: [MuseumViewMode] = [.small, .standard, .large]

    var title: String {
        switch self {
        case .standard: String(localized: "標準")
        case .small: String(localized: "小圖")
        case .large: String(localized: "大圖")
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "square.grid.2x2"
        case .small: "square.grid.3x3"
        case .large: "rectangle.portrait"
        }
    }

    /// Grid columns for a content width in points (iPhone portrait is 375–440 pt).
    func columns(forWidth width: CGFloat) -> Int {
        let wide = width >= 600
        switch self {
        case .standard: return wide ? 3 : 2
        case .large: return wide ? 2 : 1
        case .small:
            if width >= 600 { return 6 }
            return width >= 428 ? 5 : 4
        }
    }

    var columnSpacing: CGFloat {
        switch self {
        case .standard: 18
        case .small: 5
        case .large: 24
        }
    }

    var rowSpacing: CGFloat {
        switch self {
        case .standard: 28
        case .small: 5
        case .large: 40
        }
    }

    /// Side padding of the grid.
    var horizontalPadding: CGFloat {
        switch self {
        case .standard: Metrics.gutter + 6
        case .small: Metrics.gutter
        case .large: Metrics.gutter + 10
        }
    }

    /// The 選取 checkmark, sized to the tile.
    var selectionMarkSize: CGFloat {
        switch self {
        case .standard: 26
        case .small: 20
        case .large: 30
        }
    }

    /// Width of one tile for a container width.
    func tileWidth(containerWidth: CGFloat) -> CGFloat {
        let n = CGFloat(columns(forWidth: containerWidth))
        let w = containerWidth - horizontalPadding * 2 - columnSpacing * (n - 1)
        return max(0, w / n)
    }

    /// After a pinch on the grid: pinch in (scale < 1) → smaller prints, pinch out → bigger. One step per gesture;
    /// small wobbles don't change anything.
    func afterPinch(scale: CGFloat) -> MuseumViewMode {
        let order = Self.byDensity
        guard let i = order.firstIndex(of: self) else { return self }
        if scale < 0.8 { return order[max(0, i - 1)] }
        if scale > 1.25 { return order[min(order.count - 1, i + 1)] }
        return self
    }

    /// Long edge (pixels) to decode for a 大圖 print `widthPoints` wide: enough for the screen, never more than the
    /// 2400 px rendered image. 0 when the width isn't known yet.
    static func largePixelSize(widthPoints: CGFloat, aspect: CGFloat, scale: CGFloat) -> Int {
        guard widthPoints > 0, scale > 0 else { return 0 }
        let a = aspect > 0 ? aspect : 0.75
        let longEdgePoints = a >= 1 ? widthPoints : widthPoints / a
        return min(2400, Int((longEdgePoints * scale).rounded(.up)))
    }

    /// Long edge (pixels) for one page of the full-screen viewer: the screen's long edge, capped at 2400.
    static func viewerPixelSize(for size: CGSize, scale: CGFloat) -> Int {
        let longEdge = max(size.width, size.height) * max(scale, 1)
        guard longEdge > 0 else { return 0 }
        return min(2400, Int(longEdge.rounded(.up)))
    }
}

// MARK: Bigger decodes (大圖 prints, full-screen viewer)

/// Decodes `renderedImageData` (2400 px) downsampled to the size it is shown at, off the main actor (ImageIO
/// subsamples, the full bitmap is never decoded). A small cost-limited cache so scrolling back is instant, but only a
/// handful of big bitmaps ever stay in memory (4 GB phones); NSCache also drops them under memory pressure.
@MainActor
final class MuseumImageLoader {
    static let shared = MuseumImageLoader()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    private func key(_ artwork: Artwork, _ maxPixel: Int) -> NSString {
        "\(artwork.id.uuidString)-\(artwork.renderVersion)-\(maxPixel)" as NSString
    }

    func cached(_ artwork: Artwork, maxPixel: Int) -> UIImage? {
        cache.object(forKey: key(artwork, maxPixel))
    }

    func image(for artwork: Artwork, maxPixel: Int) async -> UIImage? {
        guard maxPixel > 0, AppModel.isAlive(artwork) else { return nil }
        let k = key(artwork, maxPixel)
        if let img = cache.object(forKey: k) { return img }
        guard let data = artwork.renderedImageData ?? artwork.thumbnailData else { return nil }
        let decoded = await Task.detached(priority: .userInitiated) {
            ImageMetadata.uprightThumbnail(of: data, maxPixelSize: maxPixel).map { RenderedImage(cgImage: $0) }
        }.value
        guard let decoded else { return nil }
        let img = UIImage(cgImage: decoded.cgImage)
        cache.setObject(img, forKey: k, cost: decoded.width * decoded.height * 4)
        return img
    }

    /// Drop the big bitmaps (the full-screen viewer closed).
    func trim() {
        cache.removeAllObjects()
    }
}

// MARK: 小圖

/// 小圖: a square thumbnail only — a tiny ⭐ and the child's colour dot, no placard. Uses the ≤ 480 px thumbnail.
struct MuseumSmallTile: View {
    let artwork: Artwork
    var processing = false
    var showChild = true

    var body: some View {
        let image = ThumbnailCache.shared.image(for: artwork)
        Rectangle()
            .fill(Palette.surface2)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if artwork.processingState == .failed {
                    Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.red)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .padding(2.5)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.print))
            .shadow(color: Palette.printShadow.opacity(0.5), radius: 2, y: 1)
            .overlay(alignment: .bottomLeading) {
                if showChild, let c = artwork.child {
                    Circle().fill(Color(hex: c.avatarColorHex))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 2) {
                    if processing { ProgressView().controlSize(.mini) }
                    if artwork.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Palette.yellow)
                            .padding(3)
                            .background(Circle().fill(.white))
                    }
                }
                .padding(5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(artwork.placardTitle), \(artwork.placardArtist), \(artwork.kind.title)"))
            .accessibilityAddTraits(.isImage)
    }
}

/// Semester header for 小圖: one line, so more thumbnails fit on screen.
struct CompactSectionHeader: View {
    var title: String
    var subtitle: String?
    var count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: title)
                .font(.fmDisplay(18, relativeTo: .headline))
                .foregroundStyle(Palette.title)
                .lineLimit(1)
            if let subtitle {
                Text(verbatim: subtitle).font(.fm(12.5)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text("\(count) 張").font(.fm(12.5, bold: true)).foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: 大圖

/// 大圖: one print across the width, its placard beneath (title, child · age, semester, 孩子說). The thumbnail shows
/// first; a sharper decode sized to the print replaces it while it is on screen and is released when it scrolls off.
struct MuseumLargeTile: View {
    let artwork: Artwork
    var processing = false
    /// Long edge to decode (MuseumViewMode.largePixelSize); 0 = keep the thumbnail.
    var pixelSize: Int = 0

    @State private var sharp: UIImage?

    private var snippet: String? {
        let note = artwork.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = note.isEmpty ? artwork.voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines) : note
        return text.isEmpty ? nil : text
    }

    private var lines: [String] {
        var out = [artwork.placardArtist, artwork.placardTerm]
        if let snippet { out.append(String(localized: "孩子說：「\(snippet)」")) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HungPrint(id: artwork.id, tilt: 0.8, tape: TapeStyle.pick(artwork.id), padding: 10) {
                Group {
                    if let sharp {
                        Image(uiImage: sharp).resizable().scaledToFit()
                    } else {
                        ArtworkImage(artwork: artwork)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(artwork.aspectRatio, contentMode: .fit)
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 6) {
                    if processing { ProgressView().controlSize(.small) }
                    if artwork.isFavorite {
                        Image(systemName: "star.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.yellow)
                            .padding(6).background(Circle().fill(.white)).shadow(radius: 1)
                    }
                }
                .padding(12)
            }
            Placard(title: artwork.placardTitle, lines: lines)
                .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .task(id: "\(artwork.renderVersion)-\(pixelSize)") {
            guard pixelSize > 0 else { return }
            if let hit = MuseumImageLoader.shared.cached(artwork, maxPixel: pixelSize) {
                sharp = hit
                return
            }
            // Skip prints that are only flicked past.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let img = await MuseumImageLoader.shared.image(for: artwork, maxPixel: pixelSize)
            if !Task.isCancelled { sharp = img }
        }
        .onDisappear { sharp = nil }
    }

    private var accessibilityText: String {
        var parts = [artwork.placardTitle, artwork.placardArtist, artwork.placardTerm, artwork.kind.title]
        if let snippet { parts.append(snippet) }
        return parts.joined(separator: ", ")
    }
}

/// 全螢幕看 — sits on a 大圖 print (outside the tile's own button, so both stay tappable).
struct FullScreenButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.black.opacity(0.4)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("全螢幕看"))
    }
}

/// Pinch on the museum wall (switch 大圖 / 標準 / 小圖). A UIPinchGestureRecognizer that never cancels touches and
/// recognizes simultaneously with everything, so the ScrollView keeps scrolling and the prints keep their taps.
struct WallPinchGesture: UIGestureRecognizerRepresentable {
    /// Called once when the pinch ends, with its final scale (< 1 pinch in, > 1 pinch out).
    let onEnded: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        let recognizer = UIPinchGestureRecognizer()
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPinchGestureRecognizer, context: Context) {
        if recognizer.state == .ended { onEnded(recognizer.scale) }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
