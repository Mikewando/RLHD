# Per-Environment AgX Legacy-Highlight Mix

**Date:** 2026-06-24
**Status:** Design approved, awaiting implementation plan
**Branch:** `feature/agx-tag-mrt`

## Problem

AgX's highlight rolloff desaturates bright colors toward white in a way that suits
photorealistic daylit scenes but breaks stylized areas like TZHAAR, where lava,
fire, and saturated walls/floors are expected to read as flat-saturated clipped-sRGB
(the way the legacy renderer presents them). The existing per-fragment tag-mask
compensation (`MATERIAL_FLAG_HAS_ATTACHED_LIGHT`) catches specific lights-attached
objects, but not the bulk of TZHAAR — tile-based lava, untagged walls, and other
scenery still go through AgX's desaturating rolloff.

Constraints from the user:

- Don't ditch AgX globally; the exposure / EV-range / overall character is correct
  for most scenes.
- Don't introduce a parallel pipeline (duplicate settings would be a maintenance
  burden).
- Per-zone activation, starting with TZHAAR. Other zones can opt in later.

## Approach

Re-use the validated literal-legacy-target mix from the existing tag-mask path
(`mix(agxOut, clamp(linear, 0, 1), strength)`), but drive it from a per-environment
uniform that's authored in `environments.json` and plumbed through
`EnvironmentManager`'s existing transition machinery.

The two strength sources — per-fragment tag (existing) and per-environment baseline
(new) — combine additively (clamped to 1.0) for v1. If the additive stacking
compounds too aggressively in TZHAAR (e.g. tagged glowy objects becoming
"double-legacy" and over-clipping), splitting into separate `mix` calls is a
trivial follow-up.

## Design

### Shader change — `src/main/resources/rs117/hd/post/tonemap_frag.glsl`

Replace the existing tag-mask block (lines 45–49):

```glsl
float tag = texture(tagTex, fUv).r;
if (tag > 0.0 && agxSurfaceVibrance > 0.0) {
    vec3 legacyTarget = clamp(linear, 0.0, 1.0);
    agxOut = mix(agxOut, legacyTarget, min(tag * agxSurfaceVibrance, 1.0));
}
```

with a unified version that combines both strengths:

```glsl
float tag = texture(tagTex, fUv).r;
float effective = min(agxLegacyMix + tag * agxSurfaceVibrance, 1.0);
if (effective > 0.0) {
    vec3 legacyTarget = clamp(linear, 0.0, 1.0);
    agxOut = mix(agxOut, legacyTarget, effective);
}
```

Existing debug probe writes (slots 21/22 "post-compensation linear" and "post-
compensation display sRGB") remain valid — they capture `agxOut` after the mix,
which is still the value displayed. The `debugTagMask` overlay continues to show
the raw R8 tag value only; the per-environment strength is not visualized (it's
uniform and easily observed via slider tuning).

### Shader uniform — `src/main/resources/rs117/hd/uniforms/global.glsl`

Add to the same uniform block that holds `agxSurfaceVibrance`, `exposure`,
`agxMinEv`, `agxMaxEv`:

```glsl
uniform float agxLegacyMix;
```

### Environment schema — `src/main/java/rs117/hd/scene/environments/Environment.java`

Add one field with default `0` (existing behavior preserved):

```java
public float legacyHighlightMix = 0;
```

`0` means pure AgX; `1` means pure clipped-legacy target (for in-range values, this
is byte-for-byte legacy clip+sRGB). Values in between linearly mix the two.

### Transition plumbing — `src/main/java/rs117/hd/scene/EnvironmentManager.java`

Add three fields alongside the existing transition state (mirrors the pattern used
for `currentAmbientStrength`, `currentFogDepth`, etc.):

```java
private float startLegacyHighlightMix = 0;
public  float currentLegacyHighlightMix = 0;
private float targetLegacyHighlightMix = 0;
```

Update them in the same snapshot/transition-update code paths that handle the other
scalar environment parameters. 3-second cross-fade on area boundary; instant snap
on `SKIP_TRANSITION_DISTANCE` jumps. No new transition machinery — just a fourth
scalar joining the existing group.

(Note: in practice TZHAAR is always entered via teleport or instance/loading-line
crossing, which exceeds `SKIP_TRANSITION_DISTANCE` and triggers an instant snap.
The smooth transition path is supported by reusing existing machinery but won't
be observed for TZHAAR specifically.)

### UBO upload — `src/main/java/rs117/hd/opengl/uniforms/UBOGlobal.java` + `src/main/java/rs117/hd/renderer/zone/ZoneRenderer.java`

In `UBOGlobal.java`, add a new property alongside `agxSurfaceVibrance`:

```java
public Property agxLegacyMix = addProperty(PropertyType.Float, "agxLegacyMix");
```

In `ZoneRenderer.scenePass()`, upload it each frame in the same block that already
uploads `currentFogColor`, `currentAmbientColor`, etc.:

```java
plugin.uboGlobal.agxLegacyMix.set(environmentManager.currentLegacyHighlightMix);
```

### Naming bridge

Intentional naming split:

| Layer | Name | Rationale |
|---|---|---|
| `Environment.java` field + `environments.json` key | `legacyHighlightMix` | Author-facing: describes the effect (clip highlights toward legacy). |
| `EnvironmentManager.java` transition fields | `startLegacyHighlightMix` / `currentLegacyHighlightMix` / `targetLegacyHighlightMix` | Matches the source field. |
| `UBOGlobal.java` property + GLSL uniform | `agxLegacyMix` | Matches the surrounding `agx*` naming convention used by `agxSurfaceVibrance`, `agxPunchPower`, etc. |

The bridge happens at the single UBO upload line in `ZoneRenderer.scenePass()`.

### Environment opt-in — `src/main/resources/rs117/hd/scene/environments.json`

Add one line to the TZHAAR entry (currently at line 262):

```json
{
  "area": "TZHAAR",
  ...
  "legacyHighlightMix": 1.0
}
```

Starting at `1.0` for maximum effect; can be dialed live via FileWatcher hot-reload
once visual results are evaluated.

## What's not changing

- `agxSurfaceVibrance` config slider keeps its current meaning and default (drives
  only the per-fragment tag-mask path).
- `MATERIAL_FLAG_HAS_ATTACHED_LIGHT` tagging in `SceneUploader.uploadStaticModel`
  and `ModelStreamingManager.drawTemp` is untouched.
- R8 tag attachment, MRT setup, scene_frag pre-clip for tagged HDR fragments — all
  untouched.
- AgX exposure / `agxMinEv` / `agxMaxEv` / `agxPunchSaturation` / `agxPunchPower`
  are unchanged.
- The sky inverse-AgX (`ColorUtils.agxInverseToHdrInput` called from
  `ZoneRenderer.scenePass`) is unchanged. Fog colors are authored in display sRGB,
  the inverse maps them to HDR values typically < 1.0, and `clamp(linear, 0, 1)`
  is identity for in-range values — so the new mix is a no-op on sky pixels.
- Legacy renderer is unaffected; `tonemap_frag.glsl` is zone-only.
- No config slider, no plugin-config field. Author-controlled via JSON only.

## Verification

1. **Build & launch.** `./gradlew build` succeeds; plugin loads in RuneLite.
2. **TZHAAR appearance.** Walk into TZHAAR (region 9551, 9552, or any region inside
   the box `9807-10064` — confirmed via Ctrl+F3 Tile Info overlay showing
   `Environment: TZHAAR`). Lava, walls, and bright surfaces should snap to legacy-
   like hard-clipped appearance (per the saved `legacy lava.png` reference).
3. **Boundary exit.** Walk out / teleport away. AgX behavior resumes. (Transition
   is expected to snap instantly via `SKIP_TRANSITION_DISTANCE`; not a test
   priority.)
4. **Hot-reload.** Edit TZHAAR's `legacyHighlightMix` in `environments.json` to
   `0.5`, save. Change applies live without restart.
5. **Daylit overworld regression.** Spawn in Lumbridge or another daylit area. No
   visual change (no environment opts in; uniform stays at 0).
6. **Tag-mask still works elsewhere.** Visit GOTR (rewards guardian / barrier).
   Surface vibrance via the existing tag mask continues to apply (the new uniform
   adds 0 outside TZHAAR).
7. **Legacy renderer toggle.** Switch to legacy renderer. No visible change anywhere
   (tonemap_frag not used).

## Follow-ups (out of scope for this change)

- **Other lava-heavy zones.** Mount Karuulm, Cerberus lair, Wilderness lava
  — each gets its own `legacyHighlightMix` opt-in once a TZHAAR value is settled.
- **Re-evaluate stacking.** If results show additive (tag + env) over-clips tagged
  fragments in TZHAAR, split into two separate `mix` calls (env first, then tag) or
  switch to `max(envMix, tag * agxSurfaceVibrance)`.
- **Generalize to other AgX overrides per Environment.** If a zone wants different
  exposure / EV range / punch parameters, the same plumbing pattern extends —
  but not yet authored as a goal.
