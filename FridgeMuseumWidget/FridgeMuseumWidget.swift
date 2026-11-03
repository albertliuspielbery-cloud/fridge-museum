import ImageIO
import SwiftUI
import UIKit
import WidgetKit

// 主畫面小工具 (1.3.0): one artwork from the museum as a print on the mint fridge door, held by a fruit magnet, with
// the child's name and the date. Rotates every 3 hours (WidgetSchedule); tap opens it in the app
// (fridgemuseum://artwork/<uuid>). Reads only the App Group files the app writes (App/WidgetSnapshot.swift) — never the
// database. Empty museum (or no data yet): 冰冰 and 拍第一張作品吧.

@main
struct FridgeMuseumWidgetBundle: WidgetBundle {
    var body: some Widget {
        MuseumWidget()
    }
}

struct MuseumWidget: Widget {
    let kind = "MuseumWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MuseumProvider()) { entry in
            MuseumWidgetView(entry: entry)
        }
        .configurationDisplayName(Text("冰箱美術館"))
        .description(Text("每三小時換一件孩子的作品。"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: Timeline

struct MuseumEntry: TimelineEntry, Sendable {
    let date: Date
    let artwork: WidgetArtwork?
    let imageURL: URL?
}

struct MuseumProvider: TimelineProvider {
    func placeholder(in context: Context) -> MuseumEntry {
        MuseumEntry(date: Date(), artwork: nil, imageURL: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (MuseumEntry) -> Void) {
        completion(Self.entries(now: Date()).first ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MuseumEntry>) -> Void) {
        let entries = Self.entries(now: Date())
        // One artwork or none: nothing to rotate; the app reloads the timeline when the museum changes.
        completion(Timeline(entries: entries, policy: entries.count > 1 ? .atEnd : .never))
    }

    static func entries(now: Date) -> [MuseumEntry] {
        let manifest = WidgetFiles.loadManifest()
        let schedule = WidgetSchedule.entries(now: now, count: manifest.artworks.count, calendar: .current)
        return schedule.map { e in
            guard let i = e.index, manifest.artworks.indices.contains(i) else {
                return MuseumEntry(date: e.date, artwork: nil, imageURL: nil)
            }
            let a = manifest.artworks[i]
            return MuseumEntry(date: e.date, artwork: a, imageURL: WidgetFiles.imageURL(a.imageFile))
        }
    }
}

enum WidgetFiles {
    static func loadManifest() -> WidgetManifest {
        guard let root = WidgetShared.containerURL(),
              let data = try? Data(contentsOf: root.appendingPathComponent(WidgetShared.manifestFileName)) else { return .empty }
        return WidgetManifest.decode(data) ?? .empty
    }

    static func imageURL(_ file: String) -> URL? {
        WidgetShared.containerURL()?
            .appendingPathComponent(WidgetShared.imagesFolderName, isDirectory: true)
            .appendingPathComponent(file)
    }

    /// Decoded at most `maxPixel` on the long side (the files are already ≤ 600 px; this keeps memory predictable).
    static func image(at url: URL?, maxPixel: Int = WidgetShared.maxImageEdge) -> CGImage? {
        guard let url, let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}

// MARK: Look (colours copied from the app's UI/Theme.swift Palette; fonts: system rounded to keep the extension small)

enum WidgetPalette {
    static let doorHi = dynamic(0xB9E7DA, 0x4F9890)
    static let door = dynamic(0x8ED3C0, 0x33766F)
    static let doorLo = dynamic(0x5DB4A0, 0x24585A)
    static let doorInk = dynamic(0x173A31, 0xFFFFFF)
    static let doorMuted = dynamic(0x22564A, 0xE2F6F1)
    static let printEdge = Color(uiColor: UIColor(rgb: 0xE8DECE))
    static let shadow = Color(uiColor: UIColor(rgb: 0x3C2814, alpha: 0.30))

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}

/// The same fruit magnet for an artwork every time (the app's own magnet art).
enum WidgetMagnet {
    static let names = ["mag-lemon", "mag-tomato", "mag-berry"]

    static func name(for id: UUID) -> String {
        let sum = id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return names[sum % names.count]
    }
}

// MARK: Views

struct MuseumWidgetView: View {
    let entry: MuseumEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let artwork = entry.artwork, let image = WidgetFiles.image(at: entry.imageURL) {
                filled(artwork, image: image)
                    .widgetURL(WidgetShared.artworkURL(artwork.id))
            } else {
                EmptyMuseumView(family: family)
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [WidgetPalette.doorHi, WidgetPalette.door, WidgetPalette.doorLo],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    @ViewBuilder
    private func filled(_ artwork: WidgetArtwork, image: CGImage) -> some View {
        switch family {
        case .systemMedium:
            HStack(spacing: 14) {
                PrintView(image: image, magnet: WidgetMagnet.name(for: artwork.id), magnetSize: 30)
                    .padding(.top, 8)
                CaptionView(artwork: artwork, nameSize: 20, dateSize: 14, lines: 2, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
        case .systemLarge:
            VStack(spacing: 10) {
                PrintView(image: image, magnet: WidgetMagnet.name(for: artwork.id), magnetSize: 40)
                    .padding(.top, 12)
                CaptionView(artwork: artwork, nameSize: 19, dateSize: 14, lines: 1, alignment: .center)
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
        default:
            VStack(spacing: 5) {
                PrintView(image: image, magnet: WidgetMagnet.name(for: artwork.id), magnetSize: 24)
                    .padding(.top, 6)
                CaptionView(artwork: artwork, nameSize: 13, dateSize: 11, lines: 1, alignment: .center, compact: true)
            }
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 9, trailing: 10))
        }
    }
}

/// The artwork as a white print on the door, a magnet holding its top edge (like the app's fridge and share card).
struct PrintView: View {
    let image: CGImage
    let magnet: String
    let magnetSize: CGFloat

    var body: some View {
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(aspect, contentMode: .fit)
            .padding(magnetSize * 0.22)
            .background(Color.white)
            .overlay(Rectangle().strokeBorder(WidgetPalette.printEdge, lineWidth: 0.5))
            .shadow(color: WidgetPalette.shadow, radius: 3, y: 2)
            .overlay(alignment: .top) {
                Image(magnet)
                    .resizable()
                    .scaledToFit()
                    .frame(width: magnetSize, height: magnetSize)
                    .offset(y: -magnetSize * 0.45)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CaptionView: View {
    let artwork: WidgetArtwork
    let nameSize: CGFloat
    let dateSize: CGFloat
    let lines: Int
    let alignment: HorizontalAlignment
    var compact = false

    var body: some View {
        VStack(alignment: alignment, spacing: compact ? 0 : 3) {
            if let name = artwork.childName, !name.isEmpty {
                Text(verbatim: name)
                    .font(.system(size: nameSize, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetPalette.doorInk)
                    .lineLimit(lines)
                    .minimumScaleFactor(0.7)
            }
            Text(artwork.capturedAt, format: .dateTime.year().month().day())
                .font(.system(size: dateSize, weight: .medium, design: .rounded))
                .foregroundStyle(WidgetPalette.doorMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }
}

struct EmptyMuseumView: View {
    let family: WidgetFamily

    var body: some View {
        let small = family == .systemSmall
        let layout = family == .systemMedium
            ? AnyLayout(HStackLayout(spacing: 14))
            : AnyLayout(VStackLayout(spacing: small ? 6 : 12))
        layout {
            Image("bibi-empty")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: small ? 92 : 150, maxHeight: small ? 84 : 140)
                .accessibilityHidden(true)
            Text("拍第一張作品吧")
                .font(.system(size: small ? 15 : 20, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetPalette.doorInk)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
