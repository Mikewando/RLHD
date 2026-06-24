#pragma once

#include <uniforms/lights.glsl>

#include <utils/constants.glsl>
#include <utils/specular.glsl>

#if !LEGACY_RENDERER
#include <utils/tonemap.glsl>
#endif

#if DYNAMIC_LIGHTS
void calculateLight(
    int lightIdx, vec3 position, vec3 normals, vec3 viewDir,
    vec3 texBlend, vec3 specularGloss, vec3 specularStrength,
    inout vec3 pointLightsOut, inout vec3 pointLightsSpecularOut
) {
    PointLight light = PointLightArray[lightIdx];
    vec3 lightToFrag = light.position.xyz - position;
    float distanceSquared = dot(lightToFrag, lightToFrag);
    float radiusSquared = light.position.w;
    if (distanceSquared <= radiusSquared) {
        float attenuation = 1 - sqrt(distanceSquared / radiusSquared);
        attenuation *= attenuation;

        vec3 pointLightColor = light.color.rgb * attenuation;
        vec3 pointLightDir = normalize(lightToFrag);

        float pointLightDotNormals = max(dot(normals, pointLightDir), 0);
        pointLightsOut += pointLightColor * pointLightDotNormals;

        vec3 pointLightReflectDir = reflect(-pointLightDir, normals);
        pointLightsSpecularOut += pointLightColor * specular(texBlend, viewDir, pointLightReflectDir, specularGloss, specularStrength);
    }
}

void calculateLighting(
    vec3 position, vec3 normals, vec3 viewDir,
    vec3 texBlend, vec3 specularGloss, vec3 specularStrength,
    inout vec3 pointLightsOut, inout vec3 pointLightsSpecularOut
) {
    #if TILED_LIGHTING
        ivec2 tileXY = ivec2(gl_FragCoord.xy / sceneResolution * tiledLightingResolution);

        for (int tileLayer = 0; tileLayer < TILED_LIGHTING_LAYER_COUNT; tileLayer++) {
            uvec4 tileLayerData = texelFetch(tiledLightingArray, ivec3(tileXY, tileLayer), 0);
            ivec2 unpackedData = ivec2(0);

            #define PROCESS_TILED_LIGHT_COMPONENT(c)                 \
                if (tileLayerData[c] <= 0u)                          \
                    break;                                           \
                unpackedData = decodePackedLight(tileLayerData[c]);  \
                                                                     \
                if (unpackedData[0] >= 0)                            \
                    calculateLight(unpackedData[0],                  \
                        position, normals, viewDir,                  \
                        texBlend, specularGloss, specularStrength,   \
                        pointLightsOut, pointLightsSpecularOut);     \
                                                                     \
                if (unpackedData[1] >= 0)                            \
                    calculateLight(unpackedData[1],                  \
                        position, normals, viewDir,                  \
                        texBlend, specularGloss, specularStrength,   \
                        pointLightsOut, pointLightsSpecularOut);

            PROCESS_TILED_LIGHT_COMPONENT(0);
            PROCESS_TILED_LIGHT_COMPONENT(1);
            PROCESS_TILED_LIGHT_COMPONENT(2);
            PROCESS_TILED_LIGHT_COMPONENT(3);
        }
    #else
        for (int lightIdx = 0; lightIdx < pointLightsCount; lightIdx++)
            calculateLight(lightIdx, position, normals, viewDir,
                texBlend, specularGloss, specularStrength,
                pointLightsOut, pointLightsSpecularOut);
    #endif

    #if !LEGACY_RENDERER
        // Pre-compensate the accumulated point-light contributions for AgX's
        // chroma-killing input matrix. Multiplying by AGX_OUTPUT_MATRIX (the
        // approximate inverse of AGX_INPUT_MATRIX) and lerping by the user-
        // facing strength uniform makes colored glows (lava, magical effects,
        // GOTR portals/barriers/rewards guardian, etc.) read closer to the
        // authored light color on lit surfaces after tonemapping. The matrix
        // is linear so applying it once to the sum is equivalent to applying
        // it per-light and cheaper.
        // Clamp non-negative: AGX_OUTPUT_MATRIX has negative off-diagonals and
        // can push saturated colors slightly negative on the orthogonal axis;
        // negatives surviving into compositeLight would poison linearToSrgb.
        // 0 ≤ t ≤ 1 interpolates raw → compensated; t > 1 scales brightness
        // of the (already chroma-corrected) value to push past the matrix
        // ceiling into AgX's saturated zone, without the extrapolation hue
        // collapse that pure mix(t>1) produces.
        vec3 pointLightsComp = max(AGX_OUTPUT_MATRIX * pointLightsOut, vec3(0.0));
        vec3 pointLightsSpecularComp = max(AGX_OUTPUT_MATRIX * pointLightsSpecularOut, vec3(0.0));
        pointLightsOut = mix(pointLightsOut, pointLightsComp * max(agxLightCompensation, 1.0), min(agxLightCompensation, 1.0));
        pointLightsSpecularOut = mix(pointLightsSpecularOut, pointLightsSpecularComp * max(agxLightCompensation, 1.0), min(agxLightCompensation, 1.0));
    #endif
}
#else
#define calculateLighting(position, normals, viewDir, texBlend, specularGloss, specularStrength, pointLightsOut,  pointLightsSpecularOut)
#endif
