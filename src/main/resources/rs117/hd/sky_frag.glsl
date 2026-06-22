#version 330

#include <uniforms/global.glsl>
#include <uniforms/sky.glsl>

#include <utils/output_transform.glsl>
#include <utils/sky_sampling.glsl>
#if ZONE_RENDERER
    #include <utils/tonemap.glsl>
#endif

in vec2 fScreenPos;

layout(location = 0) out vec4 FragColor;
#if ZONE_RENDERER
    // Zone scene FBO has a second attachment for the AgX legacy-clip tag mask
    layout(location = 1) out vec4 fragTag;
#endif

void main() {
    vec3 color = uboGlobal.fogColor;

    if (uboSky.enabled && !uboGlobal.orthographicProjection) {
        // Unproject a near/far ray to get the view direction.
        vec4 nearWorld = uboGlobal.invProjectionMatrix * vec4(fScreenPos, -1.0, 1.0);
        vec4 farWorld = uboGlobal.invProjectionMatrix * vec4(fScreenPos, 1.0, 1.0);
        vec3 viewDir = normalize(farWorld.xyz / farWorld.w - nearWorld.xyz / nearWorld.w);
        color = sampleSky(viewDir, true, true);
    }

    #if ZONE_RENDERER
        // The zone scene FBO holds scene-referred OKLab which tonemap_frag maps to the display,
        // also applying color adjustments and output correction. Invert the tonemap so the sky
        // displays as authored.
        FragColor = vec4(linearToOklab(agxInverseForDisplay(clamp(color, 0.0, 1.0))), 1.0);
        fragTag = vec4(0.0);
    #else
        vec3 srgb = linearToSrgb(color);
        srgb = applyColorAdjustments(srgb);
        srgb = applyOutputCorrection(srgb);
        FragColor = vec4(srgb, 1.0);
    #endif
}
