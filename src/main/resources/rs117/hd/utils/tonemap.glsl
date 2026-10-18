/*
 * AgX tonemap.
 * Reference: Filament (MIT) and three.js port.
 *   https://github.com/google/filament/blob/main/filament/src/ToneMapper.cpp
 *   https://github.com/mrdoob/three.js/blob/master/src/renderers/shaders/ShaderChunk/tonemapping_pars_fragment.glsl.js
 *
 * Pipeline: input matrix (REC709 -> AgX) -> per-channel sigmoid -> "Punchy" look -> output matrix.
 * Input is expected to be linear scene-referred (HDR, >0).
 * Output is linear display-referred in [0, 1].
 */
#pragma once

#include <uniforms/global.glsl>
#include <utils/color_utils.glsl>

const mat3 AGX_INPUT_MATRIX = mat3(
    0.842479062253094, 0.0784335999999992, 0.0792237451477643,
    0.0423282422610123, 0.878468636469772, 0.0791661274605434,
    0.0423756549057051, 0.0784336, 0.879142973793104
);

const mat3 AGX_OUTPUT_MATRIX = mat3(
     1.19687900512017, -0.0980208811401368, -0.0990297440797205,
    -0.0528968517574562, 1.15190312990417, -0.0989611768448433,
    -0.0529716355144438, -0.0980434501171241, 1.15107367264116
);

// AGX_MIN_EV / AGX_MAX_EV come from the global UBO (agxMinEv / agxMaxEv) so
// they're runtime-tunable via the AgX min/max EV config sliders.

// Polynomial fit of the AgX sigmoid curve in log2 space.
vec3 agxDefaultContrastApprox(vec3 x) {
    vec3 x2 = x * x;
    vec3 x4 = x2 * x2;
    return + 15.5 * x4 * x2
           - 40.14 * x4 * x
           + 31.96 * x4
           - 6.868 * x2 * x
           + 0.4298 * x2
           + 0.1191 * x
           - 0.00232;
}

// AgX "Punchy" look: luma-based saturation + per-channel power curve, applied
// to the post-sigmoid linear value before the output matrix. agxPunchSaturation
// and agxPunchPower come from the UBO; both at 1.0 are no-op.
vec3 agxLookPunchy(vec3 ldr) {
    float luma = dot(ldr, REC709_LUMA);
    ldr = max(ldr, vec3(0.0)); // pow(neg, non-int) -> NaN
    vec3 graded = pow(ldr, vec3(uboGlobal.agxPunchPower));
    return luma + uboGlobal.agxPunchSaturation * (graded - luma);
}

// Inverses below mirror ColorUtils.agxInverseToHdrInput / agxLegacyInverseToHdrInput
// (keep in sync). The Java versions drive the fallback clear color in
// ZoneRenderer.scenePass; these let sky_frag/star_frag write scene-referred values
// that tonemap_frag maps back to the sky's authored display color. See
// docs/agx-legacy-mix.md for the overall AgX + legacy-mix design.

// Numerical inverse of the AgX sigmoid via bisection.
float agxInverseSigmoid(float target) {
    float lo = 0.0, hi = 1.0;
    for (int i = 0; i < 24; i++) {
        float mid = (lo + hi) * 0.5;
        if (agxDefaultContrastApprox(vec3(mid)).x < target) lo = mid; else hi = mid;
    }
    return (lo + hi) * 0.5;
}

// Inverse of agxLookPunchy. Luma couples the channels, so iterate.
vec3 agxInverseLookPunchy(vec3 graded) {
    float sat = uboGlobal.agxPunchSaturation;
    if (sat < 1e-3)
        return graded; // Forward collapses to grey, inverse is underdetermined
    float invPow = 1.0 / uboGlobal.agxPunchPower;
    vec3 ldr = graded;
    float luma = dot(ldr, REC709_LUMA);
    for (int i = 0; i < 8; i++) {
        ldr = pow(max((graded - (1.0 - sat) * luma) / sat, vec3(0.0)), vec3(invPow));
        luma = dot(ldr, REC709_LUMA);
    }
    return ldr;
}

// Pre-exposure HDR input that agxTonemap displays as targetDisplayLinear.
vec3 agxInverseTonemap(vec3 targetDisplayLinear) {
    vec3 v = AGX_INPUT_MATRIX * targetDisplayLinear;
    v = agxInverseLookPunchy(v);
    for (int i = 0; i < 3; i++)
        v[i] = exp2(uboGlobal.agxMinEv + agxInverseSigmoid(v[i]) * (uboGlobal.agxMaxEv - uboGlobal.agxMinEv));
    // Saturated targets (e.g. sunset orange) can require slightly negative scene RGB.
    // Keep it: agxTonemap accepts negatives, so clamping here would shift the hue.
    vec3 scene = AGX_OUTPUT_MATRIX * v;
    return scene / max(uboGlobal.exposure, 1e-6);
}

// Inverse of tonemap_frag's luminance-scaled hard-clip legacy target.
vec3 agxLegacyInverseTonemap(vec3 targetDisplayLinear) {
    float invExp = 1.0 / max(uboGlobal.exposure, 1e-6);
    float lumTarget = dot(targetDisplayLinear, REC709_LUMA);
    if (lumTarget < 1e-6)
        return max(targetDisplayLinear, vec3(0.0)) * invExp;
    float lumNorm = agxInverseSigmoid(lumTarget);
    float lum = exp2(uboGlobal.agxMinEv + lumNorm * (uboGlobal.agxMaxEv - uboGlobal.agxMinEv));
    return max(targetDisplayLinear * (lum / lumTarget), vec3(0.0)) * invExp;
}

// Scene-referred value that tonemap_frag displays as targetDisplayLinear, lerped
// toward the legacy inverse by agxLegacyMix (exact at mix 0 and 1).
vec3 agxInverseForDisplay(vec3 targetDisplayLinear) {
    vec3 hdr = agxInverseTonemap(targetDisplayLinear);
    if (uboGlobal.agxLegacyMix > 0.0)
        hdr = mix(hdr, agxLegacyInverseTonemap(targetDisplayLinear), uboGlobal.agxLegacyMix);
    return hdr;
}

vec3 agxTonemap(vec3 hdr) {
    // Move to AgX color space. Negative channels are left in: the input matrix
    // pulls slightly out-of-gamut colors back in, and agxInverseTonemap relies on
    // this to reach saturated targets. The max below still guards the log.
    vec3 v = AGX_INPUT_MATRIX * hdr;

    // Log2 encode with AgX EV range (from UBO uniforms), mapped to [0,1]
    v = max(v, vec3(1e-10));
    v = clamp(log2(v), vec3(uboGlobal.agxMinEv), vec3(uboGlobal.agxMaxEv));
    v = (v - uboGlobal.agxMinEv) / (uboGlobal.agxMaxEv - uboGlobal.agxMinEv);

    // Sigmoid (per-channel polynomial fit)
    v = agxDefaultContrastApprox(v);

    // Apply the "Punchy" look (no-op at default 1.0/1.0).
    v = agxLookPunchy(v);

    // Back to linear display-referred RGB
    v = AGX_OUTPUT_MATRIX * v;

    return clamp(v, vec3(0.0), vec3(1.0));
}
