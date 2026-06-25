#version 330

#include <uniforms/global.glsl>
#include <utils/tonemap.glsl>
#include <utils/color_utils.glsl>
#include <utils/color_blindness.glsl>
#include <utils/color_filters.glsl>
#include <utils/misc.glsl>

uniform sampler2D sceneTex;
uniform sampler2D tagTex;

in vec2 fUv;
out vec4 FragColor;

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

    // Legacy-clip compensation. Two strengths combine additively (clamped to 1):
    //   - agxLegacyMix: per-environment scalar set from environments.json; uniform
    //     across the scene, lets a whole zone (e.g. TZHAAR) hard-clip highlights.
    //   - tag: per-fragment, written to the R8 tag mask by scene_frag. See
    //     docs/agx-legacy-mix.md for the four upstream sources max-combined
    //     into the tag value.
    // Target construction: apply AgX's brightness response (log + EV normalise +
    // sigmoid) to LUMINANCE only, then scale the per-channel linear by that
    // response and hard-clip. This keeps the saturated legacy-clip hue shift
    // (e.g. fire's high-R / mid-G clips to yellow because R saturates at 1
    // before G does) while making exposure behave like the AgX path — typical
    // game HDR values are well below 2^maxEv, so a per-channel sigmoid would
    // never actually clip them and channel ratios would survive when the artist
    // intent is the legacy hue-collapse.
    float tag = texture(tagTex, fUv).r;
    float effective = min(agxLegacyMix + tag, 1.0);
    if (effective > 0.0) {
        float lum = dot(linear, REC709_LUMA);
        float lumNorm = clamp((log2(max(lum, 1e-10)) - agxMinEv) / (agxMaxEv - agxMinEv), 0.0, 1.0);
        float lumOut = clamp(agxDefaultContrastApprox(vec3(lumNorm)).x, 0.0, 1.0);
        vec3 legacyTarget = clamp(linear * (lumOut / max(lum, 1e-10)), 0.0, 1.0);
        agxOut = mix(agxOut, legacyTarget, effective);
    }

    vec3 srgb = linearToSrgb(agxOut);

    srgb = applySaturationContrast(srgb, saturation, contrast);
    srgb = colorBlindnessCompensation(srgb);

    #if APPLY_COLOR_FILTER
        srgb = applyColorFilter(srgb);
    #endif

    #if WINDOWS_HDR_CORRECTION
        srgb = windowsHdrCorrection(srgb);
    #endif

    FragColor = vec4(srgb, 1.0);
}
