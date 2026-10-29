import Foundation
import CoreGraphics

enum ArtworkKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case flat
    case craft

    var id: String { rawValue }
    var label: String { self == .flat ? "畫作" : "勞作" }
    var longLabel: String { self == .flat ? "平面畫作" : "立體勞作" }
}

/// sRGB color, 0...1.
struct RGBColor: Codable, Sendable, Hashable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// "#RRGGBB" or "RRGGBB".
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = Double((v >> 16) & 0xFF) / 255
        g = Double((v >> 8) & 0xFF) / 255
        b = Double(v & 0xFF) / 255
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

enum CraftBackground: String, Codable, Sendable, CaseIterable, Identifiable {
    case white, warm, gray, gradient

    var id: String { rawValue }
    var label: String {
        switch self {
        case .white: "純白"
        case .warm: "暖白"
        case .gray: "淺灰"
        case .gradient: "柔光漸層"
        }
    }
    /// Solid color (for gradient: the center color).
    var color: RGBColor {
        switch self {
        case .white, .gradient: RGBColor(hex: "#FFFFFF")!
        case .warm: RGBColor(hex: "#F1EFE9")!
        case .gray: RGBColor(hex: "#E6E9EE")!
        }
    }
    var edgeColor: RGBColor { self == .gradient ? RGBColor(hex: "#D9DDE3")! : color }
}

struct BrushStroke: Codable, Sendable, Hashable {
    enum Mode: String, Codable, Sendable {
        /// Flat artwork: paint paper white (coordinates in the corrected output).
        case paintWhite
        /// Craft: remove background (coordinates in the upright source image).
        case erase
        /// Craft: bring back object pixels.
        case restore
    }

    var mode: Mode
    /// Radius as a fraction of the long edge of the coordinate space the points live in.
    var radius: Double
    var points: [NormPoint]
}

/// Non-destructive edit recipe. The original photo is never modified; output = render(original, recipe).
/// Decoding is tolerant: missing keys fall back to defaults so old recipes keep working.
struct ProcessingRecipe: Codable, Sendable, Hashable {
    static let currentVersion = 1

    var version: Int = ProcessingRecipe.currentVersion
    var kind: ArtworkKind = .flat
    /// Paper corners in the upright original (flat only). nil = not detected yet (use full frame).
    var corners: Quad?
    /// 紙張變白 0...1
    var strength: Double = 0.6
    /// 保護淡色 0...1
    var protect: Double = 0.85
    /// 色彩鮮豔 0...1
    var vivid: Double = 0.15
    /// 自動清掉小黑點
    var removeSpecks: Bool = true
    /// 去背範圍 0...1 (craft)
    var sensitivity: Double = 0.5
    var background: CraftBackground = .white
    var shadow: Bool = true
    var strokes: [BrushStroke] = []
    /// Add name / age / date band under the image on export.
    var caption: Bool = false
    /// Quarter turns, clockwise, 0...3 (both kinds).
    var quarterTurns: Int = 0
    /// 拉直 −15...15 degrees, positive = clockwise (both kinds).
    var straightenDegrees: Double = 0
    /// Craft: parts the person removed, as points normalized in the ORIGINAL (upright) photo.
    /// A part of the cut-out is removed when it contains a seed.
    var removedPartSeeds: [CGPoint] = []
    /// Craft: false while the person has not picked parts yet; the processor then also drops edge clutter
    /// automatically (`ProcessingNote.autoDroppedEdgeParts`). `PartPicking` sets it.
    var partsEdited: Bool = false
    /// Automatic upright turn (1.2.0): nil = not checked yet; otherwise the quarter turns the content check applied
    /// at intake (0 = left as captured). Set once, so re-renders stay stable; a manual turn simply changes
    /// `quarterTurns` and wins.
    var autoTurns: Int?

    init(kind: ArtworkKind = .flat) {
        self.kind = kind
    }

    static func `default`(for kind: ArtworkKind) -> ProcessingRecipe { ProcessingRecipe(kind: kind) }

    enum CodingKeys: String, CodingKey {
        case version, kind, corners, strength, protect, vivid, removeSpecks, sensitivity, background, shadow, strokes, caption
        case quarterTurns, straightenDegrees, removedPartSeeds, partsEdited, autoTurns
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProcessingRecipe()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        kind = try c.decodeIfPresent(ArtworkKind.self, forKey: .kind) ?? d.kind
        corners = try c.decodeIfPresent(Quad.self, forKey: .corners)
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? d.strength
        protect = try c.decodeIfPresent(Double.self, forKey: .protect) ?? d.protect
        vivid = try c.decodeIfPresent(Double.self, forKey: .vivid) ?? d.vivid
        removeSpecks = try c.decodeIfPresent(Bool.self, forKey: .removeSpecks) ?? d.removeSpecks
        sensitivity = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? d.sensitivity
        background = (try? c.decodeIfPresent(CraftBackground.self, forKey: .background)) ?? d.background
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? d.shadow
        strokes = try c.decodeIfPresent([BrushStroke].self, forKey: .strokes) ?? d.strokes
        caption = try c.decodeIfPresent(Bool.self, forKey: .caption) ?? d.caption
        // Turning / parts fields are new in v0.9: tolerate missing or malformed values.
        let turns: Int? = try? c.decodeIfPresent(Int.self, forKey: .quarterTurns)
        quarterTurns = (((turns ?? d.quarterTurns) % 4) + 4) % 4
        let tilt: Double = (try? c.decodeIfPresent(Double.self, forKey: .straightenDegrees)) ?? d.straightenDegrees
        straightenDegrees = tilt.isFinite ? tilt.clamped(-15, 15) : 0
        removedPartSeeds = (try? c.decodeIfPresent([CGPoint].self, forKey: .removedPartSeeds)) ?? d.removedPartSeeds
        partsEdited = (try? c.decodeIfPresent(Bool.self, forKey: .partsEdited)) ?? d.partsEdited
        let auto: Int? = (try? c.decodeIfPresent(Int.self, forKey: .autoTurns)) ?? nil
        autoTurns = auto.map { (($0 % 4) + 4) % 4 }
    }

    /// Total turn in degrees, clockwise.
    var turnDegrees: Double { Double(quarterTurns) * 90 + straightenDegrees }

    mutating func rotateClockwise() { quarterTurns = (quarterTurns + 1) % 4 }
    mutating func rotateCounterClockwise() { quarterTurns = (quarterTurns + 3) % 4 }

    /// Records the one-time automatic upright check. Turns only when the content was sure and nobody has turned the
    /// artwork yet; a recipe that was already checked is returned unchanged.
    func applyingAutoOrientation(_ estimate: AutoOrientation) -> ProcessingRecipe {
        guard autoTurns == nil else { return self }
        var r = self
        if kind == .flat, estimate.shouldApply, quarterTurns == 0 {
            r.quarterTurns = ((estimate.quarterTurns % 4) + 4) % 4
            r.autoTurns = r.quarterTurns
        } else {
            r.autoTurns = 0
        }
        return r
    }

    /// The automatic turn is in effect (applied and not changed by hand since).
    var isAutoTurned: Bool {
        guard let autoTurns, autoTurns != 0 else { return false }
        return quarterTurns == autoTurns
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    static func decode(_ data: Data) throws -> ProcessingRecipe {
        try JSONDecoder().decode(ProcessingRecipe.self, from: data)
    }

    /// Strokes that apply to the current kind (flat strokes are tied to the warp, craft strokes to the source).
    var activeStrokes: [BrushStroke] {
        strokes.filter { kind == .flat ? $0.mode == .paintWhite : $0.mode != .paintWhite }
    }
}

/// What the automatic processing could not do well on this photo (port of the prototype's processNote).
/// `PreviewResult.notes` lists them most important first.
enum ProcessingNote: String, Codable, Sendable, CaseIterable {
    case paperNotFound
    case notWhitePaper
    case dotsKeptAsPattern
    case touchesEdge
    case autoDroppedEdgeParts
    case cutoutFallback

    /// String Catalog key (owned by the UI team): "processing.note.<case>".
    var localizationKey: String { "processing.note.\(rawValue)" }
}

/// How the flat pipeline treated the paper (prototype flatten modes "white" / "keep" / "sparse").
enum PaperMode: String, Codable, Sendable {
    /// White paper: light evened out and paper pushed to white.
    case white
    /// Coloured or dark paper: only the light is evened out, the paper keeps its colour.
    case colored
    /// Paint covers most of the sheet: only a gentle, coarse light correction.
    case paintCovered
}
