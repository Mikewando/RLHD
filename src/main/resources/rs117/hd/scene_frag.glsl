/*
 * Copyright (c) 2018, Adam <Adam@sigterm.info>
 * Copyright (c) 2021, 117 <https://twitter.com/117scape>
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
#version 330
#extension GL_ARB_shader_storage_buffer_object : require
#extension GL_ARB_shading_language_420pack : require

#define DISPLAY_BASE_COLOR 0
#define DISPLAY_UV 0
#define DISPLAY_NORMAL 0
#define DISPLAY_TANGENT 0
#define DISPLAY_SHADOWS 0
#define DISPLAY_LIGHTING 0

#include <uniforms/global.glsl>
#include <uniforms/world_views.glsl>
#include <uniforms/materials.glsl>
#include <uniforms/water_types.glsl>

#include MATERIAL_CONSTANTS

uniform sampler2DArray textureArray;
uniform sampler2D shadowMap;
uniform usampler2DArray tiledLightingArray;

#if !LEGACY_RENDERER
// Debug probe SSBO: one shared 16 vec4 buffer written from scene_frag (slots 0..3)
// and tonemap_frag (slots 4..15). Java reads back after the frame.
layout(std430, binding = 10) buffer DebugProbeBuffer {
    vec4 debugProbeData[96];
    uint sceneFragHits;
};
#endif

// general HD settings

flat in int fWorldViewId;
flat in ivec3 fAlphaBiasHsl;
flat in ivec3 fMaterialData;
flat in ivec3 fTerrainData;

#if FLAT_SHADING && ZONE_RENDERER
    flat in vec3 fFlatNormal;
#endif

in FragmentData {
    vec3 position;
    vec2 uv;
    vec3 normal;
    vec3 texBlend;
} IN;

layout(location = 0) out vec4 FragColor;
#if !LEGACY_RENDERER
// Second color attachment: per-fragment tagged-glow signal. The same alpha-blend
// used for FragColor accumulates this value into a per-pixel mask in [0..1] that
// tonemap_frag samples to drive AgX-time chroma compensation. Declared as vec4
// for driver compatibility — the destination is R8 so only .r is sampled.
layout(location = 1) out vec4 fragTag;
#endif

vec2 worldUvs(float scale) {
    return -IN.position.xz / (128 * scale);
}

#include <utils/constants.glsl>
#include <utils/misc.glsl>
#include <utils/color_blindness.glsl>
#include <utils/caustics.glsl>
#include <utils/color_utils.glsl>
#include <utils/normals.glsl>
#include <utils/specular.glsl>
#include <utils/displacement.glsl>
#include <utils/shadows.glsl>
#include <utils/legacy_water.glsl>
#include <utils/water.glsl>
#include <utils/color_filters.glsl>
#include <utils/fog.glsl>
#include <utils/wireframe.glsl>
#include <utils/lights.glsl>

// =============================================================================
// Color-space conventions in this shader
// =============================================================================
// Three spaces appear in this file. Mixing them silently is the source of
// almost every water/lighting bug we've debugged. Each transition is marked.
//
//   LINEAR           Physical light values in [0, ∞). All lighting math
//                    (ambient × dir + diffuse + specular) lives here. The
//                    `textureArray` sampler is GL_SRGB8_ALPHA8 so diffuse
//                    samples auto-decode to LINEAR. Vertex HSL goes through
//                    srgbToLinear() to get here. Uniforms `ambientColor` and
//                    `lightColor` are LINEAR.
//
//   sRGB-encoded     Values that look right when treated as display bytes.
//                    Range nominally [0, 1] but extrapolated values can spill
//                    above 1 (linearToSrgb(2.0) ≈ 1.39). The GL alpha blend
//                    operates on these so multiplicative attenuation matches
//                    legacy's RGBA8-byte behavior. depthColor / foamColor /
//                    waterColor* / fogColor uniforms are sRGB-encoded by
//                    convention — that's the magnitude the shader's water mix
//                    and fog mix were tuned around.
//
//   unicorn-hybrid   What the water shader returns: a numerical mix of a
//                    LINEAR lit_surface and an sRGB-encoded gradient. Not a
//                    proper color space; lives at roughly sRGB magnitudes
//                    because the dominant fresnel weight is on the gradient.
//                    Don't apply colorspace conversions to this — match
//                    legacy's "treat it as bytes" handling.
//
// Pipeline (zone):
//   shader_frag computes in LINEAR → wraps to sRGB-encoded for sampleUnderwater
//   and fog (so those operate in the space they were tuned for) → converts to
//   OKLab right before FragColor → GL alpha blend operates on OKLab values
//   (perceptually uniform interpolation) → FBO → tonemap_frag converts OKLab
//   back to linear, clamps, encodes sRGB for display.
//
// Legacy pipeline: same lighting math, wraps to sRGB-encoded, no OKLab step,
// writes sRGB-encoded directly to RGBA8 → display interprets bytes as sRGB.
// =============================================================================

void main() {
    vec3 downDir = vec3(0, -1, 0);
    // View & light directions are from the fragment to the camera/light
    vec3 viewDir = normalize(cameraPos - IN.position);

    #if !LEGACY_RENDERER
        // Default the tag-mask output so debug-mode early-returns don't leave the
        // second color attachment undefined.
        fragTag = vec4(0.0);
    #endif

    // Probe-scope shadows of per-fragment values; populated inside the non-water
    // terrain branch when available, else stay zero (water fragments).
    float _probeHasAttachedLightBlend = 0.0;
    float _probeUnlit = 0.0;
    float _probeCompositeLightLen = 0.0;
    vec3 _probeBaseColor = vec3(0.0);
    int _probeColorMap1 = -2;
    int _probeColorMap2 = -2;
    // Function-scope so the fragTag write at the end of main() can read it after
    // the terrain block closes. Populated inside #if !LEGACY_RENDERER terrain branch.
    float legacyHighlightBlend = 0.0;
    // Per-fragment point-light luminance scaled by agxPointLightVibrance and clamped
    // to [0,1]. Drives the same R8 tag attachment as the object/material paths so a
    // strong coloured glow pushes nearby surfaces toward the legacy hard-clip+sRGB
    // hue. Stays zero for water fragments (computed only in the terrain branch).
    float pointLightTag = 0.0;

    Material material1 = getMaterial(fMaterialData[0] >> MATERIAL_INDEX_SHIFT & MATERIAL_INDEX_MASK);
    Material material2 = getMaterial(fMaterialData[1] >> MATERIAL_INDEX_SHIFT & MATERIAL_INDEX_MASK);
    Material material3 = getMaterial(fMaterialData[2] >> MATERIAL_INDEX_SHIFT & MATERIAL_INDEX_MASK);

    // Water data
    bool isTerrain = (fTerrainData[0] & 1) != 0; // 1 = 0b1
    int waterDepth1 = fTerrainData[0] >> 11 & 0xFFF;
    int waterDepth2 = fTerrainData[1] >> 11 & 0xFFF;
    int waterDepth3 = fTerrainData[2] >> 11 & 0xFFF;
    float waterDepth =
        waterDepth1 * IN.texBlend.x +
        waterDepth2 * IN.texBlend.y +
        waterDepth3 * IN.texBlend.z;
    int waterTypeIndex = isTerrain ? fTerrainData[0] >> 3 & 0xFF : 0;
    WaterType waterType = getWaterType(waterTypeIndex);

    // set initial texture map ids
    int colorMap1 = material1.colorMap;
    int colorMap2 = material2.colorMap;
    int colorMap3 = material3.colorMap;

    // only use one flowMap map
    int flowMap = material1.flowMap;

    bool isUnderwater = waterDepth != 0;
    bool isWater = waterTypeIndex > 0 && !isUnderwater;

    vec4 outputColor = vec4(1);

    if (isWater) {
        // sampleWater returns in unicorn-hybrid space. Don't try to convert.
        outputColor = sampleWater(waterTypeIndex, viewDir);
    } else {
        vec2 blendedUv = IN.uv;

        float mipBias = 0;
        // Vanilla tree textures rely on UVs being clamped horizontally, which HD doesn't do at the texture level.
        // Instead we manually clamp vanilla textures with transparency here. Including the transparency check
        // allows texture wrapping to work correctly for the mirror shield.
        if ((fMaterialData[0] >> MATERIAL_FLAG_VANILLA_UVS & 1) == 1 && getMaterialHasTransparency(material1))
            blendedUv.x = clamp(blendedUv.x, 0, .984375);

        vec2 uv1 = blendedUv;
        vec2 uv2 = blendedUv;
        vec2 uv3 = blendedUv;

        // Scroll UVs
        uv1 += material1.scrollDuration * elapsedTime;
        uv2 += material2.scrollDuration * elapsedTime;
        uv3 += material3.scrollDuration * elapsedTime;

        // Scale from the center
        uv1 = (uv1 - .5) * material1.textureScale.xy + .5;
        uv2 = (uv2 - .5) * material2.textureScale.xy + .5;
        uv3 = (uv3 - .5) * material3.textureScale.xy + .5;

        // get flowMap map
        vec2 flowMapUv = uv1 - animationFrame(material1.flowMapDuration);
        float flowMapStrength = material1.flowMapStrength;
        if (isUnderwater)
        {
            // Distort underwater textures
            flowMapUv = worldUvs(1.5) + animationFrame(10 * waterType.duration) * vec2(1, -1);
            flowMapStrength = 0.075;
        }

        vec2 uvFlow = texture(textureArray, vec3(flowMapUv, flowMap)).xy;
        uv1 += uvFlow * flowMapStrength;
        uv2 += uvFlow * flowMapStrength;
        uv3 += uvFlow * flowMapStrength;

        // Set up tangent-space transformation matrix

        vec3 N;
        #if FLAT_SHADING && ZONE_RENDERER
            N = normalize(fFlatNormal);
        #else
            N = normalize(IN.normal);
        #endif
        mat3 TBN = cotangent_frame(N, IN.position, IN.uv * -1.0);

        #if DISPLAY_UV
            FragColor = vec4(fract(uv1 * IN.texBlend.x + uv2 * IN.texBlend.y + uv3 * IN.texBlend.z), 0.0, 1.0);
            if (DISPLAY_UV == 1) return; // Redundant, for syntax highlighting in IntelliJ
        #endif

        #if DISPLAY_NORMAL
            FragColor = vec4(N * 0.5 + 0.5, 1.0);
            if (DISPLAY_NORMAL == 1) return; // Redundant, for syntax highlighting in IntelliJ
        #endif

        #if DISPLAY_TANGENT
            FragColor = vec4(TBN[0] * 0.5 + 0.5, 1.0);
            if (DISPLAY_TANGENT == 1) return; // Redundant, for syntax highlighting in IntelliJ
        #endif

        float selfShadowing = 0;
        vec3 fragPos = IN.position;
        #if PARALLAX_OCCLUSION_MAPPING
            mat3 invTBN = inverse(TBN);
            vec3 tsViewDir = invTBN * viewDir;
            vec3 tsLightDir = invTBN * -lightDir;

            vec3 fragDelta = vec3(0);

            sampleDisplacementMap(material1, tsViewDir, tsLightDir, uv1, fragDelta, selfShadowing);
            sampleDisplacementMap(material2, tsViewDir, tsLightDir, uv2, fragDelta, selfShadowing);
            sampleDisplacementMap(material3, tsViewDir, tsLightDir, uv3, fragDelta, selfShadowing);

            // Average
            fragDelta /= 3;
            selfShadowing /= 3;

            // Prevent displaced surfaces from casting flat shadows onto themselves
            fragDelta.z = max(0, fragDelta.z);

            fragPos += TBN * fragDelta;
        #endif

        vec3 hsl1 = unpackRawHsl(fAlphaBiasHsl[0]);
        vec3 hsl2 = unpackRawHsl(fAlphaBiasHsl[1]);
        vec3 hsl3 = unpackRawHsl(fAlphaBiasHsl[2]);

        // Apply entity tint to HSL
        ivec4 tint = getWorldViewTint(fWorldViewId);
        if (tint.w > 0) {
            hsl1 += ((tint.xyz - hsl1) * tint.w) / 128;
            hsl2 += ((tint.xyz - hsl2) * tint.w) / 128;
            hsl3 += ((tint.xyz - hsl3) * tint.w) / 128;
        }

        // get vertex colors
        vec4 baseColor1 = vec4(convertHsl(hsl1), 1 - float(fAlphaBiasHsl[0] >> 24 & 0xff) / 255.);
        vec4 baseColor2 = vec4(convertHsl(hsl2), 1 - float(fAlphaBiasHsl[1] >> 24 & 0xff) / 255.);
        vec4 baseColor3 = vec4(convertHsl(hsl3), 1 - float(fAlphaBiasHsl[2] >> 24 & 0xff) / 255.);

        // Jagex HSL (from convertHsl) → sRGB-encoded → LINEAR. baseColor* is
        // now LINEAR albedo, ready to multiply against texture & lighting.
        baseColor1.rgb = srgbToLinear(hslToSrgb(baseColor1.xyz));
        baseColor2.rgb = srgbToLinear(hslToSrgb(baseColor2.xyz));
        baseColor3.rgb = srgbToLinear(hslToSrgb(baseColor3.xyz));

        #if DISPLAY_BASE_COLOR
        if (DISPLAY_BASE_COLOR == 1) { // Redundant, used for syntax highlighting in IntelliJ
            outputColor = baseColor1 * IN.texBlend.x + baseColor2 * IN.texBlend.y + baseColor3 * IN.texBlend.z;
            outputColor.rgb = linearToSrgb(outputColor.rgb);
            FragColor = outputColor;
            return;
        }
        #endif

        // get diffuse textures. textureArray is GL_SRGB8_ALPHA8 (MaterialManager.java)
        // so the sampler auto-decodes the bytes to LINEAR. texColor* is LINEAR.
        vec4 texColor1 = colorMap1 == -1 ? vec4(1) : texture(textureArray, vec3(uv1, colorMap1), mipBias);
        vec4 texColor2 = colorMap2 == -1 ? vec4(1) : texture(textureArray, vec3(uv2, colorMap2), mipBias);
        vec4 texColor3 = colorMap3 == -1 ? vec4(1) : texture(textureArray, vec3(uv3, colorMap3), mipBias);
        texColor1.rgb *= material1.brightness;
        texColor2.rgb *= material2.brightness;
        texColor3.rgb *= material3.brightness;

        ivec3 isOverlay = ivec3(
            fMaterialData[0] >> MATERIAL_FLAG_IS_OVERLAY & 1,
            fMaterialData[1] >> MATERIAL_FLAG_IS_OVERLAY & 1,
            fMaterialData[2] >> MATERIAL_FLAG_IS_OVERLAY & 1
        );
        int overlayCount = isOverlay[0] + isOverlay[1] + isOverlay[2];
        ivec3 isUnderlay = ivec3(1) - isOverlay;
        int underlayCount = isUnderlay[0] + isUnderlay[1] + isUnderlay[2];

        // calculate blend amounts for overlay and underlay vertices
        vec3 underlayBlend = IN.texBlend * isUnderlay;
        vec3 overlayBlend = IN.texBlend * isOverlay;

        if (underlayCount == 0 || overlayCount == 0)
        {
            // if a tile has all overlay or underlay vertices,
            // use the default blend

            underlayBlend = IN.texBlend;
            overlayBlend = IN.texBlend;
        }
        else
        {
            // if there's a mix of overlay and underlay vertices,
            // calculate custom blends for each 'layer'

            float underlayBlendMultiplier = 1.0 / (underlayBlend[0] + underlayBlend[1] + underlayBlend[2]);
            // adjust back to 1.0 total
            underlayBlend *= underlayBlendMultiplier;
            underlayBlend = clamp(underlayBlend, 0, 1);

            float overlayBlendMultiplier = 1.0 / (overlayBlend[0] + overlayBlend[1] + overlayBlend[2]);
            // adjust back to 1.0 total
            overlayBlend *= overlayBlendMultiplier;
            overlayBlend = clamp(overlayBlend, 0, 1);
        }


        // get fragment colors by combining vertex colors and texture samples
        vec4 texA = getMaterialShouldOverrideBaseColor(material1) ? texColor1 : vec4(texColor1.rgb * baseColor1.rgb, min(texColor1.a, baseColor1.a));
        vec4 texB = getMaterialShouldOverrideBaseColor(material2) ? texColor2 : vec4(texColor2.rgb * baseColor2.rgb, min(texColor2.a, baseColor2.a));
        vec4 texC = getMaterialShouldOverrideBaseColor(material3) ? texColor3 : vec4(texColor3.rgb * baseColor3.rgb, min(texColor3.a, baseColor3.a));

        // combine fragment colors based on each blend, creating
        // one color for each overlay/underlay 'layer'
        vec4 underlayColor = texA * underlayBlend.x + texB * underlayBlend.y + texC * underlayBlend.z;
        vec4 overlayColor = texA * overlayBlend.x + texB * overlayBlend.y + texC * overlayBlend.z;

        float overlayMix = 0;

        if (overlayCount > 0 && underlayCount > 0)
        {
            ivec3 isPrimary = isUnderlay;
            bool invert = true;
            if (overlayCount == 1) {
                isPrimary = isOverlay;
                invert = false;
            }

            float result = dot(IN.texBlend, isPrimary);
            if (invert)
                result = 1 - result;

            result = clamp(result * 2 - 1, 0, 1);
            overlayMix = result;
        }

        outputColor = mix(underlayColor, overlayColor, overlayMix);

        // Probe-scope shadows for per-fragment stack metadata.
        _probeBaseColor = baseColor1.rgb * IN.texBlend.x + baseColor2.rgb * IN.texBlend.y + baseColor3.rgb * IN.texBlend.z;
        _probeColorMap1 = colorMap1;
        _probeColorMap2 = colorMap2;

        #if !LEGACY_RENDERER
            // ── debug probe: capture outputColor right after base/texture blend, before any lighting ──
            if (debugProbeArm != 0 && ivec2(gl_FragCoord.xy) == debugProbePixelScene) {
                debugProbeData[16] = vec4(outputColor.rgb, outputColor.a);
                debugProbeData[17].x = float(overlayCount);
                debugProbeData[17].y = float(underlayCount);
                debugProbeData[17].z = float(colorMap1);
                debugProbeData[17].w = float(colorMap2);
            }
        #endif

        // normals
        vec3 normals;
        if ((fMaterialData[0] >> MATERIAL_FLAG_UPWARDS_NORMALS & 1) == 1) {
            normals = vec3(0, -1, 0);
        } else {
            vec3 n1 = sampleNormalMap(material1, uv1, TBN);
            vec3 n2 = sampleNormalMap(material2, uv2, TBN);
            vec3 n3 = sampleNormalMap(material3, uv3, TBN);
            normals = normalize(n1 * IN.texBlend.x + n2 * IN.texBlend.y + n3 * IN.texBlend.z);
        }

        float lightDotNormals = dot(normals, lightDir);
        float downDotNormals = dot(downDir, normals);
        float viewDotNormals = dot(viewDir, normals);

        #if DISABLE_DIRECTIONAL_SHADING
            lightDotNormals = .7;
        #endif

        float shadow = 0;
        if ((fMaterialData[0] >> MATERIAL_FLAG_DISABLE_SHADOW_RECEIVING & 1) == 0)
            shadow = sampleShadowMap(fragPos, vec2(0), lightDotNormals);
        shadow = max(shadow, selfShadowing);
        float inverseShadow = 1 - shadow;

        #if DISPLAY_SHADOWS
            FragColor = vec4(inverseShadow, inverseShadow, inverseShadow, 1.0);
            if (DISPLAY_SHADOWS == 1) return; // Redundant, for syntax highlighting in IntelliJ
        #endif

        // specular
        vec3 vSpecularGloss = vec3(material1.specularGloss, material2.specularGloss, material3.specularGloss);
        vec3 vSpecularStrength = vec3(material1.specularStrength, material2.specularStrength, material3.specularStrength);
        // Roughness maps are data, not colors. Sampler auto-decoded to LINEAR
        // for us; linearToSrgb undoes that so we get back the byte-as-float
        // value the artist authored. Same trick is used on normal maps.
        vSpecularStrength *= vec3(
            material1.roughnessMap == -1 ? 1 : linearToSrgb(texture(textureArray, vec3(uv1, material1.roughnessMap)).r),
            material2.roughnessMap == -1 ? 1 : linearToSrgb(texture(textureArray, vec3(uv2, material2.roughnessMap)).r),
            material3.roughnessMap == -1 ? 1 : linearToSrgb(texture(textureArray, vec3(uv3, material3.roughnessMap)).r)
        );

        // apply specular highlights to anything semi-transparent
        // this isn't always desirable but adds subtle light reflections to windows, etc.
        if (baseColor1.a + baseColor2.a + baseColor3.a < 2.99)
        {
            vSpecularGloss = vec3(30);
            vSpecularStrength = vec3(
                clamp((1 - baseColor1.a) * 2, 0, 1),
                clamp((1 - baseColor2.a) * 2, 0, 1),
                clamp((1 - baseColor3.a) * 2, 0, 1)
            );
        }
        float combinedSpecularStrength = dot(vSpecularStrength, IN.texBlend);


        // calculate lighting — all light contributions below are in LINEAR space.
        // They sum into compositeLight which is then multiplied into the albedo.

        // ambient light
        vec3 ambientLightOut = ambientColor * ambientStrength;

        float aoFactor =
            IN.texBlend.x * (material1.ambientOcclusionMap == -1 ? 1 : texture(textureArray, vec3(uv1, material1.ambientOcclusionMap)).r) +
            IN.texBlend.y * (material2.ambientOcclusionMap == -1 ? 1 : texture(textureArray, vec3(uv2, material2.ambientOcclusionMap)).r) +
            IN.texBlend.z * (material3.ambientOcclusionMap == -1 ? 1 : texture(textureArray, vec3(uv3, material3.ambientOcclusionMap)).r);
        ambientLightOut *= aoFactor;

        // directional light
        vec3 dirLightColor = lightColor * lightStrength;

        // underwater caustics based on directional light
        if (underwaterCaustics && underwaterEnvironment) {
            float scale = 12.8;
            vec2 causticsUv = worldUvs(scale);

            const ivec2 direction = ivec2(1, -1);
            const int driftSpeed = 231;
            vec2 drift = animationFrame(231) * ivec2(1, -2);
            vec2 flow1 = causticsUv + animationFrame(19) * direction + drift;
            vec2 flow2 = causticsUv * 1.25 + animationFrame(37) * -direction + drift;

            vec3 caustics = sampleCaustics(flow1, flow2) * 2;

            vec3 causticsColor = underwaterCausticsColor * underwaterCausticsStrength;
            dirLightColor += caustics * causticsColor * lightDotNormals * pow(lightStrength, 1.5);
        }

        // apply shadows
        dirLightColor *= inverseShadow;

        vec3 lightColor = dirLightColor;
        vec3 lightOut = max(lightDotNormals, 0.0) * lightColor;

        // directional light specular
        vec3 lightReflectDir = reflect(-lightDir, normals);
        vec3 lightSpecularOut = lightColor * specular(IN.texBlend, viewDir, lightReflectDir, vSpecularGloss, vSpecularStrength);

        // point lights
        vec3 pointLightsOut = vec3(0);
        vec3 pointLightsSpecularOut = vec3(0);
        calculateLighting(IN.position, normals, viewDir, IN.texBlend, vSpecularGloss, vSpecularStrength, pointLightsOut, pointLightsSpecularOut);

        // sky light. fogColor uniform is sRGB-encoded for both renderers (zone's
        // upload now applies linearToSrgb to match legacy). Treated as LINEAR
        // here for lighting math — same "unicorn" convention used by the water
        // gradient stops. Legacy was tuned this way; zone now matches.
        vec3 skyLightColor = fogColor;
        float skyLightStrength = 0.5;
        float skyDotNormals = downDotNormals;
        vec3 skyLightOut = max(skyDotNormals, 0.0) * skyLightColor * skyLightStrength;


        // lightning
        vec3 lightningColor = vec3(.25, .25, .25);
        float lightningStrength = lightningBrightness;
        float lightningDotNormals = downDotNormals;
        vec3 lightningOut = max(lightningDotNormals, 0.0) * lightningColor * lightningStrength;


        // underglow
        vec3 underglowOut = underglowColor * max(normals.y, 0) * underglowStrength;


        // fresnel reflection
        float baseOpacity = 0.4;
        float fresnel = 1.0 - clamp(viewDotNormals, 0.0, 1.0);
        float finalFresnel = clamp(mix(baseOpacity, 1.0, fresnel * 1.2), 0.0, 1.0);
        vec3 surfaceColor = vec3(0);
        vec3 surfaceColorOut = surfaceColor * max(combinedSpecularStrength, 0.2);


        // apply lighting
        vec3 compositeLight = ambientLightOut + lightOut + lightSpecularOut + skyLightOut + lightningOut +
        underglowOut + pointLightsOut + pointLightsSpecularOut + surfaceColorOut;

        #if DISPLAY_LIGHTING
            FragColor = vec4(compositeLight, 1.0);
            if (DISPLAY_LIGHTING == 1) return; // Redundant, for syntax highlighting in IntelliJ
        #endif

        float unlit = dot(IN.texBlend, vec3(
            getMaterialIsUnlit(material1),
            getMaterialIsUnlit(material2),
            getMaterialIsUnlit(material3)
        ));

        // Surface vibrance / probe support: shadow lighting magnitude into function scope
        _probeUnlit = unlit;
        _probeCompositeLightLen = length(compositeLight);

        // Point-light-driven legacy tag. Metric is the fraction of total composite
        // light luminance contributed by point lights (diffuse + specular), passed
        // through a smoothstep so the transition between "sun-dominated" and
        // "point-light-dominated" is sharp instead of linear. Sample-derived cuts:
        // overworld with strong point light measures ratio ≈ 0.37 (want ~0), eclipse
        // moon attack ≈ 0.69 (want ~1). smoothstep(0.3, 0.7) hits both: 0.37 → 0.08,
        // 0.69 → 1.00. Slider is a linear multiplier on the curve output.
        vec3 luminanceWeights = vec3(0.2126, 0.7152, 0.0722);
        float pointLightLum = dot(pointLightsOut + pointLightsSpecularOut, luminanceWeights);
        float compositeLightLum = dot(compositeLight, luminanceWeights);
        float pointLightFraction = pointLightLum / max(compositeLightLum, 1e-5);
        pointLightTag = clamp(
            smoothstep(0.3, 0.7, pointLightFraction) * agxPointLightVibrance,
            0.0, 1.0
        );

        #if VANILLA_COLOR_BANDING
            outputColor.rgb = linearToSrgb(outputColor.rgb);
            outputColor.rgb = srgbToHsv(outputColor.rgb);
            outputColor.b = floor(outputColor.b * 127) / 127;
            outputColor.rgb = hsvToSrgb(outputColor.rgb);
            outputColor.rgb = srgbToLinear(outputColor.rgb);
        #endif

        // Apply lighting to the albedo: outputColor (LINEAR) × compositeLight
        // (LINEAR) = lit_albedo (LINEAR, may be HDR > 1 with dir × 4).
        #if !LEGACY_RENDERER
            // ── debug probe: capture outputColor right BEFORE the lighting multiply ──
            if (debugProbeArm != 0 && ivec2(gl_FragCoord.xy) == debugProbePixelScene) {
                debugProbeData[18] = vec4(outputColor.rgb, outputColor.a);
                debugProbeData[19] = vec4(compositeLight, unlit);
                debugProbeData[20] = vec4(tint.xyz, tint.w);
            }
        #endif

        if (tint.w > 0) {
            outputColor.rgb *= 1.0 + skyLightOut;
        } else {
            outputColor.rgb *= mix(compositeLight, vec3(1), unlit);
        }

        #if !LEGACY_RENDERER
            // Per-fragment hasAttachedLightBlend drives the R8 tag attachment that
            // tonemap_frag samples to apply AgX-time chroma compensation. The previous
            // per-fragment inverse-AgX path was removed — see docs/agx-tag-mrt-plan.md
            // for why that approach was structurally wrong (operating on a color that
            // wasn't what AgX eventually saw, then diluted by alpha blend and OKLab
            // encode before reaching the tonemap).
            float hasAttachedLightBlend = dot(IN.texBlend, vec3(
                (fMaterialData[0] >> MATERIAL_FLAG_HAS_ATTACHED_LIGHT & 1),
                (fMaterialData[1] >> MATERIAL_FLAG_HAS_ATTACHED_LIGHT & 1),
                (fMaterialData[2] >> MATERIAL_FLAG_HAS_ATTACHED_LIGHT & 1)
            ));
            _probeHasAttachedLightBlend = hasAttachedLightBlend;
            // Per-material legacy-clip signal: materials.json `legacyHighlightClip: true`
            // packs MaterialStruct.flags bit 3, blended through IN.texBlend the same way
            // unlit and hasAttachedLight are. Full-strength (1.0) contribution to fragTag.
            legacyHighlightBlend = dot(IN.texBlend, vec3(
                getMaterialIsLegacyClip(material1),
                getMaterialIsLegacyClip(material2),
                getMaterialIsLegacyClip(material3)
            ));
            if (debugAttachedLightTint != 0 && hasAttachedLightBlend > 0.0) {
                // Visual debug only: additive magenta wash over tagged fragments.
                outputColor.rgb += vec3(5.0, 0.0, 5.0) * hasAttachedLightBlend;
            }

            // ── debug probe writes for scene_frag (slots 0..3) ──
            if (debugProbeArm != 0 && ivec2(gl_FragCoord.xy) == debugProbePixelScene) {
                debugProbeData[0] = vec4(outputColor.rgb, hasAttachedLightBlend);
                debugProbeData[1] = vec4(
                    intBitsToFloat(fMaterialData[0]),
                    intBitsToFloat(fMaterialData[1]),
                    intBitsToFloat(fMaterialData[2]),
                    0.0
                );
                debugProbeData[2] = vec4(IN.texBlend, 0.0);
                debugProbeData[3] = vec4(outputColor.rgb, hasAttachedLightBlend);
                debugProbeData[15].x = float(int(gl_FragCoord.x));
                debugProbeData[15].y = float(int(gl_FragCoord.y));
                debugProbeData[15].z += 1.0; // shaderHits (scene)
            }

            // Mirror legacy's RGBA8 clip-at-write behavior, but ONLY for tagged
            // fragments. Without this, a tagged HDR-bright fragment with more than
            // one channel above 1 (e.g. fire's lit (5.2, 0.69, 0.003) or the nagua
            // ring's (6.93, 1.94, 0.002)) carries its full HDR magnitudes through
            // the OKLab round-trip and the per-channel ratio survives the alpha
            // blend. Legacy would have collapsed both over-1 channels to 1 at the
            // RGBA8 storage write, making R = G in the encoded space and producing
            // yellow after blending. Clamping linear to [0,1] here is equivalent
            // pre-linearToSrgb (linearToSrgb is monotonic; clip-before is the same
            // as clip-after for values in [0,1]). Untagged HDR scenery is unaffected
            // and keeps its AgX rolloff at tonemap time.
            outputColor.rgb = mix(outputColor.rgb, min(outputColor.rgb, vec3(1.0)), hasAttachedLightBlend);
        #endif

        // ─── transition LINEAR → sRGB-encoded ───
        // Puts terrain in the same space legacy uses for the rest of its
        // pipeline. sampleUnderwater expects this (multiplies by sRGB-encoded
        // depthColor); the fog mix below also runs in this space.
        outputColor.rgb = linearToSrgb(outputColor.rgb);

        if (isUnderwater) {
            // Multiplies outputColor (sRGB-encoded) by mix(1, depthColor, t).
            // depthColor is sRGB-encoded, so this is sRGB × sRGB.
            sampleUnderwater(outputColor.rgb, waterType, waterDepth, lightDotNormals);
        }
    }
    // Beyond this point, outputColor.rgb is sRGB-encoded for terrain branches
    // and unicorn-hybrid for water (≈ sRGB-encoded magnitude). Either way, NOT
    // linear, and downstream code should treat it as display-space-ish.

    #if LEGACY_RENDERER
        vec2 tiledist = abs(floor(IN.position.xz / 128) - floor(cameraPos.xz / 128));
        float maxDist = max(tiledist.x, tiledist.y);
        if (maxDist > drawDistance) {
            // Rapidly fade out any geometry that extends beyond the draw distance.
            // This is required if we always draw all underwater terrain.
            outputColor.a *= -256;
        }
    #endif

    // Clamp before the GL alpha blend so per-channel saturation of HDR-bright
    // values (notably water specular peaks) collapses to neutral white the way
    // legacy's RGBA8 storage forces it to. Without this, channel ratios are
    // preserved through the alpha multiplication and bright peaks display with
    // their underlying tint (e.g. bluish sun glints on water).
    //outputColor.rgb = clamp(outputColor.rgb, 0, 1);

    #if LEGACY_RENDERER
        outputColor.rgb = clamp(outputColor.rgb, 0, 1);
        // Skip unnecessary color conversion if possible
        if (saturation != 1 || contrast != 1) {
            vec3 hsv = srgbToHsv(outputColor.rgb);

            // Apply saturation setting
            hsv.y *= saturation;

            // Apply contrast setting
            if (hsv.z > 0.5) {
                hsv.z = 0.5 + ((hsv.z - 0.5) * contrast);
            } else {
                hsv.z = 0.5 - ((0.5 - hsv.z) * contrast);
            }

            outputColor.rgb = hsvToSrgb(hsv);
        }

        outputColor.rgb = colorBlindnessCompensation(outputColor.rgb);

        #if APPLY_COLOR_FILTER
            outputColor.rgb = applyColorFilter(outputColor.rgb);
        #endif
    #endif

    #if WIREFRAME
        outputColor.rgb *= wireframeMask();
    #endif

    // apply fog
    if (!isUnderwater) {
        // ground fog
        float distance = distance(IN.position, cameraPos);
        float closeFadeDistance = 1500;
        float groundFog = 1.0 - clamp((IN.position.y - groundFogStart) / (groundFogEnd - groundFogStart), 0.0, 1.0);
        groundFog = mix(0.0, groundFogOpacity, groundFog);
        groundFog *= clamp(distance / closeFadeDistance, 0.0, 1.0);

        // multiply the visibility of each fog
        float fogAmount = calculateFogAmount(IN.position);
        float combinedFog = 1 - (1 - fogAmount) * (1 - groundFog);

        if (isWater) {
            outputColor.a = combinedFog + outputColor.a * (1 - combinedFog);
        }

        #if LEGACY_RENDERER
            // outputColor and fogColor are both sRGB-encoded; direct mix in
            // sRGB-encoded space matches the convention legacy always used.
            outputColor.rgb = mix(outputColor.rgb, fogColor, combinedFog);
        #else
            // Currently identical to the legacy branch — both inputs are sRGB-encoded
            // (outputColor from the wrap above, fogColor from the ZoneRenderer upload
            // that now applies linearToSrgb to match). Kept as a separate branch
            // because if the whole sRGB-blend strategy gets swapped for OKLab, the
            // zone fog mix will move to OKLab while legacy's stays as-is.
            outputColor.rgb = mix(outputColor.rgb, fogColor, combinedFog);
        #endif
    }

    #if LEGACY_RENDERER
        outputColor.rgb = pow(outputColor.rgb, vec3(gammaCorrection));

        #if WINDOWS_HDR_CORRECTION
            outputColor.rgb = windowsHdrCorrection(outputColor.rgb);
        #endif
    #endif

    #if !LEGACY_RENDERER
        // ─── transition sRGB-encoded → OKLab ───
        // Up to this point outputColor.rgb is sRGB-encoded (terrain) or
        // unicorn-hybrid (water, ≈ sRGB-encoded magnitude). Convert to OKLab
        // so the GL alpha blend that follows interpolates perceptually rather
        // than in sRGB-byte space. tonemap_frag converts back to sRGB-encoded
        // for display.
        outputColor.rgb = linearToOklab(srgbToLinear(outputColor.rgb));
    #endif

    // FragColor convention:
    //   Zone — OKLab (L, a, b). RGBA16F FBO; GL alpha blend interpolates the
    //          three OKLab channels per-channel linearly, which IS a
    //          perceptually-uniform interpolation. tonemap_frag converts back.
    //   Legacy — sRGB-encoded. RGBA8 FBO; alpha blend in byte space; display
    //            interprets bytes as sRGB.
    #if !LEGACY_RENDERER
        // ── debug probe: capture every fragment that writes to this pixel ──
        // Each entry is 2 vec4 starting at slot 24:
        //   slot 24+2k:   outputColor.rgba — what GL blends as src into the OKLab FBO
        //                 (rgb = OKLab encoded for zone, a = blend alpha).
        //   slot 24+2k+1: (hasAttachedLightBlend, intBitsToFloat(fMaterialData[0]),
        //                  unlit, length(compositeLight)).
        // hasAttachedLightBlend/unlit/compositeLight are zero for water fragments.
        if (debugProbeArm != 0 && ivec2(gl_FragCoord.xy) == debugProbePixelScene) {
            uint idx = atomicAdd(sceneFragHits, 1u);
            if (idx < 24u) {
                uint base = 24u + 3u * idx;
                debugProbeData[base] = outputColor;
                debugProbeData[base + 1u] = vec4(
                    _probeHasAttachedLightBlend,
                    intBitsToFloat(fMaterialData[0]),
                    _probeUnlit,
                    _probeCompositeLightLen
                );
                debugProbeData[base + 2u] = vec4(
                    _probeBaseColor,
                    intBitsToFloat(_probeColorMap1)
                );
            }
        }
    #endif

    FragColor = outputColor;
    #if !LEGACY_RENDERER
        // Tag mask, written to a second R8 attachment that gets alpha-blended through
        // the scene pass the same way FragColor is. Two things must be true for a
        // fragment to push the per-pixel tag up:
        //   (1) the fragment came from tagged geometry (hasAttachedLightBlend > 0); and
        //   (2) the fragment actually contributes visible brightness (outputColor.r —
        //       OKLab L at this point — is clamped to [0,1]; near-zero means the
        //       fragment is essentially invisible, e.g. the GOTR barrier dummy whose
        //       lit color is 0 and whose alpha is ~0.004).
        // Without (2), an invisible-but-tagged near-transparent draw would still
        // contribute its alpha-weighted fraction to the tag and compensate background
        // pixels that the user never sees a tagged contribution at.
        // (Declared vec4 for driver compatibility — single-float outputs to R8
        // attachments were silently dropped on at least one Nvidia driver build.)
        //
        // Bit 7 (MATERIAL_FLAG_HAS_ATTACHED_LIGHT) has context-sensitive semantics
        // based on isTerrain:
        //   - On objects (isTerrain=false): bit 7 = "this object is tagged for
        //     subtle glow compensation" (set by lights.json auto-tag or
        //     ModelOverride.legacyHighlightClip). Goes through the vibrance×gate
        //     path so the user's agxSurfaceVibrance slider tunes object glow and
        //     so invisible-but-tagged transparent draws don't accumulate (e.g.
        //     GOTR barrier dummy: lit colour 0, alpha ~0.004).
        //   - On tiles (isTerrain=true): bit 7 = "this tile's groundMaterial is
        //     explicitly tagged for legacy clip" (set by uploadTilePaint/Model
        //     when groundMaterial.legacyHighlightClip is true). Promoted to the
        //     full-strength legacyHighlightBlend path, matching how per-material
        //     bit 3 already works for tiles that happen to get a flagged Material
        //     assigned (e.g. karamja's vanilla-LAVA-texture path).
        float tileFullStrength = isTerrain ? _probeHasAttachedLightBlend : 0.0;
        float objectAttached = isTerrain ? 0.0 : _probeHasAttachedLightBlend;
        // outputColor.r here is OKLab L (lightness); see the FBO-convention block above.
        // Both the attached-light and point-light paths use it as a brightness gate so
        // dim fragments don't get pushed toward the legacy hard-clip target, which is
        // strictly darker than AgX below the per-channel clamp threshold.
        float lightnessGate = clamp(outputColor.r, 0.0, 1.0);
        float attached = objectAttached * agxSurfaceVibrance * lightnessGate;
        float pointGated = pointLightTag * lightnessGate;
        float tagContribution = max(
            attached,
            max(legacyHighlightBlend, max(tileFullStrength, pointGated))
        );
        fragTag = vec4(tagContribution);
    #endif
}
