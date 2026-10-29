import CoreTransferable
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// 分享卡片: drawing (ShareCardView), rendering (ShareCardRenderer → 1080-wide opaque sRGB JPEG), the share sheet item
// (ShareCardItem, rendered only when the person actually shares) and the entry points on the artwork detail screen.
// Sharing is free for everyone and never touches the quota (QuotaTracker): it's a picture of an artwork already kept.

/// Fixed light colours: the card is a picture, so it looks the same in dark mode (Theme.swift light palette).
enum ShareCardColors {
    static let door = Color(hex: "#8ED3C0")
    static let doorLight = Color(hex: "#9DDAC9")
    static let handle = Color(hex: "#5DB4A0")
    static let card = Color(hex: "#FFF8EA")
    static let cardLine = Color(hex: "#EFDDBF")
    static let rule = Color(hex: "#E2CBA6")
    static let title = Color(hex: "#C9432D")
    /// Name + age, semester: ≥ 4.5:1 on the cream placard.
    static let name = Color(hex: "#5A4636")
    static let quote = Color(hex: "#2E211A")
    static let teal = Color(hex: "#227F6E")
    static let doorInk = Color(hex: "#173A31")
    static let printEdge = Color(hex: "#E8DECE")
    static let printShadow = Color(hex: "#3C2814").opacity(0.36)
    static let shadow = Color(hex: "#5A3214").opacity(0.28)
}

struct ShareCardView: View {
    let content: ShareCardContent
    let layout: ShareCardLayout
    let art: CGImage

    var body: some View {
        let W = layout.canvas.width, H = layout.canvas.height
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [ShareCardColors.doorLight, ShareCardColors.door], startPoint: .topLeading, endPoint: .bottomTrailing)
            // The door handle on the right (no highlight strip on the left).
            Capsule().fill(ShareCardColors.handle)
                .frame(width: 24, height: H * 0.26)
                .position(x: W - 44, y: H * 0.43)
            printView
                .position(x: layout.printFrame.midX, y: layout.printFrame.midY)
            placard
                .position(x: layout.placardFrame.midX, y: layout.placardFrame.midY)
            badge
                .position(x: layout.badgeFrame.midX, y: layout.badgeFrame.midY)
        }
        .frame(width: W, height: H)
        .environment(\.colorScheme, .light)
    }

    private var printView: some View {
        let p = layout.printFrame, a = layout.artFrame, mf = layout.magnetFrame
        return ZStack {
            Rectangle().fill(Color.white)
            Image(decorative: art, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: a.width, height: a.height)
        }
        .frame(width: p.width, height: p.height)
        .overlay(Rectangle().strokeBorder(ShareCardColors.printEdge, lineWidth: 2))
        .shadow(color: ShareCardColors.printShadow, radius: 16, x: 0, y: 12)
        .overlay(alignment: .topLeading) {
            Image(layout.magnet)
                .resizable()
                .scaledToFit()
                .frame(width: mf.width, height: mf.height)
                .shadow(color: ShareCardColors.shadow, radius: 5, x: 0, y: 5)
                .offset(x: mf.minX, y: mf.minY)
        }
        .rotationEffect(.degrees(layout.printTilt))
    }

    private var placard: some View {
        let m = layout.metrics
        let inner = layout.placardInnerWidth
        return VStack(alignment: .leading, spacing: 0) {
            line(layout.title, font: ShareCardType.font(FMFont.display, size: m.titleSize), color: ShareCardColors.title, width: inner)
            Color.clear.frame(width: 1, height: m.gapAfterTitle)
            line(layout.meta, font: ShareCardType.font(FMFont.regular, size: m.nameSize), color: ShareCardColors.name, width: inner)
            if let detail = layout.detail {
                Color.clear.frame(width: 1, height: m.gapAfterName)
                line(detail, font: ShareCardType.font(FMFont.regular, size: m.detailSize ?? m.nameSize),
                     color: ShareCardColors.name, width: inner)
            }
            if let quote = layout.quote {
                Color.clear.frame(width: 1, height: m.dividerSpace)
                DashedRule()
                    .stroke(ShareCardColors.rule, style: StrokeStyle(lineWidth: m.dividerWidth, lineCap: .round, dash: [12, 10]))
                    .frame(width: inner, height: m.dividerWidth)
                Color.clear.frame(width: 1, height: m.dividerSpace)
                if let label = layout.label {
                    line(label, font: ShareCardType.font(FMFont.bold, size: m.labelSize ?? 28), color: ShareCardColors.teal, width: inner)
                    Color.clear.frame(width: 1, height: m.gapAfterLabel)
                }
                line(quote, font: ShareCardType.font(FMFont.display, size: m.quoteSize), color: ShareCardColors.quote, width: inner)
            }
        }
        .padding(m.placardPad)
        .frame(width: layout.placardFrame.width, height: layout.placardFrame.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: m.placardRadius, style: .continuous).fill(ShareCardColors.card))
        .overlay(RoundedRectangle(cornerRadius: m.placardRadius, style: .continuous).strokeBorder(ShareCardColors.cardLine, lineWidth: 3))
        .compositingGroup()
        .shadow(color: ShareCardColors.shadow, radius: 9, x: 0, y: 7)
        .rotationEffect(.degrees(layout.placardTilt))
    }

    private func line(_ block: ShareCardLayout.TextBlock, font: Font, color: Color, width: CGFloat) -> some View {
        Text(verbatim: block.text)
            .font(font)
            .foregroundStyle(color)
            .lineSpacing(block.lineSpacing)
            .lineLimit(block.lines)
            .truncationMode(.tail)
            .frame(width: width, height: block.height, alignment: .topLeading)
    }

    private var badge: some View {
        let m = layout.metrics
        return HStack(spacing: m.badgeHead * 0.25) {
            Image("bibi-head")
                .resizable()
                .scaledToFit()
                .frame(width: m.badgeHead * 4 / 3, height: m.badgeHead)
            Text(verbatim: content.brand)
                .font(ShareCardType.font(FMFont.display, size: m.badgeWordmark))
                .foregroundStyle(ShareCardColors.doorInk)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: layout.badgeFrame.width, height: layout.badgeFrame.height)
        .background(Capsule().fill(ShareCardColors.card.opacity(0.8)))
    }
}

private struct DashedRule: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

// MARK: Rendering

enum ShareCardRenderer {
    /// The art is drawn at most ~880 px wide; decode a little above that.
    static let artMaxPixel = 1800
    static let jpegQuality = 0.9

    /// Upright decode of the rendered artwork, off the main actor.
    static func decodeArt(_ data: Data) async -> RenderedImage? {
        await Task.detached(priority: .userInitiated) {
            ImageMetadata.uprightThumbnail(of: data, maxPixelSize: artMaxPixel).map { RenderedImage(cgImage: $0) }
        }.value
    }

    /// The card as an opaque bitmap exactly `format.size` pixels (ImageRenderer needs the main actor; it's ~1 frame).
    @MainActor
    static func render(_ content: ShareCardContent, art: RenderedImage, format: ShareCardFormat) -> RenderedImage? {
        let layout = ShareCardLayout.make(content: content, artSize: CGSize(width: art.width, height: art.height), format: format)
        let renderer = ImageRenderer(content: ShareCardView(content: content, layout: layout, art: art.cgImage))
        renderer.proposedSize = ProposedViewSize(format.size)
        renderer.scale = 1
        renderer.isOpaque = true
        renderer.colorMode = .nonLinear
        return renderer.cgImage.map { RenderedImage(cgImage: $0) }
    }

    /// Decode → render → JPEG (decode and encode off the main actor).
    static func jpeg(_ content: ShareCardContent, artData: Data, format: ShareCardFormat) async -> Data? {
        guard let art = await decodeArt(artData), let card = await render(content, art: art, format: format) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            ImageEncoding.jpegData(card.cgImage, quality: jpegQuality)
        }.value
    }
}

// MARK: Share sheet item

/// Cheap to create on every render (ids + text); the card is drawn only when the person picks a destination.
/// Shared as a plain JPEG with no text, so LINE / Messages get a clean picture.
struct ShareCardItem: Transferable, Sendable {
    let content: ShareCardContent
    let format: ShareCardFormat
    let persistentID: PersistentIdentifier
    let container: ModelContainer
    let recipe: ProcessingRecipe

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { item in
            try await item.jpeg()
        }
        .suggestedFileName(String(localized: "冰箱美術館") + ".jpg")
    }

    /// The stored render when it's current; otherwise the original, to render with the current recipe.
    private func storedImage() throws -> (rendered: Data?, original: Data?) {
        let context = ModelContext(container)
        guard let artwork = context.model(for: persistentID) as? Artwork else { throw ProcessingError.decodeFailed }
        if artwork.processingState == .done, let rendered = artwork.renderedImageData { return (rendered, nil) }
        guard let original = artwork.originalImageData else {
            if let rendered = artwork.renderedImageData { return (rendered, nil) }
            throw ProcessingError.decodeFailed
        }
        return (nil, original)
    }

    func jpeg() async throws -> Data {
        let stored = try storedImage()
        let artData: Data
        if let rendered = stored.rendered {
            artData = rendered
        } else if let original = stored.original {
            artData = try await ImageProcessor.shared.export(id: content.id, originalData: original, recipe: recipe).imageData
        } else {
            throw ProcessingError.decodeFailed
        }
        guard let out = await ShareCardRenderer.jpeg(content, artData: artData, format: format) else {
            throw ProcessingError.encodeFailed
        }
        return out
    }
}

extension ShareCardItem {
    @MainActor
    init?(artwork: Artwork, format: ShareCardFormat) {
        guard let container = artwork.modelContext?.container else { return nil }
        self.init(content: ShareCardContent(artwork: artwork), format: format, persistentID: artwork.persistentModelID,
                  container: container, recipe: artwork.recipe)
    }
}

// MARK: Entry points (ArtworkDetailView)

/// Action-bar knob: tap shares the 4:5 card; long-press offers 直式 4:5 / 方形.
struct ShareCardButton: View {
    let artwork: Artwork
    var preview: Image

    var body: some View {
        if let item = ShareCardItem(artwork: artwork, format: .portrait) {
            ShareLink(item: item, preview: SharePreview(artwork.placardTitle, image: preview)) {
                RoundKnob(systemImage: "photo.artframe", size: 54)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("分享卡片"))
            .contextMenu { ShareCardMenuItems(artwork: artwork, preview: preview) }
        }
    }
}

/// 分享卡片 section for a menu: one share link per format, 4:5 first.
struct ShareCardMenuItems: View {
    let artwork: Artwork
    var preview: Image

    var body: some View {
        Section {
            ForEach(ShareCardFormat.allCases, id: \.self) { format in
                if let item = ShareCardItem(artwork: artwork, format: format) {
                    ShareLink(item: item, preview: SharePreview(artwork.placardTitle, image: preview)) {
                        Label { Text(format.titleKey) } icon: { Image(systemName: format.symbol) }
                    }
                }
            }
        } header: {
            Text("分享卡片")
        }
    }
}

// MARK: Screenshot scene (DemoMode `share-card`)

/// Full-screen preview of the rendered card. Only opened by the `share-card` demo scene (screenshot workflow).
struct ShareCardDemoScene: ViewModifier {
    let artwork: Artwork
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .task {
                guard DemoMode.scene("share-card") else { return }
                // After the navigation push has settled, or the cover may not present.
                try? await Task.sleep(for: .milliseconds(800))
                show = true
            }
            .fullScreenCover(isPresented: $show) {
                ShareCardPreview(artwork: artwork)
            }
    }
}

struct ShareCardPreview: View {
    let artwork: Artwork
    var format: ShareCardFormat = .portrait
    @State private var card: UIImage?

    var body: some View {
        ZStack {
            Wallpaper()
            if let card {
                Image(uiImage: card)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Palette.shadow, radius: 12, y: 6)
                    .padding(.horizontal, Metrics.gutter)
                    .accessibilityLabel(Text("分享卡片"))
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .topLeading) {
            if card != nil, DemoMode.scene("share-card") { ReadyMarker() }
        }
        .task {
            let content = ShareCardContent(artwork: artwork)
            guard let data = artwork.renderedImageData ?? artwork.thumbnailData,
                  let art = await ShareCardRenderer.decodeArt(data),
                  let out = ShareCardRenderer.render(content, art: art, format: format) else { return }
            card = UIImage(cgImage: out.cgImage)
        }
    }
}
