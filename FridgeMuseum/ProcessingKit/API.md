# ProcessingKit API (for the UI team)

Status: final, implemented on `feat/processing-sync` (CI green).

Brush strokes with turning: convert a touch at output-normalized `p` with `mapping.toStrokeSpace(p)` and the radius with
`mapping.strokeRadius(fromOutputRadius:)` (replaces the old `outputToSource` / warped-image math, which is wrong once turned).
Reference behaviour: web prototype `kidart.html` v0.9.0 (detectPaper, paperAspect, flatten/whiten, edgeFill,
removeSpecks, turning, craft parts / tap-to-keep, processNote).

Coordinates everywhere: **normalized 0…1, origin TOP-LEFT, y down**.
- "original" = the upright original photo (EXIF orientation applied), same space as `recipe.corners`.
- "output" = the rendered result image (`PreviewResult.output`), after rotation/straighten.
- "stroke space" = where `BrushStroke.points` live: flat → the perspective-corrected sheet *before* turning;
  craft → the original (upright source).

All pixel work runs inside `actor ImageProcessor` (never on the main actor). Every input/output type is `Sendable`.
Sources are decoded with ImageIO thumbnailing to ≤ 2400 px long edge, so 12–48 MP photos are safe.

## ProcessingRecipe (Codable; every new field has a default, old JSON decodes unchanged)

```swift
struct ProcessingRecipe: Codable, Sendable, Hashable {
    // existing: version, kind, corners, strength, protect, vivid, removeSpecks, sensitivity,
    //           background, shadow, strokes, caption
    var quarterTurns: Int = 0            // 0…3, clockwise (normalized mod 4 on decode)
    var straightenDegrees: Double = 0    // −15…15, positive = clockwise (clamped on decode)
    var removedPartSeeds: [CGPoint] = [] // craft: normalized ORIGINAL coords; a part containing a seed is removed
    var partsEdited: Bool = false        // craft: false = automatic edge-clutter drop still applies (see below)
    var autoTurns: Int? = nil            // 1.2.0: nil = upright check not run yet; else turns it applied (0 = none)

    func applyingAutoOrientation(_ e: AutoOrientation) -> ProcessingRecipe // once only; flat; never over a manual turn
    var isAutoTurned: Bool { get }       // auto turn applied and quarterTurns unchanged since (editor hint)

    var turnDegrees: Double { get }      // quarterTurns * 90 + straightenDegrees (clockwise)
    mutating func rotateClockwise()      // quarterTurns = (q + 1) % 4
    mutating func rotateCounterClockwise()
}
```
Turning applies to both kinds. Turning never invalidates strokes or seeds (they are stored unturned).

## Results

```swift
enum ProcessingNote: String, Codable, Sendable, CaseIterable {
    case paperNotFound, notWhitePaper, dotsKeptAsPattern, touchesEdge, autoDroppedEdgeParts, cutoutFallback
    var localizationKey: String { get }  // "processing.note.<rawValue>" – put these in Localizable.xcstrings
}

enum PaperMode: String, Codable, Sendable { case white, colored, paintCovered }   // flat only

struct CutoutPart: Identifiable, Sendable, Hashable {
    let id: Int               // stable within one PreviewResult (not across sensitivity changes – use seeds)
    let bounds: CGRect        // normalized in OUTPUT image (removed parts may extend outside 0…1)
    let seed: CGPoint         // normalized ORIGINAL coords (innermost point of the part)
    var isRemoved: Bool
    let originalBounds: CGRect // normalized ORIGINAL coords (for a "whole photo" pick view)
    let touchesEdge: Bool     // runs off the photo's edge
    let isMain: Bool          // the largest part
}

struct OutputMapping: Sendable, Hashable {
    let outputWidth: Int, outputHeight: Int
    static func identity(width: Int, height: Int) -> OutputMapping
    func toOriginal(_ p: CGPoint) -> CGPoint        // output-normalized → original-normalized (respects turn + warp)
    func fromOriginal(_ p: CGPoint) -> CGPoint?     // inverse (nil if it cannot be mapped)
    func toStrokeSpace(_ p: CGPoint) -> CGPoint     // output-normalized → BrushStroke point space
    func strokeRadius(fromOutputRadius r: Double) -> Double // r as fraction of output long edge → fraction of stroke-space long edge
}

struct PreviewResult: Sendable {
    var output: RenderedImage
    var before: RenderedImage?       // compare-slider "before", turned like the output, same pixel size
    var specksRemoved: Int
    var outputToSource: NormRect?    // DEPRECATED: craft crop rect, only meaningful when turnDegrees == 0. Use `mapping`.
    var parts: [CutoutPart]          // craft only; significant parts only; empty for flat / fallback
    var notes: [ProcessingNote]      // most important first; show `notes.first` on the hint line
    var paperMode: PaperMode?        // flat only (paintCovered = web "sparse": only light was evened out)
    var mapping: OutputMapping
    var partMap: PartMap?            // craft: coarse part labels used by the hit tests (no need to read it)
    var canPickParts: Bool { get }   // parts.count >= 2 → show the "點一下選主體" chip

    func partID(atOutputPoint p: CGPoint, toleranceCells: Int = 1) -> Int?   // output-normalized → part id
    func partID(atOriginalPoint p: CGPoint, toleranceCells: Int = 1) -> Int? // original-normalized → part id
}

struct ExportResult: Sendable {      // + notes
    var imageData: Data, thumbnailData: Data, pixelWidth: Int, pixelHeight: Int, specksRemoved: Int
    var notes: [ProcessingNote]
}

struct PaperDetection: Sendable, Hashable {
    enum Method: String, Sendable { case vision, detector, none }
    var quad: Quad
    var isGuess: Bool        // true → nothing convincing found, quad == .full (shows .paperNotFound)
    var method: Method
}
```

## ImageProcessor (actor)

```swift
static let previewMaxEdge = 1600, exportMaxEdge = 2400, sourceMaxEdge = 2400, thumbnailMaxEdge = 480
func detectCorners(id: UUID, originalData: Data) async -> Quad                 // unchanged
func detectPaper(id: UUID, originalData: Data) async -> PaperDetection         // same, with guess flag
func sourcePreview(id: UUID, originalData: Data, maxEdge: Int = previewMaxEdge) throws -> RenderedImage
func preview(id: UUID, originalData: Data, recipe: ProcessingRecipe,
             maxEdge: Int = previewMaxEdge, includeBefore: Bool = true) throws -> PreviewResult
func export(id: UUID, originalData: Data, recipe: ProcessingRecipe) throws -> ExportResult
func evict(id: UUID)
func estimateOrientation(id: UUID, originalData: Data, corners: Quad?) -> AutoOrientation   // 1.2.0, see below

nonisolated func partID(atOutputPoint p: CGPoint, in result: PreviewResult) -> Int?
nonisolated func originalPoint(fromOutputPoint p: CGPoint, in result: PreviewResult) -> CGPoint
```
Automatic upright turn (1.2.0, `AutoOrientation.swift`, flat only): on a ≤ 720 px perspective-corrected copy,
Vision fast text recognition in all four turns (decisive when one turn clearly wins), plus weak cues — upright drawn
faces and a colour prior (sky blue / sun yellow along the top, grass green along the bottom). Weak cues only count when
≥ 2 agree including a non-colour one, or all 3 colour cues agree, and none disagrees. `AutoOrientation.shouldApply`
is the go signal. Run once at intake (`AppModel.autoProcess`, or `EditModel.autoOrientIfNeeded` when the editor
opens first) and stored in `recipe.autoTurns`. The capture angle itself comes from gravity
(`CaptureKit/CaptureOrientation.swift`).

`recipe.corners == nil` on a flat render → the processor detects the paper itself (and may add `.paperNotFound`).

Cast shadows (1.0.1, flat only, no recipe field): when the sheet was found or the user set corners (quad ≠ full),
`IlluminationEstimator.model(_:shadows: true)` also runs `ShadowEstimator` on the cell grid. It finds shadowed paper
(smooth, darker, one level and tint per region, reaching the sheet's border or attached to a region that does, grown
over crayon / ink with each block's brightest 10 % of pixels)
and returns `FlattenModel.shadow` (light / high / low grids). `renderFlat` then divides with `fmFlattenDivideShadow`,
which at a shadow edge takes the light from the pixel itself (guide: a 4 px@1600 morphological closing, so thin ink
survives). No shadow found → `shadow == nil` and the output is exactly the v0.9 one. Not for paintCovered sheets; on coloured
paper the shadow gain is capped at 2.5× and the edge step is off (plain divide).

## Tap-to-keep (pure helpers, call on the main actor)

```swift
enum PartPicking {
    /// Toggle the part under a tap. Returns nil when it would remove the last kept part
    /// (show the "至少要留一個" toast). Sets `partsEdited = true` and rewrites `removedPartSeeds`
    /// from the result's current removed parts (so auto-dropped parts stay dropped unless tapped).
    static func toggle(partID: Int, in result: PreviewResult, recipe: ProcessingRecipe) -> ProcessingRecipe?
    /// "全部保留": clears seeds and disables the automatic drop.
    static func keepAll(_ recipe: ProcessingRecipe) -> ProcessingRecipe
}
```
Typical flow: tap at output point `p` → `if let id = result.partID(atOutputPoint: p), let r = PartPicking.toggle(partID: id, in: result, recipe: recipe) { recipe = r; render() }`.
Removed parts are cleared before brush strokes, so 補回作品 can still bring pixels back.

Automatic drop (web `autoPick`): when one part is ≥ 4× every other significant part, and every other part runs off the
photo edge and is not near the main part, those parts start removed and `.autoDroppedEdgeParts` is reported
(only while `partsEdited == false`).

## Notes (priority order) and suggested copy (from the web i18n table)

| case | when | zh-Hant | en |
|---|---|---|---|
| paperNotFound | flat, detector found nothing and the whole photo is used | 沒找到紙邊，先用整張照片，可用「裁切四角」調整 | Couldn’t find the paper’s edges, so the whole photo is used. Fix it in “Crop.” |
| notWhitePaper | flat, coloured / dark paper (paperMode == .colored) | 不是白紙，保留紙本來的顏色 | This isn’t white paper, so its original color is kept. |
| dotsKeptAsPattern | flat, removeSpecks on and > 14 inner dots | 小點很多像是圖案，沒有清掉 | Lots of little dots look like part of the design, so they were left alone. |
| cutoutFallback | craft, could not separate object (and no brush strokes) → original photo kept | 沒能分開作品和桌面，先保留原照片 | Couldn’t separate the craft from the table, so the original photo is kept. |
| autoDroppedEdgeParts | craft, automatic drop removed edge clutter | 已自動去掉邊緣的其他東西，點一下可以加回來 | Other things at the edge were removed. Use “Tap What to Keep” to bring them back. |
| touchesEdge | craft, a kept part touches the photo edge | 作品碰到照片邊緣，可能被切到 | The craft touches the edge of the photo and may be cut off. |

`paperMode == .paintCovered` has no contract note; the web text was 「顏料幾乎蓋滿紙，只輕調光線」 / “Paint covers most of
the paper, so only the lighting was adjusted.” — the UI may show it when `notes` is empty.
