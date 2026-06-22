#version 330

#include <uniforms/global.glsl>
#include <uniforms/sky.glsl>

#include <utils/output_transform.glsl>
#if ZONE_RENDERER
    #include <utils/tonemap.glsl>
#endif

in vec3 vColor;
in float vBrightness;
#if !POINT_SPRITES
    in vec2 vUv;
#endif

layout(location = 0) out vec4 FragColor;
#if ZONE_RENDERER
    layout(location = 1) out vec4 fragTag;
#endif

void main() {
    if (!uboSky.enabled || uboGlobal.orthographicProjection || vBrightness <= 0.0)
        discard;

    #if POINT_SPRITES
        vec2 pointCoord = gl_PointCoord;
    #else
        vec2 pointCoord = vUv;
    #endif

    float d = length(pointCoord - vec2(0.5)) * 2.0;
    if (d >= 1.0)
        discard;

    // A soft profile avoids sub-pixel brightness flicker.
    float falloff = exp(-d * d * 4.4); // smooth bell, ~0 by the sprite edge (wider = softer)

    vec3 starColor = vColor * vBrightness * falloff * 4.0;
    #if ZONE_RENDERER
        // Additively blended into the scene-referred OKLab FBO. Adding OKLab values is only an
        // approximation of adding light, but stars are faint and near-neutral.
        FragColor = vec4(linearToOklab(agxInverseForDisplay(clamp(starColor, 0.0, 1.0))), 0.0);
        fragTag = vec4(0.0);
    #else
        starColor = linearToSrgb(starColor);
        starColor = applyColorAdjustments(starColor);
        starColor = applyOutputCorrection(starColor);
        FragColor = vec4(starColor, 0.0);
    #endif
}
