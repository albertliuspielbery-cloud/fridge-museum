import CoreText
import SwiftUI
import UIKit

// 分享卡片 (share card): the artwork as a white print held by a fruit magnet on a mint fridge door, a cream placard
// underneath (title, artist + age, semester, 孩子說) and a small Bibi badge. Design: mockup A「冰箱磁鐵」with the
// artwork as the hero. This file holds the content snapshot and every layout decision (pure, unit-tested in
// ShareCardTests); ShareCardView.swift draws it and renders the JPEG.

enum ShareCardFormat: String, CaseIterable, Sendable, Hashable {
    /// 1080 × 1350 (4:5), the default.
    case portrait
    /// 1080 × 1080.
    case square

    var size: CGSize {
        switch self {
        case .portrait: CGSize(width: 1080, height: 1350)
        case .square: CGSize(width: 1080, height: 1080)
        }
    }

    /// Menu titles: 直式 4:5 / 方形.
    var titleKey: LocalizedStringKey { self == .portrait ? "直式 4:5" : "方形" }
    var symbol: String { self == .portrait ? "rectangle.portrait" : "square" }
}

/// Everything the card shows, as plain values (built on the main actor from the model, then Sendable).
struct ShareCardContent: Sendable, Equatable {
    var id: UUID
    var isCraft: Bool
    var title: String
    /// 小明 · 5歲10個月 / Mia · 5 yrs 10 mos.
    var artist: String
    /// 114學年 下學期 · 大班 / Spring 2026 · Kindergarten (no dates on the card).
    var term: String
    /// Custom medium (彩色筆、紙); shown after the term only when it fits on the same line.
    var medium: String?
    /// 孩子說 note; nil = no quote block at all.
    var quote: String?
    /// 孩子說 / In Mia’s words.
    var quoteLabel: String
    /// 冰箱美術館 / My Fridge Museum.
    var brand: String
    var isChinese: Bool

    init(id: UUID, isCraft: Bool, title: String, artist: String, term: String, medium: String? = nil, quote: String? = nil,
         quoteLabel: String, brand: String, isChinese: Bool) {
        self.id = id
        self.isCraft = isCraft
        self.title = Self.clean(title)
        self.artist = Self.clean(artist)
        self.term = Self.clean(term)
        let m = medium.map(Self.clean) ?? ""
        self.medium = m.isEmpty ? nil : m
        let q = quote.map(Self.clean) ?? ""
        self.quote = q.isEmpty ? nil : q
        self.quoteLabel = Self.clean(quoteLabel)
        self.brand = Self.clean(brand)
        self.isChinese = isChinese
    }

    /// One line of text for the card: newlines, tabs and the full-width space U+3000 (missing from the bundled font
    /// subsets) become a single ASCII space. Any other glyph the subsets lack falls back per run (ShareCardType).
    static func clean(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// 「…」 in Chinese, “…” in English.
    func quoted(_ q: String) -> String { isChinese ? "「\(q)」" : "“\(q)”" }
}

extension ShareCardContent {
    @MainActor
    init(artwork a: Artwork) {
        let zh = AppLanguage.isChinese
        let note = a.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? a.voiceTranscript : a.note
        let label: String
        if !zh, let name = a.child?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            label = String(localized: "In \(name)’s words")
        } else {
            label = String(localized: "孩子說")
        }
        self.init(id: a.id, isCraft: a.kind == .craft, title: a.placardTitle, artist: a.placardArtist, term: a.placardTerm,
                  medium: a.medium, quote: note, quoteLabel: label, brand: String(localized: "冰箱美術館"), isChinese: zh)
    }
}

// MARK: Type

/// Fonts for the card. Fixed point sizes (the card never follows Dynamic Type). The bundled Huninn / Chiron GoRound TC
/// are subsets: a cascade list sends any glyph they lack (a rare character in a typed name) to the system rounded font
/// for that run, then Core Text's own fallback (PingFang) — the same automatic fallback the rest of the app relies on.
enum ShareCardType {
    static let titleLeading: CGFloat = 1.16
    static let bodyLeading: CGFloat = 1.28
    static let quoteLeading: CGFloat = 1.36

    static func uiFont(_ name: String, size: CGFloat) -> UIFont {
        let system = UIFont.systemFont(ofSize: size, weight: name == FMFont.bold ? .bold : .regular)
        let rounded = system.fontDescriptor.withDesign(.rounded) ?? system.fontDescriptor
        guard let custom = UIFont(name: name, size: size) else { return UIFont(descriptor: rounded, size: size) }
        let descriptor = custom.fontDescriptor.addingAttributes([.cascadeList: [rounded]])
        return UIFont(descriptor: descriptor, size: size)
    }

    static func font(_ name: String, size: CGFloat) -> Font {
        Font(uiFont(name, size: size) as CTFont)
    }

    static func lineHeight(_ font: UIFont, leading: CGFloat) -> CGFloat {
        max(font.lineHeight, font.pointSize * leading)
    }

    /// Lines `text` wraps to at `width` (unclamped), laid out by Core Text (thread-safe, no UIKit drawing).
    static func lineCount(_ text: String, font: UIFont, width: CGFloat) -> Int {
        guard !text.isEmpty, width > 0 else { return 0 }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let setter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        return max(1, CFArrayGetCount(CTFrameGetLines(frame)))
    }

    static func width(_ text: String, font: UIFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]) as CFAttributedString)
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }
}

// MARK: Metrics

/// Sizes in card pixels (the card is always 1080 wide).
struct ShareCardMetrics: Sendable, Equatable {
    var printTop: CGFloat
    var printPad: CGFloat
    var maxPrintWidth: CGFloat
    /// Square: the print never takes more than this share of the height.
    var maxPrintHeightShare: CGFloat
    var printGap: CGFloat
    var maxPrintTilt: Double
    var magnetSize: CGFloat
    var placardWidth: CGFloat
    var placardPad: CGFloat
    var placardRadius: CGFloat
    var titleSize: CGFloat
    var titleMaxLines: Int
    var nameSize: CGFloat
    /// nil = no separate semester line (square: the semester joins the name line when it fits).
    var detailSize: CGFloat?
    /// nil = no 孩子說 label (square: the 「」 marks carry it).
    var labelSize: CGFloat?
    var quoteSize: CGFloat
    var quoteMaxLines: Int
    var quoteMaxLinesEnglish: Int
    var gapAfterTitle: CGFloat
    var gapAfterName: CGFloat
    var dividerSpace: CGFloat
    var dividerWidth: CGFloat
    var gapAfterLabel: CGFloat
    var badgeHeight: CGFloat
    var badgeHead: CGFloat
    var badgeWordmark: CGFloat
    var badgeRight: CGFloat
    var badgeBottom: CGFloat
    var badgeGap: CGFloat

    static func `for`(_ format: ShareCardFormat) -> ShareCardMetrics {
        switch format {
        case .portrait:
            ShareCardMetrics(printTop: 104, printPad: 22, maxPrintWidth: 880, maxPrintHeightShare: 1, printGap: 48,
                             maxPrintTilt: 1.5, magnetSize: 124, placardWidth: 896, placardPad: 44, placardRadius: 28,
                             titleSize: 68, titleMaxLines: 2, nameSize: 42, detailSize: 34, labelSize: 30,
                             quoteSize: 42, quoteMaxLines: 3, quoteMaxLinesEnglish: 4,
                             gapAfterTitle: 14, gapAfterName: 6, dividerSpace: 24, dividerWidth: 3, gapAfterLabel: 6,
                             badgeHeight: 64, badgeHead: 44, badgeWordmark: 34, badgeRight: 44, badgeBottom: 32, badgeGap: 18)
        case .square:
            ShareCardMetrics(printTop: 80, printPad: 18, maxPrintWidth: 860, maxPrintHeightShare: 0.72, printGap: 40,
                             maxPrintTilt: 1.5, magnetSize: 104, placardWidth: 936, placardPad: 32, placardRadius: 28,
                             titleSize: 58, titleMaxLines: 1, nameSize: 40, detailSize: nil, labelSize: nil,
                             quoteSize: 40, quoteMaxLines: 2, quoteMaxLinesEnglish: 2,
                             gapAfterTitle: 8, gapAfterName: 0, dividerSpace: 16, dividerWidth: 3, gapAfterLabel: 0,
                             badgeHeight: 56, badgeHead: 38, badgeWordmark: 30, badgeRight: 36, badgeBottom: 22, badgeGap: 14)
        }
    }
}

// MARK: Layout

struct ShareCardLayout: Sendable, Equatable {
    struct TextBlock: Sendable, Equatable {
        var text: String
        /// Lines drawn (natural line count clamped to maxLines; the last one ends in … when truncated).
        var lines: Int
        var maxLines: Int
        var height: CGFloat
        var lineSpacing: CGFloat
        var truncated: Bool
    }

    var format: ShareCardFormat
    var metrics: ShareCardMetrics
    var canvas: CGSize
    /// The white print (unrotated), card coordinates.
    var printFrame: CGRect
    /// The artwork inside the print, card coordinates.
    var artFrame: CGRect
    var printTilt: Double
    var magnet: String
    /// The magnet in the print's own coordinates (y < 0 = above the paper edge).
    var magnetFrame: CGRect
    var placardFrame: CGRect
    var placardTilt: Double
    var badgeFrame: CGRect
    var title: TextBlock
    var meta: TextBlock
    var detail: TextBlock?
    var label: TextBlock?
    var quote: TextBlock?

    /// Fruit-face magnets from the app's own art (Assets.xcassets/Art), one per artwork, always the same one.
    static let magnets = ["mag-lemon", "mag-tomato", "mag-berry"]

    static func magnet(for id: UUID) -> String {
        let i = Int((wobble(id, salt: 11) + 1) / 2 * Double(magnets.count))
        return magnets[min(max(i, 0), magnets.count - 1)]
    }

    /// Size targets from the design review: the print is at least this share of the card width when the space
    /// allows (portrait art 62 %, landscape 78 %). The placard always wins: the art shrinks, the text never does.
    static func targetPrintShare(aspect: CGFloat) -> CGFloat { aspect >= 1 ? 0.78 : 0.62 }

    var placardInnerWidth: CGFloat { placardFrame.width - 2 * metrics.placardPad }

    private static func block(_ text: String, font: UIFont, leading: CGFloat, width: CGFloat, maxLines: Int) -> TextBlock {
        let lh = ShareCardType.lineHeight(font, leading: leading)
        let natural = ShareCardType.lineCount(text, font: font, width: width)
        let n = min(max(natural, 1), maxLines)
        // A little slack under the last line so Core Text's real line box never clips a line SwiftUI wants to draw.
        let height = ceil(CGFloat(n) * lh + font.pointSize * 0.12)
        return TextBlock(text: text, lines: n, maxLines: maxLines, height: height, lineSpacing: lh - font.lineHeight,
                         truncated: natural > maxLines)
    }

    static func make(content: ShareCardContent, artSize: CGSize, format: ShareCardFormat) -> ShareCardLayout {
        let m = ShareCardMetrics.for(format)
        let W = format.size.width, H = format.size.height
        let inner = m.placardWidth - 2 * m.placardPad

        // Placard text, top to bottom.
        let title = block(content.title, font: ShareCardType.uiFont(FMFont.display, size: m.titleSize),
                          leading: ShareCardType.titleLeading, width: inner, maxLines: m.titleMaxLines)
        let nameFont = ShareCardType.uiFont(FMFont.regular, size: m.nameSize)
        var metaText = content.artist
        var detail: TextBlock?
        if let ds = m.detailSize {
            let detailFont = ShareCardType.uiFont(FMFont.regular, size: ds)
            var d = content.term
            if let medium = content.medium {
                let joined = d.isEmpty ? medium : "\(d) · \(medium)"
                if ShareCardType.width(joined, font: detailFont) <= inner { d = joined }
            }
            if !d.isEmpty {
                detail = block(d, font: detailFont, leading: ShareCardType.bodyLeading, width: inner, maxLines: 1)
            }
        } else if !content.term.isEmpty {
            let joined = "\(metaText) · \(content.term)"
            if ShareCardType.width(joined, font: nameFont) <= inner { metaText = joined }
        }
        let meta = block(metaText, font: nameFont, leading: ShareCardType.bodyLeading, width: inner, maxLines: 1)
        var label: TextBlock?
        var quote: TextBlock?
        if let q = content.quote {
            if let ls = m.labelSize, !content.quoteLabel.isEmpty {
                label = block(content.quoteLabel, font: ShareCardType.uiFont(FMFont.bold, size: ls),
                              leading: ShareCardType.bodyLeading, width: inner, maxLines: 1)
            }
            quote = block(content.quoted(q), font: ShareCardType.uiFont(FMFont.display, size: m.quoteSize),
                          leading: ShareCardType.quoteLeading, width: inner,
                          maxLines: content.isChinese ? m.quoteMaxLines : m.quoteMaxLinesEnglish)
        }
        var placardH = 2 * m.placardPad + title.height + m.gapAfterTitle + meta.height
        if let detail { placardH += m.gapAfterName + detail.height }
        if let quote {
            placardH += 2 * m.dividerSpace + m.dividerWidth + quote.height
            if let label { placardH += label.height + m.gapAfterLabel }
        }
        placardH = ceil(placardH)

        // Brand badge, bottom right: capsule with Bibi's head + the wordmark.
        let wordFont = ShareCardType.uiFont(FMFont.display, size: m.badgeWordmark)
        let headW = m.badgeHead * 4 / 3
        let badgeW = ceil(2 * m.badgeHeight * 0.34 + headW + m.badgeHead * 0.25 + ShareCardType.width(content.brand, font: wordFont))
        let badge = CGRect(x: W - m.badgeRight - badgeW, y: H - m.badgeBottom - m.badgeHeight, width: badgeW, height: m.badgeHeight)

        // Tilts: the print ±1.5°, the placard 0.25–1° the other way. Leave room for the corners they swing out.
        let printTilt = wobble(content.id) * m.maxPrintTilt
        let placardTilt = (printTilt >= 0 ? -1.0 : 1.0) * (0.25 + 0.75 * abs(wobble(content.id, salt: 5)))
        let printSlack = ceil(m.maxPrintWidth / 2 * CGFloat(sin(abs(printTilt) * .pi / 180)))
        let placardSlack = ceil(m.placardWidth / 2 * CGFloat(sin(abs(placardTilt) * .pi / 180)))

        // The print gets everything between the top and the placard (stack sits just above the badge).
        let regionTop = m.printTop
        let regionBottom = badge.minY - m.badgeGap - placardSlack
        let gap = printSlack + m.printGap + placardSlack
        let availablePrintH = min(regionBottom - placardH - gap - regionTop, H * m.maxPrintHeightShare)
        let aspect = artSize.width > 0 && artSize.height > 0 ? artSize.width / artSize.height : 0.75
        let innerMaxW = m.maxPrintWidth - 2 * m.printPad
        let innerMaxH = max(120, availablePrintH - 2 * m.printPad)
        let artH = floor(min(innerMaxH, innerMaxW / aspect))
        let artW = floor(artH * aspect)
        let printW = artW + 2 * m.printPad, printH = artH + 2 * m.printPad
        // Width-bound art (landscape) leaves height over: split it above the print and below the placard.
        let leftover = max(0, regionBottom - regionTop - placardH - gap - printH)
        let printFrame = CGRect(x: ((W - printW) / 2).rounded(), y: (regionTop + leftover / 2).rounded(), width: printW, height: printH)
        let artFrame = printFrame.insetBy(dx: m.printPad, dy: m.printPad)
        let placardFrame = CGRect(x: ((W - m.placardWidth) / 2).rounded(), y: printFrame.maxY + gap,
                                  width: m.placardWidth, height: placardH)

        // Magnet on the top edge: at most 40 % of it over the paper, and never over more than the art's top 6 %.
        let magH = m.magnetSize
        let overlap = min(0.4 * magH, m.printPad + 0.06 * artH)
        let magX = printW / 2 + CGFloat(wobble(content.id, salt: 9)) * min(56, printW * 0.12) - magH / 2
        let magnetFrame = CGRect(x: magX.rounded(), y: (overlap - magH).rounded(.down), width: magH, height: magH)

        return ShareCardLayout(format: format, metrics: m, canvas: format.size, printFrame: printFrame, artFrame: artFrame,
                               printTilt: printTilt, magnet: magnet(for: content.id), magnetFrame: magnetFrame,
                               placardFrame: placardFrame, placardTilt: placardTilt, badgeFrame: badge,
                               title: title, meta: meta, detail: detail, label: label, quote: quote)
    }
}
