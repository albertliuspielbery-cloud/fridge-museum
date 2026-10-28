// Core Image color kernels in Metal Shading Language.
// Built with MTL_COMPILER_FLAGS = -fcikernel and MTLLINKER_FLAGS = -cikernel (see project.yml),
// so they end up in the app's default.metallib and are loaded by ProcessingKernels.swift.
// The CIContext's working color space is (non-linear) sRGB, so the math matches the web prototype exactly.

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

extern "C" {
namespace coreimage {

// Illumination flatten: divide by the estimated paper light (prototype: d / bg * gain, capped at 65535/40000).
// gain = 0.97 for white / paint-covered paper, 1 for coloured paper (its map is grey: light only).
float4 fmFlattenDivide(sample_t s, sample_t bg, float gain) {
    float3 b = max(bg.rgb, float3(0.02f));
    float3 c = min(s.rgb / b * gain, float3(1.638f));
    return float4(c, 1.0f);
}

// Chroma-protected whitening (prototype: whiten()).
// knee = 0.94 - 0.22 * strength; protect 0...1; vivid = vivid * 0.45. Coloured paper passes knee = 2 (no push to white).
float4 fmWhiten(sample_t s, float knee, float protect, float vivid) {
    float3 c = s.rgb;
    float y = dot(c, float3(0.299f, 0.587f, 0.114f));
    float chroma = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
    float w = smoothstep(knee, knee + 0.07f, y) * (1.0f - smoothstep(0.035f, 0.13f, chroma) * protect);
    c = c + (float3(1.0f) - c) * w;
    if (vivid > 0.0f) {
        float yy = dot(c, float3(0.299f, 0.587f, 0.114f));
        float f = 1.0f + vivid * (1.0f - w);
        c = float3(yy) + (c - float3(yy)) * f;
    }
    return float4(saturate(c), 1.0f);
}

}
}
