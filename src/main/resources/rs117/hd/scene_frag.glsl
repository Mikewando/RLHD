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
#include <uniforms/sky.glsl>
#include <uniforms/world_views.glsl>
#include <uniforms/materials.glsl>
#include <uniforms/water_types.glsl>

#include <utils/sky_fog.glsl>
#include <utils/hash.glsl>

#include MATERIAL_CONSTANTS
#include WATER_PASS

uniform sampler2DArray textureArray;
uniform sampler2D shadowMap;
#if TERRAIN_SHADOWS
    #if SHADOW_FILTERING == SHADOW_FILTERING_PCSS
        uniform sampler2D terrainShadowMap;
    #else
        uniform sampler2DShadow terrainShadowMap;
    #endif
#endif
uniform usampler2DArray tiledLightingArray;

// general HD settings

flat in int fWorldViewId;
flat in ivec3 fAlphaBiasHsl;
flat in ivec3 fMaterialData;
flat in ivec3 fTerrainData;

in FragmentData {
    vec3 position;
    vec2 uv;
    vec3 normal;
    #if CENTROID_QUALIFIER
        // Prevent negative components due to MSAA
        centroid in vec3 texBlend;
    #else
        vec3 texBlend;
    #endif
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
    return -(uboGlobal.sceneBase + IN.position.xz) / (128 * scale);
}

#include <utils/constants.glsl>
#include <utils/misc.glsl>
#include <utils/output_transform.glsl>
#include <utils/caustics.glsl>
#include <utils/color_utils.glsl>
#include <utils/normals.glsl>
#include <utils/specular.glsl>
#include <utils/displacement.glsl>
#include <utils/shadows.glsl>
#include <utils/fog.glsl>
#include <utils/wireframe.glsl>
#include <utils/lights.glsl>
#include <utils/sky.glsl>
#include <utils/legacy_water.glsl>
#include <utils/water.glsl>

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
//                    waterColor* uniforms are sRGB-encoded by convention —
//                    that's the magnitude the shader's water mix was tuned
//                    around. fogColor is LINEAR (since the day & night cycle)
//                    and is converted with linearToSrgb where it's mixed in.
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
    bool isTerrain = (fTerrainData[0] & 1) != 0;
    bool isSquashed = isWorldViewSquashed(fWorldViewId);
    #if LEGACY_BOAT_SILHOUETTES
        isSquashed = false;
    #endif

    vec3 downDir = vec3(0, -1, 0);
    // View & light directions are from the fragment to the camera/light
    vec3 viewDir = normalize(uboGlobal.cameraPos - IN.position);
    vec3 flatNormal = normalize(cross(dFdx(IN.position), dFdy(IN.position)));

    #if !LEGACY_RENDERER
        // Default the second colour attachment so non-terrain branches (water,
        // early-return paths) don't leave it undefined.
        fragTag = vec4(0.0);
    #endif

    // Function-scope tag inputs so the fragTag write at the end of main() can read
    // them after the terrain block closes. Populated inside the non-water terrain
    // branch when available, else stay zero (water fragments contribute no tag).
    //   hasAttachedLightBlend  — bit 21 (MATERIAL_FLAG_HAS_ATTACHED_LIGHT) blended
    //                            across the three materials by IN.texBlend. Set by
    //                            ModelOverride.legacyHighlightClip + lights.json
    //                            auto-tag in SceneUploader/ModelStreamingManager.
    //                            Used for both the per-tile (full-strength) and
    //                            per-object (vibrance-scaled) paths, split by
    //                            isTerrain at the tag-write site.
    //   legacyHighlightBlend   — per-material bit 3 (MATERIAL_FLAG_IS_LEGACY_CLIP)
    //                            blended the same way. Full-strength contribution
    //                            (e.g. lava materials in materials.json).
    //   pointLightTag          — smoothstep of point-light fraction of composite
    //                            light luminance.
    float hasAttachedLightBlend = 0.0;
    float legacyHighlightBlend = 0.0;
    float pointLightTag = 0.0;

    bool identicalMaterials = !isTerrain || (
        ((fMaterialData[0] ^ fMaterialData[1] | (fMaterialData[0] ^ fMaterialData[2]))
        >> MATERIAL_INDEX_SHIFT & MATERIAL_INDEX_MASK) == 0
    );
    Material material1;
    if (isSquashed) {
        material1 = MAT_NONE;
        identicalMaterials = true;
    } else {
        material1 = getMaterial(fMaterialData[0] >> MATERIAL_INDEX_SHIFT & MATERIAL_INDEX_MASK);
    }
    Material material2 = identicalMaterials ? material1 :
        getMaterial(fMaterialData[1] >> MATERIAL_INDEX_SHIFT & MATERIAL_INDEX_MASK);
    Material material3 = identicalMaterials ? material1 :
        getMaterial(fMaterialData[2] >> MATERIAL_INDEX_SHIFT & MATERIAL_INDEX_MASK);

    // Water data
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
    #if LEGACY_RENDERER
        bool isWater = waterTypeIndex > 0 && !isUnderwater;
    #else
        const bool isWater = WATER_PASS != 0;
    #endif

    vec4 outputColor = vec4(1);

    #if WATER_PASS
        outputColor = sampleWater(waterTypeIndex, viewDir);
    #else
    #if LEGACY_RENDERER
    if (isWater) {
        // sampleWater returns in unicorn-hybrid space. Don't try to convert.
        outputColor = sampleWater(waterTypeIndex, viewDir);
    } else
    #endif
    {
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
        uv1 += material1.scrollDuration * uboGlobal.elapsedTime;
        uv2 += material2.scrollDuration * uboGlobal.elapsedTime;
        uv3 += material3.scrollDuration * uboGlobal.elapsedTime;

        // Scale from the center
        uv1 = (uv1 - .5) * material1.textureScale.xy + .5;
        uv2 = (uv2 - .5) * material2.textureScale.xy + .5;
        uv3 = (uv3 - .5) * material3.textureScale.xy + .5;

        // get flowMap map
        vec2 flowMapUv = uv1 - animationFrame(material1.flowMapDuration);
        float flowMapStrength = material1.flowMapStrength;
        if (isUnderwater) {
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
        #if FLAT_SHADING
            N = flatNormal;
        #else
            N = normalize(IN.normal);
        #endif
        if (isSquashed)
            N = vec3(0, -1, 0);

        #if DISPLAY_UV
            FragColor = vec4(fract(uv1 * IN.texBlend.x + uv2 * IN.texBlend.y + uv3 * IN.texBlend.z), 0.0, 1.0);
            if (DISPLAY_UV == 1) // Redundant, for syntax highlighting in IntelliJ
                return;
        #endif

        #if DISPLAY_NORMAL
            FragColor = vec4(N * 0.5 + 0.5, 1.0);
            if (DISPLAY_NORMAL == 1) // Redundant, for syntax highlighting in IntelliJ
                return;
        #endif

        #if DISPLAY_TANGENT
            FragColor = vec4(cotangent_frame(N, IN.position, IN.uv * -1.0)[0] * 0.5 + 0.5, 1.0);
            if (DISPLAY_TANGENT == 1) // Redundant, for syntax highlighting in IntelliJ
                return;
        #endif

        vec3 fragPos = IN.position;
        #if PARALLAX_OCCLUSION_MAPPING
            applyDisplacement(
                fragPos,
                uv1, uv2, uv3,
                material1, material2, material3,
                identicalMaterials,
                IN.texBlend,
                flatNormal,
                N,
                viewDir
            );
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

        if (isSquashed)
            baseColor1 = baseColor2 = baseColor3 = baseColor1 * .4;

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
        vec4 texColor2 = identicalMaterials ? texColor1 :
            colorMap2 == -1 ? vec4(1) : texture(textureArray, vec3(uv2, colorMap2), mipBias);
        vec4 texColor3 = identicalMaterials ? texColor1 :
            colorMap3 == -1 ? vec4(1) : texture(textureArray, vec3(uv3, colorMap3), mipBias);
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

        if (underlayCount == 0 || overlayCount == 0) {
            // if a tile has all overlay or underlay vertices,
            // use the default blend

            underlayBlend = IN.texBlend;
            overlayBlend = IN.texBlend;
        } else {
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
        vec4 texA = getMaterialShouldOverrideBaseColor(material1) ? texColor1 :
            vec4(texColor1.rgb * baseColor1.rgb, min(texColor1.a, baseColor1.a));
        vec4 texB = getMaterialShouldOverrideBaseColor(material2) ? texColor2 :
            vec4(texColor2.rgb * baseColor2.rgb, min(texColor2.a, baseColor2.a));
        vec4 texC = getMaterialShouldOverrideBaseColor(material3) ? texColor3 :
            vec4(texColor3.rgb * baseColor3.rgb, min(texColor3.a, baseColor3.a));

        // combine fragment colors based on each blend, creating
        // one color for each overlay/underlay 'layer'
        vec4 underlayColor = texA * underlayBlend.x + texB * underlayBlend.y + texC * underlayBlend.z;
        vec4 overlayColor = texA * overlayBlend.x + texB * overlayBlend.y + texC * overlayBlend.z;

        float overlayMix = 0;

        if (overlayCount > 0 && underlayCount > 0) {
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

        // normals
        vec3 normals;
        if ((fMaterialData[0] >> MATERIAL_FLAG_UPWARDS_NORMALS & 1) == 1) {
            normals = vec3(0, -1, 0);
        } else {
            mat3 TBN = cotangent_frame(N, IN.position, IN.uv * -1.0);
            vec3 n1 = sampleNormalMap(material1, uv1, TBN);
            if (identicalMaterials) {
                normals = normalize(n1);
            } else {
                vec3 n2 = sampleNormalMap(material2, uv2, TBN);
                vec3 n3 = sampleNormalMap(material3, uv3, TBN);
                normals = normalize(n1 * IN.texBlend.x + n2 * IN.texBlend.y + n3 * IN.texBlend.z);
            }
        }

        float lightDotNormals = dot(normals, uboGlobal.lightDir);
        float downDotNormals = dot(downDir, normals);
        float viewDotNormals = dot(viewDir, normals);

        #if DISABLE_DIRECTIONAL_SHADING
            lightDotNormals = .7;
        #endif

		float shadow = 0;
		if ((fMaterialData[0] >> MATERIAL_FLAG_DISABLE_SHADOW_RECEIVING & 1) == 0) {
			bool applyNormalBias = (fMaterialData[0] >> MATERIAL_FLAG_SHADOW_NORMAL_BIAS & 1) == 1;
			shadow = sampleShadowMap(fragPos, flatNormal, true, applyNormalBias, true);
		}
        float inverseShadow = 1 - shadow;

        #if DISPLAY_SHADOWS
            FragColor = vec4(inverseShadow, inverseShadow, inverseShadow, 1.0);
            if (DISPLAY_SHADOWS == 1) // Redundant, for syntax highlighting in IntelliJ
                return;
        #endif

        // specular
        vec3 vSpecularGloss = vec3(material1.specularGloss, material2.specularGloss, material3.specularGloss);
        vec3 vSpecularStrength = vec3(material1.specularStrength, material2.specularStrength, material3.specularStrength);
        // Roughness maps are data, not colors. Sampler auto-decoded to LINEAR
        // for us; linearToSrgb undoes that so we get back the byte-as-float
        // value the artist authored. Same trick is used on normal maps.
        float roughness1 = material1.roughnessMap == -1 ? 1 :
            linearToSrgb(texture(textureArray, vec3(uv1, material1.roughnessMap)).r);
        vSpecularStrength *= vec3(
            roughness1,
            identicalMaterials ? roughness1 :
                material2.roughnessMap == -1 ? 1 : linearToSrgb(texture(textureArray, vec3(uv2, material2.roughnessMap)).r),
            identicalMaterials ? roughness1 :
                material3.roughnessMap == -1 ? 1 : linearToSrgb(texture(textureArray, vec3(uv3, material3.roughnessMap)).r)
        );

        // apply specular highlights to anything semi-transparent
        // this isn't always desirable but adds subtle light reflections to windows, etc.
        if (baseColor1.a + baseColor2.a + baseColor3.a < 2.99) {
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
        vec3 ambientLightOut = uboGlobal.ambientColor * uboGlobal.ambientStrength;

        float aoFactor = material1.ambientOcclusionMap == -1 ? 1 :
            texture(textureArray, vec3(uv1, material1.ambientOcclusionMap)).r;
        if (!identicalMaterials) {
            aoFactor =
                IN.texBlend.x * aoFactor +
                IN.texBlend.y * (material2.ambientOcclusionMap == -1 ? 1 :
                    texture(textureArray, vec3(uv2, material2.ambientOcclusionMap)).r) +
                IN.texBlend.z * (material3.ambientOcclusionMap == -1 ? 1 :
                    texture(textureArray, vec3(uv3, material3.ambientOcclusionMap)).r);
        }
        ambientLightOut *= aoFactor;

        // directional light
        vec3 dirLightColor = uboGlobal.lightColor * uboGlobal.lightStrength;

        // underwater caustics based on directional light
        if (uboGlobal.underwaterCaustics && uboGlobal.underwaterEnvironment) {
            float scale = 12.8;
            vec2 causticsUv = worldUvs(scale);

            const ivec2 direction = ivec2(1, -1);
            const int driftSpeed = 231;
            vec2 drift = animationFrame(231) * ivec2(1, -2);
            vec2 flow1 = causticsUv + animationFrame(19) * direction + drift;
            vec2 flow2 = causticsUv * 1.25 + animationFrame(37) * -direction + drift;

            vec3 caustics = sampleCaustics(flow1, flow2) * 2;

            vec3 causticsColor = uboGlobal.underwaterCausticsColor * uboGlobal.underwaterCausticsStrength;
            dirLightColor += caustics * causticsColor * lightDotNormals * pow(uboGlobal.lightStrength, 1.5);
        }

        // apply shadows
        dirLightColor *= inverseShadow;

        vec3 lightColor = dirLightColor;
        vec3 lightOut = max(lightDotNormals, 0.0) * lightColor;

        // directional light specular
        vec3 lightReflectDir = reflect(-uboGlobal.lightDir, normals);
        vec3 lightSpecularOut = lightColor * specular(IN.texBlend, viewDir, lightReflectDir, vSpecularGloss, vSpecularStrength);

        // point lights
        vec3 pointLightsOut = vec3(0);
        vec3 pointLightsSpecularOut = vec3(0);
        float subsurface = material1.subsurface;
        calculateLighting(IN.position, normals, viewDir, IN.texBlend, vSpecularGloss, vSpecularStrength,
            subsurface, pointLightsOut, pointLightsSpecularOut);

        // sky light
        vec3 skyLightColor = uboGlobal.fogColor;
        float skyLightStrength = 0.5;
        float skyDotNormals = downDotNormals;
        vec3 skyLightOut = max(skyDotNormals, 0.0) * skyLightColor * skyLightStrength;


        // lightning
        vec3 lightningColor = vec3(.25, .25, .25);
        float lightningStrength = uboGlobal.lightningBrightness;
        float lightningDotNormals = downDotNormals;
        vec3 lightningOut = max(lightningDotNormals, 0.0) * lightningColor * lightningStrength;

        // Artistic thin-sheet transmission
        vec3 transmissionOut = vec3(0.0);
        if (subsurface > 0.0)
            transmissionOut = dirLightColor * thinSheetTransmission(
                dot(normals, uboGlobal.lightDir), dot(-uboGlobal.lightDir, viewDir), subsurface);

        // underglow
        vec3 underglowOut = uboGlobal.underglowColor * max(normals.y, 0) * uboGlobal.underglowStrength;


        // fresnel reflection
        float baseOpacity = 0.4;
        float fresnel = 1.0 - clamp(viewDotNormals, 0.0, 1.0);
        float finalFresnel = clamp(mix(baseOpacity, 1.0, fresnel * 1.2), 0.0, 1.0);
        vec3 surfaceColor = vec3(0);
        vec3 surfaceColorOut = surfaceColor * max(combinedSpecularStrength, 0.2);


        // apply lighting
        vec3 compositeLight = ambientLightOut + lightOut + lightSpecularOut + skyLightOut + lightningOut +
        underglowOut + pointLightsOut + pointLightsSpecularOut + surfaceColorOut + transmissionOut;

        #if DISPLAY_LIGHTING
            FragColor = vec4(compositeLight, 1.0);
            if (DISPLAY_LIGHTING == 1) // Redundant, for syntax highlighting in IntelliJ
                return;
        #endif

        float unlit = dot(IN.texBlend, vec3(
            getMaterialIsUnlit(material1),
            getMaterialIsUnlit(material2),
            getMaterialIsUnlit(material3)
        ));

        // Point-light-driven legacy tag. Metric is the fraction of total composite
        // light luminance contributed by point lights (diffuse + specular), passed
        // through a smoothstep so the transition between "sun-dominated" and
        // "point-light-dominated" is sharp instead of linear. Sample-derived cuts:
        // overworld with strong point light measures ratio ≈ 0.37 (want ~0), eclipse
        // moon attack ≈ 0.69 (want ~1). smoothstep(0.3, 0.7) hits both: 0.37 → 0.08,
        // 0.69 → 1.00.
        float pointLightLum = dot(pointLightsOut + pointLightsSpecularOut, REC709_LUMA);
        float compositeLightLum = dot(compositeLight, REC709_LUMA);
        float pointLightFraction = pointLightLum / max(compositeLightLum, 1e-5);
        pointLightTag = smoothstep(0.3, 0.7, pointLightFraction);

        #if VANILLA_COLOR_BANDING
            outputColor.rgb = linearToSrgb(outputColor.rgb);
            outputColor.rgb = srgbToHsv(outputColor.rgb);
            outputColor.b = floor(outputColor.b * 127) / 127;
            outputColor.rgb = hsvToSrgb(outputColor.rgb);
            outputColor.rgb = srgbToLinear(outputColor.rgb);
        #endif

        // Apply lighting to the albedo: outputColor (LINEAR) × compositeLight
        // (LINEAR) = lit_albedo (LINEAR, may be HDR > 1).
        outputColor.rgb *= mix(compositeLight, vec3(1), unlit);

        #if !LEGACY_RENDERER
            // Texture-blend the MATERIAL_FLAG_HAS_ATTACHED_LIGHT bit across the three
            // sampled materials. The bit's source is dual-purpose and split by isTerrain
            // at the tag-write site:
            //   - Objects (isTerrain=false): set by SceneUploader / ModelStreamingManager
            //     when the object/NPC/projectile/graphics-object ID is in lights.json,
            //     OR by ModelOverride.legacyHighlightClip. Gated by lightnessGate.
            //   - Tiles (isTerrain=true): set by SceneUploader when the tile's
            //     GroundMaterial has any member material flagged legacyHighlightClip
            //     (e.g. karamja/eclipse-moon lava ground). Full-strength.
            hasAttachedLightBlend = dot(IN.texBlend, vec3(
                (fMaterialData[0] >> MATERIAL_FLAG_HAS_ATTACHED_LIGHT & 1),
                (fMaterialData[1] >> MATERIAL_FLAG_HAS_ATTACHED_LIGHT & 1),
                (fMaterialData[2] >> MATERIAL_FLAG_HAS_ATTACHED_LIGHT & 1)
            ));
            // Per-material legacy-clip signal: materials.json `legacyHighlightClip: true`
            // packs MaterialStruct.flags bit 3, blended through IN.texBlend the same way
            // unlit and hasAttachedLight are. Full-strength (1.0) contribution to fragTag.
            legacyHighlightBlend = dot(IN.texBlend, vec3(
                getMaterialIsLegacyClip(material1),
                getMaterialIsLegacyClip(material2),
                getMaterialIsLegacyClip(material3)
            ));

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
    #endif // WATER_PASS
    // Beyond this point, outputColor.rgb is sRGB-encoded for terrain branches
    // and unicorn-hybrid for water (≈ sRGB-encoded magnitude). Either way, NOT
    // linear, and downstream code should treat it as display-space-ish.

    #if LEGACY_RENDERER
        vec2 tiledist = abs(floor(IN.position.xz / 128) - floor(uboGlobal.cameraPos.xz / 128));
        float maxDist = max(tiledist.x, tiledist.y);
        if (maxDist > uboGlobal.drawDistance) {
            // Rapidly fade out any geometry that extends beyond the draw distance.
            // This is required if we always draw all underwater terrain.
            outputColor.a *= -256;
        }
    #endif

    #if WIREFRAME
        outputColor.rgb *= wireframeMask();
    #endif

    // apply fog
    if (!isUnderwater) {
        // ground fog
        float distance = distance(IN.position, uboGlobal.cameraPos);
        float closeFadeDistance = 1500;
        float groundFog = 1.0 - clamp((IN.position.y - uboGlobal.groundFogStart) / (uboGlobal.groundFogEnd - uboGlobal.groundFogStart), 0.0, 1.0);
        groundFog = mix(0.0, uboGlobal.groundFogOpacity, groundFog);
        groundFog *= clamp(distance / closeFadeDistance, 0.0, 1.0);
        float nightFogBlend = 0.0;

        // Scale optical depth, with lighter haze at night. Apply before water coverage too.
        if (uboSky.enabled) {
            nightFogBlend = 1.0 - smoothstep(sin(radians(-6.0)), 0.0, uboSky.sunDir.y);
            groundFog = 1.0 - pow(1.0 - clamp(groundFog, 0.0, 1.0), mix(0.88, 0.352, nightFogBlend));
        }

        // multiply the visibility of each fog
        float fogAmount = calculateFogAmount(IN.position);
        float combinedFog = 1 - (1 - fogAmount) * (1 - groundFog);

        if (isWater) {
            outputColor.a = combinedFog + outputColor.a * (1 - combinedFog);
        }

        if (uboSky.enabled) {
            if (combinedFog > 1e-4) {
                vec3 fogViewDir = normalize(IN.position - uboGlobal.cameraPos);
                vec3 distanceFogColor = foggedSkyColor(fogViewDir);
                if (groundFog > 1e-4 && fogAmount < 1.0) {
                    // Approximate reduced nighttime color sensitivity without changing luminance.
                    vec3 nightFogColor = mix(uboSky.groundFogLight,
                        vec3(linearSrgbLuminance(uboSky.groundFogLight)), 0.5);
                    // Preserve the regular fog color by day; introduce adapted local
                    // illumination only through civil dusk, from sun altitude 0 to -6 degrees.
                    vec3 groundFogColor = mix(distanceFogColor, nightFogColor, nightFogBlend);
                    outputColor.rgb = linearToSrgb(mix(srgbToLinear(outputColor.rgb), groundFogColor, groundFog));
                }
                // Preserve the scene's existing distance-fog composition. It hides
                // the local haze at the far boundary, matching the sky behind it.
                if (fogAmount > 1e-4)
                    outputColor.rgb = mix(outputColor.rgb, linearToSrgb(distanceFogColor), fogAmount);
            }
        } else {
            outputColor.rgb = mix(outputColor.rgb, linearToSrgb(uboGlobal.fogColor), combinedFog);
        }
    }

    #if LEGACY_RENDERER
        // Zone renderer applies color adjustments and output correction in tonemap_frag
        outputColor.rgb = applyColorAdjustments(outputColor.rgb);
        outputColor.rgb = applyOutputCorrection(outputColor.rgb);
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
    FragColor = outputColor;
    #if !LEGACY_RENDERER
        // Tag mask, written to a second R8 attachment that gets alpha-blended through
        // the scene pass the same way FragColor is. Declared vec4 for driver
        // compatibility — single-float outputs to R8 attachments were silently
        // dropped on at least one Nvidia driver build.
        //
        // Bit 21 (MATERIAL_FLAG_HAS_ATTACHED_LIGHT) has context-sensitive semantics
        // based on isTerrain:
        //   - On objects (isTerrain=false): "this object is tagged for subtle glow
        //     compensation" (set by lights.json auto-tag or
        //     ModelOverride.legacyHighlightClip). Gated by lightnessGate so
        //     invisible-but-tagged transparent draws don't accumulate.
        //   - On tiles (isTerrain=true): "this tile's groundMaterial is explicitly
        //     tagged for legacy clip" (set by uploadTilePaint/Model when
        //     groundMaterial.legacyHighlightClip is true). Promoted to the
        //     full-strength legacyHighlightBlend path, matching how per-material
        //     bit 3 already works for tiles that happen to get a flagged Material
        //     assigned (e.g. karamja's vanilla-LAVA-texture path).
        //
        // outputColor.r here is OKLab L (lightness); see the FBO-convention block
        // above. Both the attached-light and point-light paths use it as a
        // brightness gate so dim fragments don't get pushed toward the legacy
        // hard-clip target, which is strictly darker than AgX below the per-channel
        // clamp threshold (an invisible-but-tagged transparent draw would otherwise
        // still contribute its alpha-weighted fraction).
        float tileFullStrength = isTerrain ? hasAttachedLightBlend : 0.0;
        float objectAttached = isTerrain ? 0.0 : hasAttachedLightBlend;
        float lightnessGate = clamp(outputColor.r, 0.0, 1.0);
        float attached = objectAttached * lightnessGate;
        float pointGated = pointLightTag * lightnessGate;
        float tagContribution = max(
            attached,
            max(legacyHighlightBlend, max(tileFullStrength, pointGated))
        );
        // src.a = outputColor.a so the scene-pass alpha blend weights the tag by
        // how much of the pixel this fragment is actually contributing. Putting
        // tagContribution in src.a (e.g. vec4(tagContribution) for both .r and .a)
        // makes the blend tag² + dst×(1−tag), and an opaque untagged fragment
        // (tag=0, outputColor.a=1) would leave the destination unchanged instead
        // of clearing a previously-written tag at that pixel.
        fragTag = vec4(tagContribution, 0.0, 0.0, outputColor.a);
    #endif
}
