#pragma once

#define EPS 1.0e-10
#define PI 3.14159265f // max 32-bit float precision
#define HALF_PI (.5*PI)
#define TAU (2*PI)

#define SHORT_MAX 32767 // 2^15 - 1

#include SHADER_TYPE
#include LEGACY_RENDERER
#include ZONE_RENDERER

// Any changes here may need to be reflected in OpenCL's constants.cl
// They are kept separate to avoid accidentally breaking OpenCL compatibility
#define MATERIAL_INDEX_SHIFT 21
#define MATERIAL_INDEX_MASK ((1 << (32 - MATERIAL_INDEX_SHIFT)) - 1)
#define MATERIAL_SHADOW_OPACITY_THRESHOLD_SHIFT 15
#define MATERIAL_FLAG_WIND_MODIFIER 12
#define MATERIAL_FLAG_WIND_SWAYING 9
#define MATERIAL_FLAG_INVERT_DISPLACEMENT_STRENGTH 8
// Bit 7 was previously reserved as MATERIAL_FLAG_UNDO_VANILLA_SHADING but was
// never actually read by any shader (undo-vanilla-shading is performed CPU-side
// in SceneUploader on the colors directly). Repurposed for auto-tagging objects
// that have an attached light in lights.json, which drives AgX surface vibrance.
#define MATERIAL_FLAG_HAS_ATTACHED_LIGHT 7
#define MATERIAL_FLAG_TERRAIN_VERTEX_SNAPPING 6
#define MATERIAL_FLAG_DISABLE_SHADOW_RECEIVING 5
#define MATERIAL_FLAG_UPWARDS_NORMALS 4
#define MATERIAL_FLAG_FLAT_NORMALS 3
#define MATERIAL_FLAG_WORLD_UVS 2
#define MATERIAL_FLAG_VANILLA_UVS 1
#define MATERIAL_FLAG_IS_OVERLAY 0

#include SHADOW_MODE
#define SHADOW_MODE_OFF 0
#define SHADOW_MODE_FAST 1
#define SHADOW_MODE_DETAILED 2

#define SHADOW_TRANSPARENCY_BIAS 0.006
#define SHADOW_DEPTH_BITS 16
#define SHADOW_ALPHA_BITS 8
#define SHADOW_COMBINED_BITS (SHADOW_DEPTH_BITS + SHADOW_ALPHA_BITS)
#define SHADOW_DEPTH_MAX ((1 << SHADOW_DEPTH_BITS) - 1)
#define SHADOW_ALPHA_MAX ((1 << SHADOW_ALPHA_BITS) - 1)
#define SHADOW_COMBINED_MAX ((1 << SHADOW_COMBINED_BITS) - 1)

#include SHADOW_RESOLUTION

#include SHADOW_FILTERING
#define SHADOW_FILTERING_PCF 0
#define SHADOW_FILTERING_DITHER 1
#define SHADOW_FILTERING_AVERAGE 2
#define SHADOW_FILTERING_JITTERED_PCF 3

#include SHADOW_TRANSPARENCY
#if SHADOW_TRANSPARENCY
    #define SHADOW_DEFAULT_OPACITY_THRESHOLD 0.01 // Remove shadows from clickboxes
#else
    #define SHADOW_DEFAULT_OPACITY_THRESHOLD 0.71 // Lowest while keeping Prifddinas glass walkways transparent
#endif

#include VANILLA_COLOR_BANDING
#include UNDO_VANILLA_SHADING
#include LEGACY_GREY_COLORS
#include DISABLE_DIRECTIONAL_SHADING
#include FLAT_SHADING
#include APPLY_COLOR_FILTER
#include WIREFRAME
#include WIND_DISPLACEMENT
#include WIND_DISPLACEMENT_NOISE_RESOLUTION
#include CHARACTER_DISPLACEMENT
#include DYNAMIC_LIGHTS
#include MAX_LIGHT_COUNT
#include TILED_LIGHTING
#include TILED_LIGHTING_LAYER_COUNT
#include TILED_LIGHTING_TILE_SIZE
#define TILED_LIGHTING_MAX_TILE_LIGHT_COUNT (TILED_LIGHTING_LAYER_COUNT * 4 * 2)
#include WINDOWS_HDR_CORRECTION
