/*
 * Copyright (c) 2021, 117 <https://twitter.com/117scape>
 * Copyright (c) 2024, Hooder <ahooder@protonmail.com>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
#include <uniforms/global.glsl>

#include <utils/constants.glsl>
#include <utils/misc.glsl>

#if SHADOW_RESOLUTION == 0
    #define MIN_SHADOW_BIAS -0.00125f
#elif SHADOW_RESOLUTION == 1
    #define MIN_SHADOW_BIAS -0.0007f
#elif SHADOW_RESOLUTION == 2
    #define MIN_SHADOW_BIAS -0.00035
#elif SHADOW_RESOLUTION == 3
    #define MIN_SHADOW_BIAS -0.0003
#elif SHADOW_RESOLUTION >= 4
    #define MIN_SHADOW_BIAS -0.00025
#endif

#ifndef TILE_SIZE
    #define TILE_SIZE 128
#endif

#if SHADOW_MODE != SHADOW_MODE_OFF
// Raw SM (depth, alpha) decode. Alpha is 1.0 in opaque mode; in transparency
// mode it's the texel's blocker opacity (1 = fully blocks, 0 = fully clear).
// Used by SHADOW_FILTERING_JITTERED_PCF's transparency path, which needs the
// real depth (the depth attachment carries a packed sort key in transparency
// mode) and per-texel alpha for soft-compared PCF accumulation.
vec2 fetchShadowDepthAlpha(ivec2 pixelCoord) {
    uint stored = texelFetch(shadowMapUint, pixelCoord, 0).r;
    #if SHADOW_TRANSPARENCY
        uint depthBits = stored & 0x00FFFFFFu;
        uint alphaBits = stored >> 24;
        return vec2(float(depthBits) / 16777215.0, 1.0 - float(alphaBits) / 255.0);
    #else
        return vec2(float(stored) / 4294967040.0, 1.0);
    #endif
}

float fetchShadowTexel(ivec2 pixelCoord, float fragDepth) {
    uint stored = texelFetch(shadowMapUint, pixelCoord, 0).r;
    #if SHADOW_TRANSPARENCY
        // 24-bit depth in lower bits, 8-bit (1 - opacity) packed in upper bits.
        uint depthBits = stored & 0x00FFFFFFu;
        uint alphaBits = stored >> 24;
        float depth = float(depthBits) / 16777215.0;   // 2^24 - 1
        float alpha = 1.0 - float(alphaBits) / 255.0;
        return depth < fragDepth ? alpha : 0.0;
    #else
        // 32-bit depth (scale matches the shadow_frag write side: 2^32 - 256).
        float depth = float(stored) / 4294967040.0;
        return depth < fragDepth ? 1.0 : 0.0;
    #endif
}

#if SHADOW_FILTERING == SHADOW_FILTERING_JITTERED_PCF
// Stochastic PCF with a soft depth compare.
//
// Structurally a PCF kernel with N XY-jittered taps at a single reference
// depth, soft-compared per tap and averaged across taps. Differs from the
// SMOOTH/PIXELATED 3x3 filters in three ways that together hide the SM
// triangulation artifacts and remove the MIN_SHADOW_BIAS acne/peter-panning
// tradeoff: (1) wider sample footprint (±xyJitterTexels vs. ~1 texel for
// SMOOTH's bilinear tent), (2) smoothstep-based soft compare instead of
// hard binary compare, giving anti-aliased edges, and (3) a slope-scaled
// start offset along lightDir applied in sampleJitteredPCF() that replaces
// MIN_SHADOW_BIAS so contact features (feet, crenelations) resolve.
//
// Opaque uses the depth attachment via texture() (GL_NEAREST — one texel
// per tap); transparency uses the R32UI to recover the real depth + alpha
// that transparency mode packs there (the depth attachment in that mode
// carries a packed sort key, not real depth, see shadow_frag.glsl).
float sampleJitteredPCFPass(vec3 origin, vec2 distortion, float jitter) {
    const int   taps           = 16;
    const float edgeWidth      = 0.0005; // soft band in normalized SM depth units
    const float xyJitterTexels = 3.0;    // ±N texels of sub-pixel XY jitter per tap
    const float invTaps        = 1.0 / float(taps);
    ivec2 shadowRes    = textureSize(shadowMap, 0);
    vec2  invShadowRes = 1.0 / vec2(shadowRes);

    // Project the (already slope-offset) origin once. baseUv + refDepth are
    // the receiver's "look here" coordinates in shadow NDC. The distortion
    // term matches what sampleShadowMap applies for the other filter modes
    // — used by water surfaces to animate the shadow with the flow map.
    vec4 sp0 = lightProjectionMatrix * vec4(origin, 1);
    sp0.xyz /= sp0.w;
    if (any(greaterThan(abs(sp0.xyz), vec3(1.0))))
        return 0.0;
    vec2  baseUv   = sp0.xy * 0.5 + 0.5 + distortion;
    float refDepth = sp0.z  * 0.5 + 0.5;

    // Per-tap sub-texel XY jitter, irrational-sequence stratified (golden
    // ratio for X, √2-1 for Y). Across 16 taps × 2 passes (the caller
    // invokes us twice with anti-correlated jitter), 32 distinct sub-pixel
    // positions span the ±xyJitterTexels disk.
#define TAP_XY_JITTER(i) ((vec2( \
        fract(jitter + float(i) * 0.61803398), \
        fract(jitter * 1.3 + float(i) * 0.41421356) \
    ) - 0.5) * (xyJitterTexels * 2.0 * invShadowRes))

    float shadowSum = 0.0;
    for (int i = 1; i <= taps; i++) {
        vec2 uv = baseUv + TAP_XY_JITTER(i);

#if SHADOW_TRANSPARENCY
        // Tap contribution = softCov × per-texel alpha. Averaging across taps
        // converges to the caster's true opacity for uniform partial-cover
        // regions and gives PCF-style soft silhouettes at edges.
        ivec2 pix = ivec2(uv * vec2(shadowRes));
        vec2  sd  = fetchShadowDepthAlpha(pix);
        float softCov = smoothstep(0.0, edgeWidth, refDepth - sd.x);
        shadowSum += softCov * sd.y * invTaps;
#else
        // Opaque: depth attachment is real depth (transparency packs a sort
        // key into it instead, which is why we read R32UI above).
        float smDepth = texture(shadowMap, uv).r;
        float softCov = smoothstep(0.0, edgeWidth, refDepth - smDepth);
        shadowSum += softCov * invTaps;
#endif
    }
    return shadowSum;
#undef TAP_XY_JITTER
}

// Entry point: offsets the origin along lightDir to skirt receiver-surface
// self-shadow (slope-scaled by 1/ndl so grazing angles get a larger
// offset), then runs two stochastic-PCF passes with anti-correlated jitter
// phases and averages them. Each pass already returns a continuous value;
// the 2-pass average doubles the effective tap count for the same fragment,
// reducing per-fragment jitter noise without increasing the disk radius.
float sampleJitteredPCF(vec3 fragPos, vec2 distortion, float lightDotNormals) {
    float ndl = max(lightDotNormals, 0.1);
    // Small world-space offset (~few units at perpendicular, larger at
    // grazing) along the sun direction. Replaces MIN_SHADOW_BIAS: receiver-
    // surface taps land just above the receiver's own SM depth so the soft
    // compare returns 0 for them, while real occluders' depth differences
    // still pass.
    vec3 origin = fragPos + lightDir * (2.0 / ndl);

    float jitter = hash(fragPos.xyz);
    float s0 = sampleJitteredPCFPass(origin, distortion, jitter);
    float s1 = sampleJitteredPCFPass(origin, distortion, fract(jitter + 0.5));
    return 0.5 * (s0 + s1);
}
#endif

float sampleShadowMap(vec3 fragPos, vec2 distortion, float lightDotNormals) {
    if (lightStrength <= 0)
        return 0.f;

    vec4 shadowPos = lightProjectionMatrix * vec4(fragPos, 1);
    shadowPos.xyz /= shadowPos.w;

    // Fade out shadows near the shadow map edges
    #if ZONE_RENDERER
        // TODO: Make this configurable if we make the Shadow Distance Variable
        const float fadeStart = 55.0 * TILE_SIZE;
        const float fadeEnd   = 65.0 * TILE_SIZE;
        float fadeOut = smoothstep(fadeStart, fadeEnd, length(fragPos - cameraPos));
    #else
        float fadeOut = smoothstep(.75, 1., dot(shadowPos.xy, shadowPos.xy));
    #endif
    if (fadeOut >= 1)
        return 0.f;

    // NDC to texture space
    ivec2 shadowRes = textureSize(shadowMap, 0);
    shadowPos.xyz += 1;
    shadowPos.xyz /= 2;
    shadowPos.xy += distortion;
    shadowPos.xy = clamp(shadowPos.xy, 0, 1);
    shadowPos.xy *= shadowRes;
    shadowPos.xy += .5; // Shift to texel center

    float shadowBias = MIN_SHADOW_BIAS * max(1, 1.0 - lightDotNormals);
    float fragDepth = shadowPos.z + shadowBias;

    #if SHADOW_FILTERING == SHADOW_FILTERING_DITHER
    {
        // Rotated Poisson PCF: per-fragment rotation decorrelates tap patterns
        // across neighboring fragments, producing soft noisy penumbra without
        // visible structure. World-position hash keeps the rotation stable
        // across camera motion, so the noise doesn't shimmer.
        float angle = hash(fragPos.xyz) * TAU;
        float ca = cos(angle), sa = sin(angle);
        mat2 rot = mat2(ca, -sa, sa, ca);

        const int taps = 16;
        const float diskRadius = 4.0; // shadow-map texels
        float shadow = 0.0;
        for (int i = 0; i < taps; i++) {
            vec2 offset = rot * getPoissonDisk(i) * diskRadius;
            ivec2 tapCoord = ivec2(shadowPos.xy + offset);
            shadow += fetchShadowTexel(tapCoord, fragDepth);
        }
        shadow /= float(taps);
        return shadow * (1 - fadeOut);
    }
    #endif

    #if SHADOW_FILTERING == SHADOW_FILTERING_JITTERED_PCF
    {
        float shadow = sampleJitteredPCF(fragPos, distortion, lightDotNormals);
        return shadow * (1 - fadeOut);
    }
    #endif

    const int kernelSize = 3;
    ivec2 kernelOffset = ivec2(shadowPos.xy - kernelSize / 2);
    #if SHADOW_FILTERING == SHADOW_FILTERING_AVERAGE
        const float kernelAreaReciprocal = 1. / (kernelSize * kernelSize);
    #else
        const float kernelAreaReciprocal = .25; // This is effectively a 2x2 kernel
        vec2 lerp = fract(shadowPos.xy);
        vec3 lerpX = vec3(1 - lerp.x, 1, lerp.x);
        vec3 lerpY = vec3(1 - lerp.y, 1, lerp.y);
    #endif

    // Sample 4 corners first
    float c00 = fetchShadowTexel(kernelOffset + ivec2(0, 0), fragDepth);
    float c02 = fetchShadowTexel(kernelOffset + ivec2(0, kernelSize - 1), fragDepth);
    float c20 = fetchShadowTexel(kernelOffset + ivec2(kernelSize - 1, 0), fragDepth);
    float c22 = fetchShadowTexel(kernelOffset + ivec2(kernelSize - 1, kernelSize - 1), fragDepth);

    // Early exit if all corners are the same (fully shadowed or fully lit)
    bool allShadowed = (c00 == 0.0 && c02 == 0.0 && c20 == 0.0 && c22 == 0.0);
    bool allLit      = (c00 == 1.0 && c02 == 1.0 && c20 == 1.0 && c22 == 1.0);

    float shadow = 0.0;
    if (allShadowed || allLit) {
        shadow = (c00 + c02 + c20 + c22) * 0.25;
    } else {
        // Finish sampling the reset of the kernal
        float s01 = fetchShadowTexel(kernelOffset + ivec2(0, 1), fragDepth);
        float s10 = fetchShadowTexel(kernelOffset + ivec2(1, 0), fragDepth);
        float s11 = fetchShadowTexel(kernelOffset + ivec2(1, 1), fragDepth);
        float s12 = fetchShadowTexel(kernelOffset + ivec2(1, 2), fragDepth);
        float s21 = fetchShadowTexel(kernelOffset + ivec2(2, 1), fragDepth);

        #if SHADOW_FILTERING == SHADOW_FILTERING_AVERAGE
            shadow =
                c00 + s01 + c02 +
                s10 + s11 + s12 +
                c20 + s21 + c22;
        #else
            shadow =
                c00 * lerpX[0] * lerpY[0] +
                s01 * lerpX[0] * lerpY[1] +
                c02 * lerpX[0] * lerpY[2] +
                s10 * lerpX[1] * lerpY[0] +
                s11 * lerpX[1] * lerpY[1] +
                s12 * lerpX[1] * lerpY[2] +
                c20 * lerpX[2] * lerpY[0] +
                s21 * lerpX[2] * lerpY[1] +
                c22 * lerpX[2] * lerpY[2];
        #endif
        shadow *= kernelAreaReciprocal;
    }

    return shadow * (1 - fadeOut);
}
#else
#define sampleShadowMap(fragPos, distortion, lightDotNormals) 0
#endif
