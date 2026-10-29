import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FridgeMuseum

/// 分享卡片: layout decisions (ShareCardLayout) and a render smoke test (ShareCardRenderer → 1080-wide opaque image).
struct ShareCardTests {
    static let fixedID = UUID(uuidString: "6F1C2B9E-3A4D-4E5F-8A7B-1C2D3E4F5A6B")!

    static let shortQuote = "這是我生日那天，大家一起玩氣球！"
    static let longQuote = "這是我生日那天，爸爸媽媽、爺爺奶奶和小美都來了，我們一起吹了好多好多顏色的氣球，還有一個超級大的蛋糕，我最喜歡紅色的那顆！"
    static let title20 = "我和小狗在公園裡追著彩色的大氣球跑來跑去"
    static let title30 = "我和小狗在公園裡追著彩色的大氣球跑來跑去，最後一起躺在草地上看雲"

    static func zh(title: String = "氣球派對", quote: String? = shortQuote, craft: Bool = false, id: UUID = fixedID,
                   medium: String? = "彩色筆、紙") -> ShareCardContent {
        ShareCardContent(id: id, isCraft: craft, title: title, artist: "小明 · 5歲10個月", term: "114學年 下學期 · 大班",
                         medium: medium, quote: quote, quoteLabel: "孩子說", brand: "冰箱美術館", isChinese: true)
    }

    static func en(quote: String? = "It was my birthday and we all played with balloons in the backyard until the sun went down, and then we had cake!") -> ShareCardContent {
        ShareCardContent(id: fixedID, isCraft: false, title: "Balloon Party", artist: "Mia · 5 yrs 10 mos",
                         term: "Spring 2026 · Kindergarten", medium: "Markers", quote: quote,
                         quoteLabel: "In Mia’s words", brand: "My Fridge Museum", isChinese: false)
    }

    static let portraitArt = CGSize(width: 1500, height: 2000)
    static let landscapeArt = CGSize(width: 2000, height: 1500)
    static let craftArt = CGSize(width: 1800, height: 1650)

    /// Geometry every card must satisfy: nothing off the card, placard margins, 48 px between print and placard,
    /// placard above the badge, art inside the white print.
    private func checkInvariants(_ l: ShareCardLayout, sourceLocation: SourceLocation = #_sourceLocation) {
        let W = l.canvas.width, H = l.canvas.height
        let m = l.metrics
        #expect(l.printFrame.minX >= 64 && l.printFrame.maxX <= W - 64, "print inside the side margins", sourceLocation: sourceLocation)
        #expect(l.printFrame.minY >= m.printTop - 0.5, sourceLocation: sourceLocation)
        #expect(l.placardFrame.minX >= 64 && l.placardFrame.maxX <= W - 64, "placard outer margin ≥ 64", sourceLocation: sourceLocation)
        #expect(l.placardFrame.minY - l.printFrame.maxY >= 48, "48 px gap print → placard", sourceLocation: sourceLocation)
        #expect(l.placardFrame.maxY <= l.badgeFrame.minY, "placard above the badge", sourceLocation: sourceLocation)
        #expect(l.badgeFrame.maxX <= W && l.badgeFrame.maxY <= H, sourceLocation: sourceLocation)
        #expect(l.printFrame.contains(l.artFrame), "art stays on the white print", sourceLocation: sourceLocation)
        #expect(l.artFrame.minX - l.printFrame.minX >= m.printPad - 0.5, sourceLocation: sourceLocation)
        #expect(abs(l.printTilt) <= 1.5 && abs(l.placardTilt) <= 1.0, sourceLocation: sourceLocation)
        #expect(l.title.lines <= 2 && l.title.lines >= 1, sourceLocation: sourceLocation)
        // Magnet: on the top edge, at most 40 % over the paper and never over more than the art's top 6 %.
        let overlap = l.magnetFrame.maxY
        #expect(overlap > 0, "magnet touches the paper", sourceLocation: sourceLocation)
        #expect(overlap <= 0.4 * l.magnetFrame.height + 0.5, sourceLocation: sourceLocation)
        #expect(overlap <= m.printPad + 0.06 * l.artFrame.height + 0.5, sourceLocation: sourceLocation)
        #expect(l.printFrame.minY + l.magnetFrame.minY >= 0, "magnet on the card", sourceLocation: sourceLocation)
    }

    // MARK: Art box

    @Test func portraitArtTakesAllTheHeightLeft() {
        let l = ShareCardLayout.make(content: Self.zh(), artSize: Self.portraitArt, format: .portrait)
        checkInvariants(l)
        #expect(abs(l.artFrame.width / l.artFrame.height - 0.75) < 0.01, "aspect kept")
        // Height-bound: the print reaches down to the 48 px gap (no leftover space).
        let gapBelow = l.placardFrame.minY - l.printFrame.maxY
        #expect(gapBelow < 48 + 30)
        #expect(l.printFrame.width < l.metrics.maxPrintWidth)
    }

    @Test func landscapeArtIsWideWhenThereIsRoom() {
        let l = ShareCardLayout.make(content: Self.zh(quote: nil), artSize: Self.landscapeArt, format: .portrait)
        checkInvariants(l)
        #expect(l.printFrame.width >= 0.78 * 1080, "landscape print ≥ 78 % of the card width")
        #expect(ShareCardLayout.targetPrintShare(aspect: 4.0 / 3) == 0.78)
        #expect(ShareCardLayout.targetPrintShare(aspect: 0.75) == 0.62)
    }

    @Test func landscapeWithQuoteStillFitsThePlacard() {
        let l = ShareCardLayout.make(content: Self.zh(quote: Self.longQuote), artSize: Self.landscapeArt, format: .portrait)
        checkInvariants(l)
        #expect(l.quote?.lines == 3)
    }

    @Test func craftStaysOnTheWhitePrint() {
        let l = ShareCardLayout.make(content: Self.zh(craft: true), artSize: Self.craftArt, format: .portrait)
        checkInvariants(l)
        #expect(l.printFrame.width - l.artFrame.width == 2 * l.metrics.printPad)
        #expect(l.printFrame.height - l.artFrame.height == 2 * l.metrics.printPad)
    }

    @Test func tallAndPanoramaArtStayInside() {
        for size in [CGSize(width: 600, height: 2400), CGSize(width: 3000, height: 800), CGSize(width: 0, height: 0)] {
            for format in ShareCardFormat.allCases {
                checkInvariants(ShareCardLayout.make(content: Self.zh(quote: Self.longQuote), artSize: size, format: format))
            }
        }
    }

    // MARK: Text

    @Test func titleWrapsToTwoLinesThenTruncates() {
        let short = ShareCardLayout.make(content: Self.zh(), artSize: Self.portraitArt, format: .portrait)
        #expect(short.title.lines == 1 && !short.title.truncated)
        let twenty = ShareCardLayout.make(content: Self.zh(title: Self.title20), artSize: Self.portraitArt, format: .portrait)
        #expect(twenty.title.lines == 2)
        #expect(twenty.title.maxLines == 2)
        let thirty = ShareCardLayout.make(content: Self.zh(title: Self.title30), artSize: Self.portraitArt, format: .portrait)
        #expect(thirty.title.lines == 2 && thirty.title.truncated)
        // Text never shrinks: a longer title costs art height, not font size.
        #expect(thirty.artFrame.height < short.artFrame.height)
        #expect(thirty.metrics.titleSize == short.metrics.titleSize)
    }

    @Test func quoteIsCappedAtThreeLinesFourInEnglish() {
        let sixty = ShareCardLayout.make(content: Self.zh(quote: String(Self.longQuote.prefix(60))), artSize: Self.portraitArt, format: .portrait)
        #expect((sixty.quote?.lines ?? 0) >= 2 && (sixty.quote?.lines ?? 0) <= 3)
        let long = ShareCardLayout.make(content: Self.zh(quote: Self.longQuote + Self.longQuote), artSize: Self.portraitArt, format: .portrait)
        #expect(long.quote?.lines == 3 && long.quote?.truncated == true)
        let english = ShareCardLayout.make(content: Self.en(quote: String(repeating: "We played with balloons. ", count: 12)),
                                           artSize: Self.portraitArt, format: .portrait)
        #expect(english.quote?.maxLines == 4 && english.quote?.lines == 4)
        #expect(english.label?.text == "In Mia’s words")
        checkInvariants(english)
    }

    @Test func noQuoteShrinksThePlacardAndGrowsTheArt() {
        let with = ShareCardLayout.make(content: Self.zh(), artSize: Self.portraitArt, format: .portrait)
        let without = ShareCardLayout.make(content: Self.zh(quote: nil), artSize: Self.portraitArt, format: .portrait)
        #expect(without.quote == nil && without.label == nil)
        #expect(with.quote != nil && with.label != nil)
        #expect(without.placardFrame.height < with.placardFrame.height - 100)
        #expect(without.artFrame.height > with.artFrame.height + 100)
        // No leftover gap: height-bound art still sits 48 px (+ tilt room) above the placard.
        #expect(without.placardFrame.minY - without.printFrame.maxY < 48 + 30)
        checkInvariants(without)
        // Whitespace-only notes count as no note.
        #expect(Self.zh(quote: " \n\u{3000} ").quote == nil)
    }

    @Test func mediumOnlyWhenItFits() {
        let fits = ShareCardLayout.make(content: Self.zh(), artSize: Self.portraitArt, format: .portrait)
        #expect(fits.detail?.text == "114學年 下學期 · 大班 · 彩色筆、紙")
        let tooLong = ShareCardLayout.make(content: Self.zh(medium: "水彩、蠟筆、色鉛筆、亮片、不織布、毛根、紙盤、膠水"),
                                           artSize: Self.portraitArt, format: .portrait)
        #expect(tooLong.detail?.text == "114學年 下學期 · 大班")
        #expect(tooLong.detail?.lines == 1)
    }

    @Test func fullWidthSpaceIsNeverRendered() {
        let c = ShareCardContent(id: Self.fixedID, isCraft: false, title: "我的\u{3000}家", artist: "小明\u{3000}·\u{3000}5歲",
                                 term: "114學年\u{3000}上學期", medium: "\u{3000}", quote: "第一行\n第二行\u{3000}完",
                                 quoteLabel: "孩子說", brand: "冰箱美術館", isChinese: true)
        for s in [c.title, c.artist, c.term, c.quote ?? "", c.quoteLabel, c.brand] {
            #expect(!s.contains("\u{3000}") && !s.contains("\n"))
        }
        #expect(c.title == "我的 家")
        #expect(c.medium == nil)
        #expect(c.quote == "第一行 第二行 完")
    }

    // MARK: Magnet

    @Test func magnetIsDeterministicFromTheArtworkID() {
        #expect(ShareCardLayout.magnet(for: Self.fixedID) == ShareCardLayout.magnet(for: Self.fixedID))
        var seen = Set<String>()
        for i in 0..<300 {
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i))!
            let name = ShareCardLayout.magnet(for: id)
            #expect(ShareCardLayout.magnets.contains(name))
            #expect(ShareCardLayout.magnet(for: id) == name)
            seen.insert(name)
        }
        #expect(seen.count == ShareCardLayout.magnets.count, "every fruit shows up")
        let a = ShareCardLayout.make(content: Self.zh(), artSize: Self.portraitArt, format: .portrait)
        let b = ShareCardLayout.make(content: Self.zh(), artSize: Self.portraitArt, format: .portrait)
        #expect(a == b, "same artwork → same card")
    }

    // MARK: Square

    @Test func squareIsACompactVerticalStack() {
        for content in [Self.zh(), Self.zh(quote: nil), Self.en(), Self.zh(title: Self.title30, quote: Self.longQuote)] {
            for art in [Self.portraitArt, Self.landscapeArt, Self.craftArt] {
                let l = ShareCardLayout.make(content: content, artSize: art, format: .square)
                checkInvariants(l)
                #expect(l.canvas == CGSize(width: 1080, height: 1080))
                #expect(l.printFrame.height <= 0.72 * 1080 + 0.5)
                #expect(l.title.lines == 1)
                #expect((l.quote?.lines ?? 0) <= 2)
                #expect(l.detail == nil && l.label == nil)
            }
        }
    }

    // MARK: Render smoke test

    private static func art(_ size: CGSize) throws -> RenderedImage {
        let w = Int(size.width), h = Int(size.height)
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        return RenderedImage(cgImage: try #require(ctx.makeImage()))
    }

    /// Alpha (0…255) at a few points, drawn into an RGBA bitmap (an opaque image stays 255 everywhere).
    private static func alphas(_ image: CGImage) throws -> [UInt8] {
        let W = image.width, H = image.height
        var px = [UInt8](repeating: 0, count: W * H * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        try #require(drawn)
        let points = [(0, 0), (W - 1, 0), (0, H - 1), (W - 1, H - 1), (W / 2, H / 2), (W / 2, 20)]
        return points.map { px[($0.1 * W + $0.0) * 4 + 3] }
    }

    @MainActor
    @Test(arguments: ["portrait", "landscape", "craft", "noQuote", "title20", "quote60", "english"])
    func rendersOpaqueCardsAt1080(_ name: String) async throws {
        let content: ShareCardContent
        var size = Self.portraitArt
        switch name {
        case "landscape": content = Self.zh(); size = Self.landscapeArt
        case "craft": content = Self.zh(craft: true); size = Self.craftArt
        case "noQuote": content = Self.zh(quote: nil)
        case "title20": content = Self.zh(title: Self.title20)
        case "quote60": content = Self.zh(quote: String(Self.longQuote.prefix(60)))
        case "english": content = Self.en()
        default: content = Self.zh()
        }
        let art = try Self.art(size)
        for format in ShareCardFormat.allCases {
            let card = try #require(ShareCardRenderer.render(content, art: art, format: format), "\(name) \(format)")
            #expect(card.width == 1080, "\(name) \(format)")
            #expect(card.height == Int(format.size.height), "\(name) \(format)")
            let alphas = try Self.alphas(card.cgImage)
            #expect(alphas.allSatisfy { $0 == 255 }, "\(name) \(format) opaque")
        }
        // The share path end to end: JPEG decodes to 1080 × 1350.
        let artJPEG = try #require(ImageEncoding.jpegData(art.cgImage, quality: 0.9))
        let rendered = await ShareCardRenderer.jpeg(content, artData: artJPEG, format: .portrait)
        let jpeg = try #require(rendered)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 1080 && decoded.height == 1350)
    }
}
