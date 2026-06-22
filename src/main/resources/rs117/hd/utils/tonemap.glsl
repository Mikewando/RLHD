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
    const vec3 lw = vec3(0.2126, 0.7152, 0.0722);
    float luma = dot(ldr, lw);
    ldr = max(ldr, vec3(0.0)); // pow(neg, non-int) -> NaN
    vec3 graded = pow(ldr, vec3(agxPunchPower));
    return luma + agxPunchSaturation * (graded - luma);
}

vec3 agxTonemap(vec3 hdr) {
    // Guard against negatives that would break the log
    hdr = max(hdr, vec3(0.0));

    // Move to AgX color space
    vec3 v = AGX_INPUT_MATRIX * hdr;

    // Log2 encode with AgX EV range (from UBO uniforms), mapped to [0,1]
    v = max(v, vec3(1e-10));
    v = clamp(log2(v), vec3(agxMinEv), vec3(agxMaxEv));
    v = (v - agxMinEv) / (agxMaxEv - agxMinEv);

    // Sigmoid (per-channel polynomial fit)
    v = agxDefaultContrastApprox(v);

    // Apply the "Punchy" look (no-op at default 1.0/1.0).
    v = agxLookPunchy(v);

    // Back to linear display-referred RGB
    v = AGX_OUTPUT_MATRIX * v;

    return clamp(v, vec3(0.0), vec3(1.0));
}
