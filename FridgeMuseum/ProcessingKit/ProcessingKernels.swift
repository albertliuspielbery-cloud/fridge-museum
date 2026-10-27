import Foundation
import CoreImage

/// Custom Core Image kernels compiled from Kernels.metal into default.metallib.
/// If loading fails (e.g. build flags missing), ImageProcessor falls back to built-in CIFilter chains.
struct ProcessingKernels {
    let flattenDivide: CIColorKernel
    let whiten: CIColorKernel

    static func load(bundle: Bundle = .main) -> ProcessingKernels? {
        guard let url = bundle.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        do {
            let divide = try CIColorKernel(functionName: "fmFlattenDivide", fromMetalLibraryData: data)
            let whiten = try CIColorKernel(functionName: "fmWhiten", fromMetalLibraryData: data)
            return ProcessingKernels(flattenDivide: divide, whiten: whiten)
        } catch {
            return nil
        }
    }
}
