#version 330
#extension GL_ARB_shader_storage_buffer_object : require
#extension GL_ARB_shading_language_420pack : require

#include <uniforms/global.glsl>
#include <utils/tonemap.glsl>
#include <utils/color_utils.glsl>
#include <utils/color_blindness.glsl>
#include <utils/color_filters.glsl>
#include <utils/misc.glsl>

uniform sampler2D sceneTex;
uniform sampler2D sceneDepth;
uniform sampler2D tagTex;

in vec2 fUv;
out vec4 FragColor;

// Debug probe SSBO mirrors scene_frag declaration; tonemap_frag writes slots 4..15.
layout(std430, binding = 10) buffer DebugProbeBuffer {
    vec4 debugProbeData[96];
    uint sceneFragHits;
};

void main() {
    // Scene FBO contains OKLab values (the GL alpha blend interpolated in
    // OKLab space). Convert back to linear, apply exposure in linear space,
    // tonemap with AgX (sigmoid response in log-space with EV bounds), and
    // sRGB-encode for the display framebuffer.
    vec3 oklab = texture(sceneTex, fUv).rgb;
    vec3 linearPre = oklabToLinear(oklab);
    vec3 linear = linearPre * exposure;

    // AgX gets the unmodified post-exposure linear. The tag-driven compensation
    // happens AFTER AgX, on the already-tonemapped output, by mixing toward what
    // legacy clip+sRGB would have shown for the same pixel.
    vec3 agxOut = agxTonemap(linear);

    // Tag-driven compensation. The R8 mask was written by scene_frag and
    // alpha-blended through the scene pass; its value here is the fraction of the
    // pixel's color that came from tagged geometry. Where tag > 0, mix AgX's
    // output toward the literal legacy target = clamp(linear, 0, 1). Both values
    // live in the same [0,1] display-linear space, so no gamut juggling is needed
    // and the eventual display sRGB matches legacy clip+sRGB exactly at strength=1.
    float tag = texture(tagTex, fUv).r;
    if (tag > 0.0 && agxSurfaceVibrance > 0.0) {
        vec3 legacyTarget = clamp(linear, 0.0, 1.0);
        agxOut = mix(agxOut, legacyTarget, min(tag * agxSurfaceVibrance, 1.0));
    }

    // ── debug probe: replicate agxTonemap stages writing to SSBO ──
    if (debugProbeArm != 0 && ivec2(gl_FragCoord.xy) == debugProbePixelTonemap) {
        vec3 hdr = max(linear, vec3(0.0));
        vec3 v0 = AGX_INPUT_MATRIX * hdr;
        vec3 v0c = max(v0, vec3(1e-10));
        vec3 v1raw = log2(v0c);
        vec3 v1 = clamp(v1raw, vec3(agxMinEv), vec3(agxMaxEv));
        v1 = (v1 - agxMinEv) / (agxMaxEv - agxMinEv);
        vec3 v2 = agxDefaultContrastApprox(v1);
        vec3 v3 = agxLookPunchy(v2);
        vec3 v4 = AGX_OUTPUT_MATRIX * v3;
        vec3 v5 = clamp(v4, vec3(0.0), vec3(1.0));   // uncompensated AgX output
        vec3 srgbAgx = linearToSrgb(v5);              // what AgX alone would display
        vec3 srgbLegacy = linearToSrgb(clamp(linear, vec3(0.0), vec3(1.0))); // legacy clip+srgb
        vec3 srgbFinal = linearToSrgb(agxOut);        // post-compensation display

        debugProbeData[4]  = vec4(oklab, 0.0);
        debugProbeData[5]  = vec4(linearPre, exposure);
        debugProbeData[6]  = vec4(hdr, 0.0);
        debugProbeData[7]  = vec4(v0, 0.0);
        debugProbeData[8]  = vec4(v1, 0.0);
        debugProbeData[9]  = vec4(v2, 0.0);
        debugProbeData[10] = vec4(v3, 0.0);
        debugProbeData[11] = vec4(v4, 0.0);
        debugProbeData[12] = vec4(v5, 0.0);
        debugProbeData[13] = vec4(srgbAgx, 0.0);
        debugProbeData[14] = vec4(srgbLegacy, 0.0);
        debugProbeData[21] = vec4(agxOut, 0.0);       // post-compensation linear
        debugProbeData[22] = vec4(srgbFinal, 0.0);    // post-compensation display sRGB
        debugProbeData[15].x = float(int(gl_FragCoord.x));
        debugProbeData[15].y = float(int(gl_FragCoord.y));
        debugProbeData[15].z += 100.0; // shaderHits (tonemap)
    }

    vec3 srgb = linearToSrgb(agxOut);

    if (debugTagMask != 0) {
        // Replace the displayed image with the tagged-glow mask. White = fully tagged
        // (e.g. opaque white eye outline), greys = partial (translucent glow layers
        // blended over background), black = untagged.
        srgb = vec3(tag);
    }

    srgb = applySaturationContrast(srgb, saturation, contrast);
    srgb = colorBlindnessCompensation(srgb);

    #if APPLY_COLOR_FILTER
        srgb = applyColorFilter(srgb);
    #endif

    #if WINDOWS_HDR_CORRECTION
        srgb = windowsHdrCorrection(srgb);
    #endif

    // Live cursor marker (Ctrl+Shift+M). Burns a magenta center + yellow crosshair
    // arms onto whichever fragment Java thinks the cursor is over. Lets us visually
    // verify the cursor → fbo pixel mapping is correct.
    if (debugCursorMarker != 0 && debugCursorPixelTonemap.x >= 0) {
        ivec2 fc = ivec2(gl_FragCoord.xy);
        ivec2 d = fc - debugCursorPixelTonemap;
        int adx = abs(d.x);
        int ady = abs(d.y);
        if (adx == 0 && ady == 0) {
            srgb = vec3(1.0, 0.0, 1.0); // center
        } else if ((adx == 0 && ady <= 10) || (ady == 0 && adx <= 10)) {
            srgb = vec3(1.0, 1.0, 0.0); // arms
        } else if (max(adx, ady) <= 12 && min(adx, ady) == 12) {
            srgb = vec3(0.0, 1.0, 1.0); // outer box outline
        }
    }

    FragColor = vec4(srgb, 1.0);
}
