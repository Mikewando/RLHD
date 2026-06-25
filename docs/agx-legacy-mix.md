# AgX tonemap with selective legacy-clip mix

The zone renderer tonemaps with [AgX](https://github.com/sobotka/AgX) for a
photographic look, then blends per-fragment toward the legacy renderer's
`clamp + sRGB` curve on selected surfaces and environments to preserve OSRS's
saturated stylised hues where AgX would otherwise desaturate them (lava, fire,
GOTR portals/barriers, magical glows, etc.).

The legacy mix is driven by four independent inputs that all converge on a
single per-pixel "tag" value in `[0, 1]`:

1. **`agxLegacyMix`** — per-environment scalar from `environments.json`.
2. **Per-material `legacyHighlightClip`** — `materials.json` flag.
3. **`MATERIAL_FLAG_HAS_ATTACHED_LIGHT`** (bit 7) — dual-purpose; semantics depend on whether the fragment is a tile or an object (see below).
4. **Per-fragment point-light fraction** — computed in scene_frag from `pointLightsOut / compositeLight` luminance ratio.

All four are combined and applied at tonemap time as `mix(agxOut, legacyTarget, effective)`.

---

## The legacy-clip target

`tonemap_frag.glsl` builds the target by applying AgX's brightness response to
luminance only, then scaling the per-channel linear value by that response and
hard-clipping to `[0, 1]`:

```glsl
float lum = dot(linear, REC709_LUMA);
float lumNorm = clamp((log2(max(lum, 1e-10)) - agxMinEv) / (agxMaxEv - agxMinEv), 0.0, 1.0);
float lumOut = clamp(agxDefaultContrastApprox(vec3(lumNorm)).x, 0.0, 1.0);
vec3 legacyTarget = clamp(linear * (lumOut / max(lum, 1e-10)), 0.0, 1.0);
agxOut = mix(agxOut, legacyTarget, effective);
```

Why this construction:

- A naive `clamp(linear, 0, 1) + linearToSrgb` reference works for hot HDR
  scenes (where R or G saturates and the channel ratio survives the clamp),
  but most game HDR values sit well below `2^agxMaxEv`. A pure per-channel
  sigmoid never actually clips those midtones, and channel ratios would
  survive into the output — washing out the "fire's high-R / mid-G clips to
  yellow" hue collapse that's the whole reason to fall back to legacy.
- Applying AgX's log + EV normalise + sigmoid to **luminance** keeps exposure
  feeling like the AgX path while preserving the per-channel hard clamp that
  produces the saturated legacy hue.

The total blend strength is `effective = min(agxLegacyMix + tag, 1.0)`, where
`tag` is the per-fragment R8 attachment value built in `scene_frag`.

---

## Per-environment `agxLegacyMix`

`environments.json` accepts a `legacyHighlightMix` float in `[0, 1]` that
`EnvironmentManager` interpolates into the active environment. Currently only
the `TZHAAR` area sets `legacyHighlightMix: 1.0` (THE_INFERNO inherits via
area resolution); the whole zone benefits from legacy's saturated fire palette.
Hot-reloads when environments.json changes.

---

## Per-material `legacyHighlightClip` (full-strength)

`materials.json`:

```json
{ "name": "LAVA", "legacyHighlightClip": true, ... }
```

`Material.legacyHighlightClip` packs into `MaterialStruct.flags` bit 3 and is
read in `scene_frag` via `getMaterialIsLegacyClip(material)`. The three
sampled materials at the fragment are blended through `IN.texBlend`:

```glsl
legacyHighlightBlend = dot(IN.texBlend, vec3(
    getMaterialIsLegacyClip(material1),
    getMaterialIsLegacyClip(material2),
    getMaterialIsLegacyClip(material3)
));
```

The result contributes to the tag at full strength (no brightness gate, no
vibrance scale). Intended for materials that should *always* render with the
legacy clip wherever they appear (canonical example: lava textures).

---

## Per-`ModelOverride` `legacyHighlightClip`

`model_overrides.json`:

```json
{
  "description": "Perilous Moons - Lava Rocks",
  "baseMaterial": "ROCK_3",
  "legacyHighlightClip": true,
  "objectIds": [ "ROCK_LAVA01_LARGE01", ... ]
}
```

Authors override-level legacy-clip for objects whose materials don't merit the
material-level flag globally. The flag flows through `SceneUploader` as
`MATERIAL_FLAG_HAS_ATTACHED_LIGHT` (bit 7), which is the next mechanism.

---

## `MATERIAL_FLAG_HAS_ATTACHED_LIGHT` (bit 7) — dual semantics

Bit 7 of `fMaterialData` is OR-ed in by the uploader from two sources:

1. **Auto-tagging from `lights.json`.** `LightManager.hasAttachedLight(uuid)`
   reports whether an object/NPC/projectile/graphics-object UUID has any
   light attached. `SceneUploader.uploadStaticModel` and
   `ModelStreamingManager.drawTemp` check this and OR the bit into the
   packed material data. Zero authoring required for the catalogued list
   in `lights.json`.

2. **Tile uploads from `GroundMaterial.legacyHighlightClip`.**
   `GroundMaterial.normalize` derives a per-ground-material flag that is
   true if *any* member `Material` has `legacyHighlightClip = true`. When
   `SceneUploader.uploadTilePaint` / `uploadTileModel` sees a flagged ground
   material, it OR-s bit 7 into the tile's material data regardless of the
   user's `Ground Textures` setting (which gates the actual material
   assignment but not the tag).

3. **`ModelOverride.legacyHighlightClip`.** Author flag in `model_overrides.json`
   above also sets bit 7 in `SceneUploader.uploadStaticModel`.

`scene_frag` blends the bit across the three materials via `IN.texBlend`:

```glsl
hasAttachedLightBlend = dot(IN.texBlend, vec3(
    (fMaterialData[0] >> MATERIAL_FLAG_HAS_ATTACHED_LIGHT & 1),
    (fMaterialData[1] >> MATERIAL_FLAG_HAS_ATTACHED_LIGHT & 1),
    (fMaterialData[2] >> MATERIAL_FLAG_HAS_ATTACHED_LIGHT & 1)
));
```

At tag-write time the meaning splits by `isTerrain` (from `fTerrainData[0] & 1`):

- **Objects** (`isTerrain == false`): gated by `lightnessGate` so dim /
  invisible-but-tagged transparent draws don't accumulate tag against
  background pixels the user perceives as untagged.
- **Tiles** (`isTerrain == true`): promoted to the full-strength
  `legacyHighlightBlend` path. Same treatment as if the per-material bit 3
  were set, matching the karamja vanilla-LAVA-texture path.

---

## Point-light driven tag

For colour-glow surfaces that aren't authored as `legacyHighlightClip`, AgX
desaturates strong coloured point lights (e.g. eclipse moon attacks, lava
casting orange light onto rocks). A per-fragment metric drives the tag from
the fraction of composite-light luminance contributed by point lights:

```glsl
float pointLightLum = dot(pointLightsOut + pointLightsSpecularOut, REC709_LUMA);
float compositeLightLum = dot(compositeLight, REC709_LUMA);
float pointLightFraction = pointLightLum / max(compositeLightLum, 1e-5);
pointLightTag = smoothstep(0.3, 0.7, pointLightFraction);
```

The `smoothstep(0.3, 0.7, ...)` curve was chosen from probe data:

| scene                          | `pointLightFraction` | tag  |
|--------------------------------|----------------------|------|
| Daylit overworld (no points)   | 0.00                 | 0.00 |
| Overworld + strong point light | 0.37                 | 0.08 |
| Eclipse Moon attack glow       | 0.69                 | 1.00 |
| Pure point-lit dark room       | 1.00                 | 1.00 |

The smoothstep gives a sharp transition between "sun-dominated" and
"point-light-dominated" lighting rather than a linear mix that over-tags the
overworld case.

---

## Tag write-out and brightness gate

All four sources combine at the end of `scene_frag.glsl`:

```glsl
float tileFullStrength = isTerrain ? hasAttachedLightBlend : 0.0;
float objectAttached   = isTerrain ? 0.0 : hasAttachedLightBlend;
float lightnessGate    = clamp(outputColor.r, 0.0, 1.0);
float attached         = objectAttached * lightnessGate;
float pointGated       = pointLightTag * lightnessGate;
float tagContribution  = max(attached, max(legacyHighlightBlend, max(tileFullStrength, pointGated)));
fragTag = vec4(tagContribution, 0.0, 0.0, outputColor.a);
```

The brightness gate (`outputColor.r`, which at this point is OKLab L because
the FBO write was preceded by `linearToOklab`) suppresses tag from dim
fragments. Below the per-channel clamp threshold, the legacy target is
strictly darker than AgX (it has no sigmoid lift in the toe), so mixing toward
it on a dim fragment just darkens the pixel without any saturation benefit.
The gate avoids that.

The tag attachment is a **second R8 colour attachment** (`fragTag`) on the
scene FBO. The scene-pass alpha blend (`glBlendFuncSeparate(GL_SRC_ALPHA,
GL_ONE_MINUS_SRC_ALPHA, GL_ZERO, GL_ONE)`) applies to both colour
attachments. Writing `outputColor.a` into `fragTag.a` makes the blend weight
the tag by how much of the pixel this fragment is contributing — an opaque
untagged fragment correctly clears any tag at that pixel, and a transparent
tagged fragment correctly accumulates partially. `tonemap_frag` samples the
resolved R8 (`tagTex.r`) and uses it as the per-fragment legacy-mix strength.

---

## Config sliders

All under the existing tonemap section:

| key                  | range        | default | role                                                  |
|----------------------|--------------|---------|-------------------------------------------------------|
| `tonemapExposure`    | 5–200%       | 45%     | Pre-AgX linear exposure multiplier.                   |
| `agxMinEv`           | -20 to 0     | -10     | Lower bound of AgX log2 EV range.                     |
| `agxMaxEv`           | 0 to 10      | 4       | Upper bound of AgX log2 EV range.                     |
| `agxPunchSaturation` | 0–200%       | 105%    | AgX look saturation multiplier (1.0 = no-op).         |
| `agxPunchPower`      | 50–200%      | 108%    | AgX look per-channel power curve (1.0 = no-op).       |

All upload from `ZoneRenderer.uploadFrameUniforms` into `UBOGlobal` and
hot-reload on config change without a scene reload.

---

## Scene reload behaviour

- Material flag (bit 3): baked into vertex data at upload. Scene reload required.
- Override flag (bit 7): same — vertex data. Scene reload required.
- Auto-tag from `lights.json` (bit 7): same — vertex data. `LightManager.loadConfig`
  triggers a scene reload on `lights.json` edit, so the existing path handles it.
- `agxLegacyMix` (per-environment): uniform; no reload required.
- AgX-look sliders (`agxPunchSaturation`, `agxPunchPower`): uniform; no
  reload required.

---

## Files

| file                                                              | purpose                                                             |
|-------------------------------------------------------------------|---------------------------------------------------------------------|
| `src/main/resources/rs117/hd/utils/tonemap.glsl`                  | AgX matrix + sigmoid + punchy helpers.                              |
| `src/main/resources/rs117/hd/post/tonemap_frag.glsl`              | Post-process pass: AgX + tag-driven legacy-mix.                     |
| `src/main/resources/rs117/hd/post/tonemap_vert.glsl`              | Fullscreen quad vertex shader.                                      |
| `src/main/resources/rs117/hd/scene_frag.glsl`                     | Per-fragment tag computation; writes `fragTag` R8 attachment.       |
| `src/main/resources/rs117/hd/utils/color_utils.glsl`              | AgX-related GLSL color helpers.                                     |
| `src/main/resources/rs117/hd/uniforms/materials.glsl`             | `getMaterialIsLegacyClip` helper for the MaterialStruct.flags bit 3. |
| `src/main/resources/rs117/hd/utils/constants.glsl`                | `MATERIAL_FLAG_HAS_ATTACHED_LIGHT` bit 7 constant.                   |
| `src/main/java/rs117/hd/utils/ColorUtils.java`                    | CPU-side AgX (used for sky clear-colour inverse-AgX).               |
| `src/main/java/rs117/hd/opengl/shader/TonemapShaderProgram.java`  | Tonemap shader program.                                             |
| `src/main/java/rs117/hd/scene/EnvironmentManager.java`            | `currentLegacyHighlightMix` interpolation.                          |
| `src/main/java/rs117/hd/scene/materials/Material.java`            | `legacyHighlightClip` field + bit 3 packing.                        |
| `src/main/java/rs117/hd/scene/model_overrides/ModelOverride.java` | `legacyHighlightClip` field.                                        |
| `src/main/java/rs117/hd/scene/ground_materials/GroundMaterial.java` | Derived `legacyHighlightClip` flag.                               |
| `src/main/java/rs117/hd/scene/LightManager.java`                  | `hasAttachedLight(uuid)` query for auto-tagging.                    |
| `src/main/java/rs117/hd/renderer/zone/SceneUploader.java`         | OR-s bit 7 into material data from all three sources.               |
| `src/main/java/rs117/hd/renderer/zone/ModelStreamingManager.java` | Same, for dynamic actors/effects.                                   |
