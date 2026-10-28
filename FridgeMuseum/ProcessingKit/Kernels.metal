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

// Illumination flatten with cast shadows (1.0.1). `closed` is the image after a small morphological closing (thin ink
// lines removed, light steps kept); e / hi / lo are the upsampled shadow layers (ShadowLayers.light / high / low).
// Near a light step (hi/lo ratio > ~1.2) a paper-looking pixel takes the light between lo and hi that its own
// brightness says it is under, so a hard shadow edge needs no blur band. Otherwise this is fmFlattenDivide with e.
float4 fmFlattenDivideShadow(sample_t s, sample_t closed, sample_t e, sample_t hi, sample_t lo, float gain) {
    const float3 Y = float3(0.299f, 0.587f, 0.114f);
    float ie = dot(closed.rgb, Y);
    float lh = dot(hi.rgb, Y);
    float ll = dot(lo.rgb, Y);
    float le = dot(e.rgb, Y);
    float atStep = smoothstep(1.12f, 1.25f, lh / max(ll, 0.001f));
    float t = clamp((ie - ll) / max(lh - ll, 0.001f), 0.0f, 1.0f);
    float chG = max(closed.r, max(closed.g, closed.b)) - min(closed.r, min(closed.g, closed.b));
    float chE = max(e.r, max(e.g, e.b)) - min(e.r, min(e.g, e.b));
    float paperLike = 1.0f - smoothstep(0.04f, 0.09f, chG - chE * ie / max(le, 0.001f));
    float notInk = smoothstep(0.80f, 0.95f, ie / max(ll, 0.001f));
    float3 between = mix(lo.rgb, hi.rgb, t);
    float3 bgc = mix(e.rgb, between, atStep * paperLike * notInk);
    float3 b = max(bgc, float3(0.02f));
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
