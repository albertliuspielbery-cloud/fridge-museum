import Foundation
import Observation
import UIKit

/// Editor state for one artwork. Re-renders previews from (original, recipe) via ImageProcessor;
/// the recipe is written back to the Artwork when the editor commits.
@MainActor
@Observable
final class EditModel {
    let artworkID: UUID
    let originalData: Data

    var recipe: ProcessingRecipe
    /// Last recipe written to the Artwork; the editor is dirty when they differ.
    private(set) var savedRecipe: ProcessingRecipe
    var output: UIImage?
    var before: UIImage?
    var source: UIImage?
    var outputToSource: NormRect?
    /// Last preview: output↔original mapping (strokes, taps), craft parts, processing notes.
    var result: PreviewResult?
    var specksRemoved = 0
    var isRendering = false
    var failed = false

    let processor = ImageProcessor.shared
    @ObservationIgnored private var renderTask: Task<Void, Never>?

    /// The one-time upright check may run in this editor: a capture never rendered when it opened, not a sample.
    /// Decided once from the editor's own copy (the background may write the turn later; the cached estimate then
    /// gives the editor the same verdict).
    private let mayAutoOrient: Bool
    @ObservationIgnored private var orientTask: Task<Bool, Never>?

    init(artwork: Artwork) {
        artworkID = artwork.id
        // iCloud: not on an artwork synced from another device (that device checks it; see owesOrientationCheck).
        mayAutoOrient = artwork.renderedImageData == nil && !artwork.isSample && !DemoMode.isActive
            && (SyncOrigin.isLocal(artwork.originDeviceID, device: DeviceIdentity.storedID) || artwork.isOwnPending)
        originalData = artwork.originalImageData ?? Data()
        var r = artwork.recipe
        r.kind = artwork.kind
        recipe = r
        savedRecipe = r
    }

    var isDirty: Bool { recipe != savedRecipe }

    func markSaved() { savedRecipe = recipe }

    /// Starts a preview render and waits for it (the editor's first preview, before the upright check).
    func renderAndWait() async {
        render()
        await renderTask?.value
    }

    /// Debounced preview render; a newer call cancels the older one.
    func render(debounceMilliseconds: Int = 0) {
        renderTask?.cancel()
        let recipe = self.recipe
        let id = artworkID
        let data = originalData
        let processor = self.processor
        isRendering = true
        renderTask = Task {
            if debounceMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(debounceMilliseconds))
                if Task.isCancelled { return }
            }
            do {
                let result = try await processor.preview(id: id, originalData: data, recipe: recipe)
                if Task.isCancelled { return }
                self.output = UIImage(cgImage: result.output.cgImage)
                self.before = result.before.map { UIImage(cgImage: $0.cgImage) }
                self.outputToSource = result.outputToSource
                self.result = result
                self.specksRemoved = result.specksRemoved
                self.failed = false
            } catch {
                if Task.isCancelled { return }
                self.failed = true
            }
            self.isRendering = false
        }
    }

    func loadSource() async {
        guard source == nil else { return }
        if let img = try? await processor.sourcePreview(id: artworkID, originalData: originalData) {
            source = UIImage(cgImage: img.cgImage)
        }
    }

    func setKind(_ kind: ArtworkKind) async {
        guard recipe.kind != kind else { return }
        recipe.kind = kind
        if kind == .flat && recipe.corners == nil {
            isRendering = true
            recipe.corners = await processor.detectCorners(id: artworkID, originalData: originalData)
        }
        output = nil
        before = nil
        render()
    }

    /// The one-time upright check for a capture opened in the editor. Runs once (later calls await the same run —
    /// keep / save wait for it so the stored recipe and the editor agree); returns true when it turned the artwork
    /// (then render again). ImageProcessor caches the estimate, so Vision runs once even if the intake asks too.
    /// A manual turn made meanwhile wins.
    @discardableResult
    func autoOrient() async -> Bool {
        if let orientTask { return await orientTask.value }
        let task = Task { await self.runAutoOrient() }
        orientTask = task
        return await task.value
    }

    private func runAutoOrient() async -> Bool {
        guard mayAutoOrient, recipe.kind == .flat, recipe.autoTurns == nil else { return false }
        let turnsBefore = recipe.quarterTurns
        let corners: Quad
        if let known = recipe.corners {
            corners = known
        } else {
            corners = await processor.detectCorners(id: artworkID, originalData: originalData)
        }
        let estimate = await processor.estimateOrientation(id: artworkID, originalData: originalData, corners: corners)
        guard recipe.autoTurns == nil else { return false }
        // Always record the check (also when the kind was switched meanwhile: a craft records 0), so the editor and
        // the stored recipe agree.
        if recipe.kind == .flat, recipe.corners == nil { recipe.corners = corners }
        guard recipe.quarterTurns == turnsBefore else {
            recipe.autoTurns = 0      // turned by hand meanwhile: their choice sticks
            return false
        }
        recipe = recipe.applyingAutoOrientation(estimate)
        return recipe.quarterTurns != turnsBefore
    }

    /// Show 「已自動轉正」 on the hint line.
    var isAutoTurned: Bool { recipe.kind == .flat && recipe.isAutoTurned }

    func redetectCorners() async {
        isRendering = true
        recipe.corners = await processor.detectCorners(id: artworkID, originalData: originalData)
        cornersChanged()
    }

    func useWholePhoto() {
        recipe.corners = .full
        cornersChanged()
    }

    /// Flat strokes live in the corrected image, so they no longer line up after the corners move.
    func cornersChanged() {
        recipe.strokes.removeAll { $0.mode == .paintWhite }
        render()
    }

    func addStroke(_ stroke: BrushStroke) {
        recipe.strokes.append(stroke)
        render()
    }

    var hasActiveStrokes: Bool { !recipe.activeStrokes.isEmpty }

    func undoStroke() {
        let active = recipe.activeStrokes
        guard let last = active.last, let idx = recipe.strokes.lastIndex(of: last) else { return }
        recipe.strokes.remove(at: idx)
        render()
    }

    func clearStrokes() {
        let kind = recipe.kind
        recipe.strokes.removeAll { kind == .flat ? $0.mode == .paintWhite : $0.mode != .paintWhite }
        render()
    }

    var parts: [CutoutPart] { recipe.kind == .craft ? (result?.parts ?? []) : [] }
    var canPickParts: Bool { recipe.kind == .craft && (result?.canPickParts ?? false) }
    var notes: [ProcessingNote] { result?.notes ?? [] }

    /// Turning (both kinds). Strokes and part seeds are stored unturned, so nothing is invalidated.
    func rotate(clockwise: Bool) {
        if clockwise { recipe.rotateClockwise() } else { recipe.rotateCounterClockwise() }
        render()
    }

    func straighten(_ degrees: Double) {
        recipe.straightenDegrees = degrees.clamped(-15, 15)
        render(debounceMilliseconds: 90)
    }

    /// Tap-to-keep: toggles the craft part under an output-normalized point. Returns false when the tap would
    /// remove the last kept part (nothing changes then).
    @discardableResult
    func togglePart(atOutputPoint p: CGPoint) -> Bool? {
        guard let result, let id = result.partID(atOutputPoint: p) else { return nil }
        guard let r = PartPicking.toggle(partID: id, in: result, recipe: recipe) else { return false }
        recipe = r
        render()
        return true
    }

    func keepAllParts() {
        recipe = PartPicking.keepAll(recipe)
        render()
    }

    func evictCaches() async {
        await processor.evict(id: artworkID)
    }
}
