#version 330

#include <uniforms/global.glsl>
#include <utils/tonemap.glsl>
#include <utils/color_utils.glsl>
#include <utils/color_blindness.glsl>
#include <utils/color_filters.glsl>
#include <utils/misc.glsl>

uniform sampler2D sceneTex;
uniform sampler2D sceneDepth;

in vec2 fUv;
out vec4 FragColor;

void main() {
    // Scene FBO contains OKLab values (the GL alpha blend interpolated in
    // OKLab space). Convert back to linear, apply exposure in linear space,
    // tonemap with AgX (sigmoid response in log-space with EV bounds), and
    // sRGB-encode for the display framebuffer.
    vec3 oklab = texture(sceneTex, fUv).rgb;
    vec3 linear = oklabToLinear(oklab);
    linear *= exposure;
    vec3 srgb = linearToSrgb(agxTonemap(linear));

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
