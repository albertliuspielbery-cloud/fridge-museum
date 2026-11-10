import CoreGraphics
import Foundation
import ImageIO
import Testing
import Vision
@testable import FridgeMuseum

/// 自動標籤 (1.4.0) feasibility probe: what Apple's on-device classifier says about children's artwork. It never
/// fails; it prints "AUTOTAG-PROBE" lines into the CI log so the labels and confidences can be judged before the
/// feature is built.
struct AutoTagProbeTests {
    private func classify(_ image: CGImage) throws -> [(String, Float)] {
        let request = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).filter { $0.confidence > 0.05 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(15)
            .map { ($0.identifier, $0.confidence) }
    }

    private func report(_ name: String, _ image: CGImage?) {
        guard let image else {
            print("AUTOTAG-PROBE \(name): no image")
            return
        }
        do {
            let labels = try classify(image)
            let line = labels.map { "\($0.0)=\(String(format: "%.2f", $0.1))" }.joined(separator: ", ")
            print("AUTOTAG-PROBE \(name): \(line.isEmpty ? "(nothing above 0.05)" : line)")
        } catch {
            print("AUTOTAG-PROBE \(name): error \(error)")
        }
    }

    private func bundled(_ name: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    @Test func printWhatTheClassifierSees() {
        report("sample-flat (child's drawing photo)", bundled("sample-flat"))
        report("sample-craft (child's craft photo)", bundled("sample-craft"))
        for piece in CraftSketch.Piece.allCases {
            report("sketch-\(piece)", CraftSketch.image(piece, on: .white, height: 320).cgImage)
        }
    }
}
