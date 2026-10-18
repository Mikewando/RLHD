#pragma once

#include <uniforms/global.glsl>

#include <utils/hash.glsl>
#include <utils/misc.glsl>

// Bias limits in world space units
const float MODEL_SHADOW_BIAS_LIMIT = 115.0;
const float TERRAIN_SHADOW_BIAS_LIMIT = 69.0;

struct ShadowReceiver {
    vec2 texelPos; // Texel position for a particular shadow map
    vec2 depthPerTexel; // Normalized depth per texel X & Y
    float depth; // Unbiased reference depth
    float bias; // Bias in normalized depth units
    float biasLimit; // Bias limit in normalized depth units
};

float limitShadowBias(float bias, float limit) {
    float magnitude = abs(bias);
    // Preserve small offsets exactly, and approach the limit asymptotically
    float knee = limit * 0.5;
    if (magnitude > knee)
        bias = sign(bias) * (limit - knee * (knee / magnitude));
    return bias;
}

vec2 getShadowDitherOffset(int i) {
#if SHADOW_FILTERING == SHADOW_FILTERING_DITHER
    int firstIndex = int(hash12(gl_FragCoord.xy) * POISSON_DISK_LENGTH);
    int index = (firstIndex + i) % POISSON_DISK_LENGTH;
    return getPoissonDisk(index) * 1.25;
#else
    return vec2(0.0);
#endif
}

float fetchShadowTexel(sampler2D tex, bool hasTransparency, ShadowReceiver receiver, int i, ivec2 texelPos) {
    texelPos += ivec2(getShadowDitherOffset(i));
    #if SHADOW_FILTERING == SHADOW_FILTERING_PCSS
        // texelFetch does not apply the texture's clamp-to-border setting.
        if (any(lessThan(texelPos, ivec2(0))) || any(greaterThanEqual(texelPos, textureSize(tex, 0))))
            return 0.0;
    #endif
    float bias = dot(vec2(texelPos) + 0.5 - receiver.texelPos, receiver.depthPerTexel);
    float fragDepth = receiver.depth + limitShadowBias(bias - receiver.bias, receiver.biasLimit);

    if (hasTransparency) {
        int alphaDepth = int(texelFetch(tex, texelPos, 0).r * SHADOW_COMBINED_MAX);
        float depth = float(alphaDepth & SHADOW_DEPTH_MAX) / SHADOW_DEPTH_MAX;
        float alpha = 1 - float(alphaDepth >> SHADOW_DEPTH_BITS) / SHADOW_ALPHA_MAX;
        return depth < fragDepth ? alpha : 0.f;
    }

    return texelFetch(tex, texelPos, 0).r < fragDepth ? 1.f : 0.f;
}

float sampleShadowPCF1x1(sampler2D tex, bool hasTransparency, ShadowReceiver receiver, vec3 fragPos, vec4 shadowPos) {
    ivec2 texelPos = ivec2(shadowPos.xy * textureSize(tex, 0));
    return fetchShadowTexel(tex, hasTransparency, receiver, 0, texelPos);
}

float sampleShadowPCF2x2(sampler2D tex, bool hasTransparency, ShadowReceiver receiver, vec3 fragPos, vec4 shadowPos) {
    shadowPos.xy *= textureSize(tex, 0);
    shadowPos.xy -= .5; // Shift so the 2x2 kernel straddles the sample point

    ivec2 offset = ivec2(floor(shadowPos.xy));
    float c00 = fetchShadowTexel(tex, hasTransparency, receiver, 0, offset + ivec2(0, 0));
    float c10 = fetchShadowTexel(tex, hasTransparency, receiver, 1, offset + ivec2(1, 0));
    float c01 = fetchShadowTexel(tex, hasTransparency, receiver, 2, offset + ivec2(0, 1));
    float c11 = fetchShadowTexel(tex, hasTransparency, receiver, 3, offset + ivec2(1, 1));

    if (c00 == c10 && c10 == c01 && c01 == c11)
        return c00;

    #if SHADOW_FILTERING == SHADOW_FILTERING_AVERAGE
        return (c00 + c10 + c01 + c11) * 0.25;
    #else
        vec2 lerp = fract(shadowPos.xy);
        return mix(
            mix(c00, c10, lerp.x),
            mix(c01, c11, lerp.x),
            lerp.y
        );
    #endif
}

float sampleShadowPCF3x3(sampler2D tex, bool hasTransparency, ShadowReceiver receiver, vec3 fragPos, vec4 shadowPos) {
    shadowPos.xy *= textureSize(tex, 0);

    const int kernelSize = 3;
    ivec2 offset = ivec2(shadowPos.xy) - kernelSize / 2;

    #if SHADOW_FILTERING == SHADOW_FILTERING_AVERAGE
        const float kernelAreaReciprocal = 1. / (kernelSize * kernelSize);
    #else
        const float kernelAreaReciprocal = .25;
        vec2 lerp = fract(shadowPos.xy);
        vec3 lerpX = vec3(1 - lerp.x, 1, lerp.x);
        vec3 lerpY = vec3(1 - lerp.y, 1, lerp.y);
    #endif

    float c00 = fetchShadowTexel(tex, hasTransparency, receiver, 0, offset + ivec2(0, 0));
    float c02 = fetchShadowTexel(tex, hasTransparency, receiver, 1, offset + ivec2(0, kernelSize - 1));
    float c20 = fetchShadowTexel(tex, hasTransparency, receiver, 2, offset + ivec2(kernelSize - 1, 0));
    float c22 = fetchShadowTexel(tex, hasTransparency, receiver, 3, offset + ivec2(kernelSize - 1, kernelSize - 1));

    if ((c00 == 0.0 || c00 == 1.0) && c00 == c02 && c00 == c20 && c00 == c22)
        return c00;

    float s01 = fetchShadowTexel(tex, hasTransparency, receiver, 4, offset + ivec2(0, 1));
    float s10 = fetchShadowTexel(tex, hasTransparency, receiver, 5, offset + ivec2(1, 0));
    float s11 = fetchShadowTexel(tex, hasTransparency, receiver, 6, offset + ivec2(1, 1));
    float s12 = fetchShadowTexel(tex, hasTransparency, receiver, 7, offset + ivec2(1, 2));
    float s21 = fetchShadowTexel(tex, hasTransparency, receiver, 8, offset + ivec2(2, 1));

    float shadow;
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
    return shadow * kernelAreaReciprocal;
}

#if SHADOW_FILTERING == SHADOW_FILTERING_POISSON_DITHER || SHADOW_FILTERING == SHADOW_FILTERING_JITTERED_PCF
// Raw (depth, alpha) decode of the R32UI shadow attachment. Alpha is 1.0 in opaque mode; in
// transparency mode it's the texel's blocker opacity (1 = fully blocks, 0 = fully clear).
vec2 fetchShadowDepthAlpha(ivec2 texelPos) {
    // texelFetch does not apply the texture's clamp-to-border setting
    if (any(lessThan(texelPos, ivec2(0))) || any(greaterThanEqual(texelPos, textureSize(shadowMapUint, 0))))
        return vec2(1.0, 0.0);
    uint stored = texelFetch(shadowMapUint, texelPos, 0).r;
    #if SHADOW_TRANSPARENCY
        uint depthBits = stored & 0x00FFFFFFu;
        uint alphaBits = stored >> 24;
        return vec2(float(depthBits) / 16777215.0, 1.0 - float(alphaBits) / 255.0);
    #else
        return vec2(float(stored) / 4294967040.0, 1.0);
    #endif
}
#endif

#if SHADOW_FILTERING == SHADOW_FILTERING_POISSON_DITHER
// Rotated Poisson PCF: per-fragment rotation decorrelates tap patterns
// across neighboring fragments, producing soft noisy penumbra without
// visible structure. World-position hash keeps the rotation stable
// across camera motion, so the noise doesn't shimmer. Each tap uses the
// receiver-plane depth at its offset, like the PCF kernels above.
float sampleShadowPoissonDither(sampler2D tex, bool hasTransparency, ShadowReceiver receiver, vec3 fragPos, vec4 shadowPos) {
    float angle = hash13(fragPos) * TAU;
    float ca = cos(angle), sa = sin(angle);
    mat2 rot = mat2(ca, -sa, sa, ca);

    const int taps = 16;
    const float diskRadius = 4.0; // shadow-map texels
    float shadow = 0.0;
    for (int i = 0; i < taps; i++) {
        vec2 offset = rot * getPoissonDisk(i) * diskRadius;
        ivec2 texelPos = ivec2(receiver.texelPos + offset);
        float bias = dot(vec2(texelPos) + 0.5 - receiver.texelPos, receiver.depthPerTexel);
        float fragDepth = receiver.depth + limitShadowBias(bias - receiver.bias, receiver.biasLimit);
        vec2 depthAlpha = fetchShadowDepthAlpha(texelPos);
        shadow += depthAlpha.x < fragDepth ? depthAlpha.y : 0.0;
    }
    return shadow / float(taps);
}
#endif

#if SHADOW_FILTERING == SHADOW_FILTERING_JITTERED_PCF
// Stochastic PCF with a soft depth compare.
//
// Structurally a PCF kernel with N XY-jittered taps at a single reference
// depth, soft-compared per tap and averaged across taps. Differs from the
// PCF kernels above in three ways that together hide the SM triangulation
// artifacts and sidestep the acne/peter-panning tradeoff: (1) wider sample
// footprint (±xyJitterTexels), (2) smoothstep-based soft compare instead of
// a hard binary compare, giving anti-aliased edges, and (3) a slope-scaled
// start offset along lightDir applied in sampleShadowJitteredPCF() instead
// of the receiver-plane bias, so contact features (feet, crenelations) resolve.
float sampleJitteredPCFPass(vec3 origin, float jitter) {
    const int   taps           = 16;
    const float edgeWidth      = 0.0005; // soft band in normalized SM depth units
    const float xyJitterTexels = 3.0;    // ±N texels of sub-pixel XY jitter per tap
    const float invTaps        = 1.0 / float(taps);
    vec2 shadowRes    = vec2(textureSize(shadowMapUint, 0));
    vec2 invShadowRes = 1.0 / shadowRes;

    // Project the (already slope-offset) origin once. baseUv + refDepth are
    // the receiver's "look here" coordinates in shadow NDC.
    vec4 sp0 = uboGlobal.lightProjectionMatrix * vec4(origin, 1);
    sp0.xyz /= sp0.w;
    if (any(greaterThan(abs(sp0.xyz), vec3(1.0))))
        return 0.0;
    vec2  baseUv   = sp0.xy * 0.5 + 0.5;
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
        // Tap contribution = softCov × per-texel alpha. Averaging across taps
        // converges to the caster's true opacity for uniform partial-cover
        // regions and gives PCF-style soft silhouettes at edges.
        vec2 depthAlpha = fetchShadowDepthAlpha(ivec2(uv * shadowRes));
        float softCov = smoothstep(0.0, edgeWidth, refDepth - depthAlpha.x);
        shadowSum += softCov * depthAlpha.y * invTaps;
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
float sampleShadowJitteredPCF(vec3 fragPos, float lightDotNormals, bool preventSelfShadowing) {
    vec3 origin = fragPos;
    if (preventSelfShadowing) {
        float ndl = max(lightDotNormals, 0.1);
        // Small world-space offset (~few units at perpendicular, larger at
        // grazing) along the light direction. Receiver-surface taps land just
        // above the receiver's own SM depth so the soft compare returns 0 for
        // them, while real occluders' depth differences still pass.
        origin += uboGlobal.lightDir * (2.0 / ndl);
    }

    float jitter = hash13(fragPos);
    float s0 = sampleJitteredPCFPass(origin, jitter);
    float s1 = sampleJitteredPCFPass(origin, fract(jitter + 0.5));
    return 0.5 * (s0 + s1);
}
#endif

float fetchHardwareShadowTexel(sampler2DShadow tex, ShadowReceiver receiver, int i, vec2 shadowPos) {
    vec2 texelPos = shadowPos * textureSize(tex, 0) + getShadowDitherOffset(i);
    float bias = dot(texelPos - receiver.texelPos, receiver.depthPerTexel);
    float fragDepth = receiver.depth + limitShadowBias(bias - receiver.bias, receiver.biasLimit);
    return texture(tex, vec3(texelPos / textureSize(tex, 0), fragDepth));
}

float sampleHardwareShadow1x1(sampler2DShadow tex, ShadowReceiver receiver, vec4 shadowPos) {
    return fetchHardwareShadowTexel(tex, receiver, 0, shadowPos.xy);
}

float sampleHardwareShadow2x2(sampler2DShadow tex, ShadowReceiver receiver, vec4 shadowPos) {
    vec2 texelSize = 1.0 / vec2(textureSize(tex, 0));
    vec2 offset = shadowPos.xy - .5 * texelSize;

    float c00 = fetchHardwareShadowTexel(tex, receiver, 0, offset + vec2(0, 0) * texelSize);
    float c10 = fetchHardwareShadowTexel(tex, receiver, 1, offset + vec2(1, 0) * texelSize);
    float c01 = fetchHardwareShadowTexel(tex, receiver, 2, offset + vec2(0, 1) * texelSize);
    float c11 = fetchHardwareShadowTexel(tex, receiver, 3, offset + vec2(1, 1) * texelSize);

    return (c00 + c10 + c01 + c11) * 0.25;
}

float sampleHardwareShadow3x3(sampler2DShadow tex, ShadowReceiver receiver, vec4 shadowPos) {
    vec2 texelSize = 1.0 / vec2(textureSize(tex, 0));

    const int kernelSize = 3;
    vec2 offset = shadowPos.xy - float(kernelSize / 2) * texelSize;

    float c00 = fetchHardwareShadowTexel(tex, receiver, 0, offset + vec2(0, 0) * texelSize);
    float c02 = fetchHardwareShadowTexel(tex, receiver, 1, offset + vec2(0, kernelSize - 1) * texelSize);
    float c20 = fetchHardwareShadowTexel(tex, receiver, 2, offset + vec2(kernelSize - 1, 0) * texelSize);
    float c22 = fetchHardwareShadowTexel(tex, receiver, 3, offset + vec2(kernelSize - 1, kernelSize - 1) * texelSize);

    if ((c00 == 0.0 || c00 == 1.0) && c00 == c02 && c00 == c20 && c00 == c22)
        return c00;

    float s01 = fetchHardwareShadowTexel(tex, receiver, 4, offset + vec2(0, 1) * texelSize);
    float s10 = fetchHardwareShadowTexel(tex, receiver, 5, offset + vec2(1, 0) * texelSize);
    float s11 = fetchHardwareShadowTexel(tex, receiver, 6, offset + vec2(1, 1) * texelSize);
    float s12 = fetchHardwareShadowTexel(tex, receiver, 7, offset + vec2(1, 2) * texelSize);
    float s21 = fetchHardwareShadowTexel(tex, receiver, 8, offset + vec2(2, 1) * texelSize);

    float shadow =
        c00 + s01 + c02 +
        s10 + s11 + s12 +
        c20 + s21 + c22;

    return shadow / 9.0;
}
