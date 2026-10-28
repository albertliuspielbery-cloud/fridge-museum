import Foundation
import CoreImage

/// Custom Core Image kernels compiled from Kernels.metal into default.metallib.
/// If loading fails (e.g. build flags missing), ImageProcessor falls back to built-in CIFilter chains.
struct ProcessingKernels {
    let flattenDivide: CIColorKernel
    let whiten: CIColorKernel
    /// Divide with cast-shadow layers (1.0.1); nil if missing from the library (falls back to `flattenDivide`).
    let flattenDivideShadow: CIColorKernel?

    static func load(bundle: Bundle = .main) -> ProcessingKernels? {
        guard let url = bundle.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { return nil }
        do {
            let divide = try CIColorKernel(functionName: "fmFlattenDivide", fromMetalLibraryData: data)
            let whiten = try CIColorKernel(functionName: "fmWhiten", fromMetalLibraryData: data)
            let shadow = try? CIColorKernel(functionName: "fmFlattenDivideShadow", fromMetalLibraryData: data)
            return ProcessingKernels(flattenDivide: divide, whiten: whiten, flattenDivideShadow: shadow)
        } catch {
            return nil
        }
    }
}
