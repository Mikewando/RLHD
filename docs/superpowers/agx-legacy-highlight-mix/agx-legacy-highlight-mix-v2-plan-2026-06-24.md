# Per-Material + Per-Override Legacy-Highlight Tagging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the just-shipped per-environment `agxLegacyMix` so that **specific materials** (lava, fire cape, infernal cape) and **specific model overrides** (lava bubbles) get the legacy-clip treatment in **any** environment, while leaving surrounding scenery on AgX.

**Architecture:** Two new sources flow into the existing R8 `fragTag` attachment that tonemap_frag already consumes:
1. **Per-material flag** (`legacyHighlightClip: true` in `materials.json`) is packed into the `MaterialStruct.flags` int (currently has 3 bits, gaining a 4th at position 3). scene_frag reads it via a `getMaterialIsLegacyClip` helper and writes a full-strength (1.0) contribution to `fragTag`.
2. **Per-override flag** (`legacyHighlightClip: true` in `model_overrides.json`) is OR'd into the existing `MATERIAL_FLAG_HAS_ATTACHED_LIGHT` bit at upload time in `SceneUploader`. This reuses the existing per-face bit (no new bit allocation needed) and the existing attached-light path — fragments get vibrance-scaled mix.

The two contributions max-combine inside scene_frag (full-strength wins when both fire). Tonemap_frag's `effective = min(envMix + tag * agxSurfaceVibrance, 1.0)` becomes `effective = min(envMix + tag, 1.0)` because vibrance is now applied at write time on the attached-light path; the material-flag path is already full-strength.

**Tech Stack:** Java 11, GLSL 330, LWJGL, std140 UBO layout. No new uniforms, no new MRT attachments, no new bit allocations in the per-face `materialData` int.

---

### Task 1: Add `MaterialStruct.flags` bit 3 for legacy-clip, add shader getter

**Files:**
- Modify: `src/main/resources/rs117/hd/uniforms/materials.glsl` (extend the comment on `flags` and add a new helper)

- [ ] **Step 1: Update the `flags` field comment and add the getter**

Edit `src/main/resources/rs117/hd/uniforms/materials.glsl`. The current `flags` comment reads:

```glsl
    int flags; // overrideBaseColor << 2 | unlit << 1 | hasTransparency
```

Replace with:

```glsl
    int flags; // legacyHighlightClip << 3 | overrideBaseColor << 2 | unlit << 1 | hasTransparency
```

Then immediately below the existing `getMaterialHasTransparency` helper at the end of the file, add a new helper:

```glsl
int getMaterialIsLegacyClip(const Material material) {
    return material.flags >> 3 & 1;
}
```

Match the file's existing 4-space indentation.

- [ ] **Step 2: Verify build**

Run: `./gradlew compileJava`
Expected: BUILD SUCCESSFUL. (Shader compilation happens at runtime; mechanical changes here are unlikely to syntax-error.)

- [ ] **Step 3: Commit**

```bash
git add src/main/resources/rs117/hd/uniforms/materials.glsl
git commit -m "Add MaterialStruct.flags bit 3 + getMaterialIsLegacyClip"
```

---

### Task 2: Add `legacyHighlightClip` field to `Material.java`, pack into struct

**Files:**
- Modify: `src/main/java/rs117/hd/scene/materials/Material.java`
  - New field (around line 60, alongside other booleans like `unlit`, `overrideBaseColor`)
  - Pack bit 3 of `struct.flags` in `fillMaterialStruct` (around line 217)

- [ ] **Step 1: Add the field**

Edit `src/main/java/rs117/hd/scene/materials/Material.java`. The existing booleans cluster on lines 57–59:

```java
	public boolean hasTransparency;
	private boolean overrideBaseColor;
	private boolean unlit;
```

Add a new line immediately after `unlit`:

```java
	private boolean legacyHighlightClip;
```

(Tab indentation matching the file.)

- [ ] **Step 2: Pack bit 3 in `fillMaterialStruct`**

In the same file, the existing flags packing reads (around lines 217–221):

```java
		struct.flags.set(
			(overrideBaseColor ? 1 : 0) << 2 |
			(unlit ? 1 : 0) << 1 |
			(hasTransparency ? 1 : 0)
		);
```

Replace with:

```java
		struct.flags.set(
			(legacyHighlightClip ? 1 : 0) << 3 |
			(overrideBaseColor ? 1 : 0) << 2 |
			(unlit ? 1 : 0) << 1 |
			(hasTransparency ? 1 : 0)
		);
```

- [ ] **Step 3: Verify build**

Run: `./gradlew compileJava`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add src/main/java/rs117/hd/scene/materials/Material.java
git commit -m "Material.legacyHighlightClip packs into struct.flags bit 3"
```

---

### Task 3: Add `legacyHighlightClip` field to `ModelOverride.java`

**Files:**
- Modify: `src/main/java/rs117/hd/scene/model_overrides/ModelOverride.java` (add field around line 80, alongside other booleans like `upwardsNormals`, `terrainVertexSnap`)

- [ ] **Step 1: Add the field**

Edit `src/main/java/rs117/hd/scene/model_overrides/ModelOverride.java`. The existing booleans are on lines 66–80 (cluster of `hide`, `disableDetailCulling`, `retainVanillaUvs`, etc.). The boolean cluster currently ends around line 80:

```java
	public boolean undoVanillaShading = true;
	private boolean hideAsWaterEffect = false;
	public float terrainVertexSnapThreshold = 0.125f;
```

Add a new field immediately before `hideAsWaterEffect`:

```java
	public boolean legacyHighlightClip = false;
```

(Tab indentation.)

- [ ] **Step 2: Verify build**

Run: `./gradlew compileJava`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
git add src/main/java/rs117/hd/scene/model_overrides/ModelOverride.java
git commit -m "ModelOverride.legacyHighlightClip field (default false)"
```

---

### Task 4: OR override flag into `MATERIAL_FLAG_HAS_ATTACHED_LIGHT` in upload paths

**Files:**
- Modify: `src/main/java/rs117/hd/renderer/zone/SceneUploader.java`
  - `uploadStaticModel` around line 1419
  - `drawTemp` (streamed) around line 2040
- Modify: `src/main/java/rs117/hd/renderer/zone/ModelStreamingManager.java` (if a third instance of this query exists there; verify in Step 1)

- [ ] **Step 1: Locate all `lightManager.hasAttachedLight` upload sites**

Run: `grep -rn "lightManager.hasAttachedLight" src/main/java/rs117/hd/renderer/zone/`
Expected: two hits in `SceneUploader.java` (around lines 1419 and 2040). If a third exists in `ModelStreamingManager.java`, include it in the edits below.

- [ ] **Step 2: Update the static-model query**

Edit `src/main/java/rs117/hd/renderer/zone/SceneUploader.java`. The block around line 1416–1420 reads:

```java
		// Auto-tag fragments for AgX surface vibrance compensation if the object
		// has an attached light in lights.json. Computed once per model — the bit
		// is then OR'd into each face's materialData below.
		final int materialDataExtraBits = lightManager.hasAttachedLight(uuid)
			? Material.MATERIAL_FLAG_HAS_ATTACHED_LIGHT : 0;
```

Replace with:

```java
		// Auto-tag fragments for AgX surface vibrance compensation if the object
		// has an attached light in lights.json, OR if the resolved ModelOverride
		// has legacyHighlightClip=true (for objects like LAVABUBBLES that aren't
		// rendered with a flagged material). Computed once per model — the bit is
		// then OR'd into each face's materialData below.
		final int materialDataExtraBits =
			(lightManager.hasAttachedLight(uuid) || modelOverride.legacyHighlightClip)
				? Material.MATERIAL_FLAG_HAS_ATTACHED_LIGHT : 0;
```

- [ ] **Step 3: Update the streamed-model query**

In the same file, the block around line 2037–2041 reads:

```java
		// Auto-tag fragments for AgX surface vibrance compensation if the
		// renderable has an attached light in lights.json. Mirrors the same
		// query used in uploadStaticModel.
		final int materialDataExtraBits = lightManager.hasAttachedLight(uuid)
			? Material.MATERIAL_FLAG_HAS_ATTACHED_LIGHT : 0;
```

Find the resolved override in this method. Streamed paths typically resolve override via `ModelStreamingManager` or `modelOverrideManager`; locate the local variable holding the `ModelOverride` (it'll be named `modelOverride` or similar — read 20 lines above the existing block to confirm). Replace with:

```java
		// Auto-tag fragments for AgX surface vibrance compensation if the
		// renderable has an attached light in lights.json OR the resolved
		// ModelOverride has legacyHighlightClip=true. Mirrors uploadStaticModel.
		final int materialDataExtraBits =
			(lightManager.hasAttachedLight(uuid) || modelOverride.legacyHighlightClip)
				? Material.MATERIAL_FLAG_HAS_ATTACHED_LIGHT : 0;
```

If the local variable holding the override is named differently (e.g. `override`, `mo`), substitute the actual name. **If no resolved override is available in scope, escalate as BLOCKED rather than guessing** — the override has to come from somewhere the upload knows about.

- [ ] **Step 4: Verify build**

Run: `./gradlew compileJava`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Commit**

```bash
git add src/main/java/rs117/hd/renderer/zone/SceneUploader.java
git commit -m "OR ModelOverride.legacyHighlightClip into per-face attached-light bit"
```

---

### Task 5: scene_frag.glsl — compute per-fragment material legacy-clip blend, write max contribution to fragTag

**Files:**
- Modify: `src/main/resources/rs117/hd/scene_frag.glsl`
  - Add the per-fragment legacy-clip blend computation alongside the existing `hasAttachedLightBlend` block (around lines 586–597)
  - Update the `fragTag` write at line 791–792 to combine both contributions

- [ ] **Step 1: Add `legacyHighlightBlend` computation**

Edit `src/main/resources/rs117/hd/scene_frag.glsl`. Around line 592 there's the existing block:

```glsl
            float hasAttachedLightBlend = dot(IN.texBlend, vec3(
                (fMaterialData[0] >> MATERIAL_FLAG_HAS_ATTACHED_LIGHT & 1),
                (fMaterialData[1] >> MATERIAL_FLAG_HAS_ATTACHED_LIGHT & 1),
                (fMaterialData[2] >> MATERIAL_FLAG_HAS_ATTACHED_LIGHT & 1)
            ));
            _probeHasAttachedLightBlend = hasAttachedLightBlend;
```

Immediately after `_probeHasAttachedLightBlend = hasAttachedLightBlend;`, add:

```glsl
            // Per-material legacy-clip signal: materials.json `legacyHighlightClip: true`
            // packs MaterialStruct.flags bit 3, blended through IN.texBlend the same way
            // unlit and hasAttachedLight are. Full-strength (1.0) contribution to fragTag.
            float legacyHighlightBlend = dot(IN.texBlend, vec3(
                getMaterialIsLegacyClip(material1),
                getMaterialIsLegacyClip(material2),
                getMaterialIsLegacyClip(material3)
            ));
```

(Match the surrounding 12-space indentation — the block is inside the `#if !LEGACY_RENDERER` guard which is itself nested.)

- [ ] **Step 2: Update the `fragTag` write to combine both contributions**

In the same file, around lines 776–793, the existing write reads:

```glsl
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
        float tagContribution = _probeHasAttachedLightBlend * clamp(outputColor.r, 0.0, 1.0);
        fragTag = vec4(tagContribution);
    #endif
}
```

Replace the `float tagContribution = ...;` line (only that one line) with:

```glsl
        // Two contributions max-combined at write time:
        //   - hasAttachedLight path: scaled by agxSurfaceVibrance so the existing
        //     tagged-glow tuning slider still controls these fragments.
        //   - legacyHighlightClip path: always full strength (lava etc. are
        //     explicitly tagged for full legacy treatment in materials.json).
        // Brightness gate via outputColor.r (OKLab L clamped to [0,1]) still applies
        // so invisible-but-tagged draws don't contribute (e.g. GOTR barrier dummy).
        float attached = _probeHasAttachedLightBlend * agxSurfaceVibrance;
        float tagContribution = max(attached, legacyHighlightBlend) * clamp(outputColor.r, 0.0, 1.0);
```

Note: this also requires reading `agxSurfaceVibrance` (uniform from UBOGlobal — already accessible everywhere). No new uniform.

- [ ] **Step 3: Verify build**

Run: `./gradlew compileJava`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add src/main/resources/rs117/hd/scene_frag.glsl
git commit -m "scene_frag: max-combine attached-light (vibrance-scaled) + material legacy-clip"
```

---

### Task 6: tonemap_frag.glsl — drop `* agxSurfaceVibrance` (now applied upstream)

**Files:**
- Modify: `src/main/resources/rs117/hd/post/tonemap_frag.glsl` (around line 47, the `effective` computation)

- [ ] **Step 1: Update the effective-strength expression**

Edit `src/main/resources/rs117/hd/post/tonemap_frag.glsl`. The current line reads (around line 47):

```glsl
    float effective = min(agxLegacyMix + tag * agxSurfaceVibrance, 1.0);
```

Replace with:

```glsl
    float effective = min(agxLegacyMix + tag, 1.0);
```

The tag value now arrives with vibrance already applied (for the attached-light path) or full-strength (for the material legacy-clip path) — see scene_frag.glsl after Task 5.

Also update the comment block above. The current comment (around lines 39–48) mentions `tag * agxSurfaceVibrance`. Update the bullet for the tag-mask path:

The existing bullet reads:

```glsl
    //   - tag * agxSurfaceVibrance: per-fragment, driven by the R8 tag mask that
    //     scene_frag writes for fragments with attached lights.
```

Replace with:

```glsl
    //   - tag: per-fragment, written to the R8 tag mask by scene_frag. Combines
    //     two upstream sources (max'd at write time): attached-light tagged
    //     geometry scaled by agxSurfaceVibrance, and material/override-flagged
    //     fragments at full strength.
```

- [ ] **Step 2: Verify build**

Run: `./gradlew compileJava`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
git add src/main/resources/rs117/hd/post/tonemap_frag.glsl
git commit -m "tonemap_frag: tag now arrives with vibrance applied upstream"
```

---

### Task 7: Tag lava materials in `materials.json`

**Files:**
- Modify: `src/main/resources/rs117/hd/scene/materials.json`

Apply `"legacyHighlightClip": true` to each of the following material entries:
- `LAVA` (line ~219)
- `RED_LAVA` (line ~357)
- `FIRE_CAPE` (line ~276)
- `INFERNAL_CAPE` (line ~370)
- `HD_LAVA_1` (line ~2221)
- `HD_LAVA_2` (line ~2232)
- `HD_MAGMA_1` (line ~2243)
- `HD_MAGMA_2` (line ~2254)
- `HD_INFERNAL_CAPE` (line ~2482)
- `LEGACY_INFERNAL_CAPE` (line ~2501)
- `HD_LAVA_3` (line ~2579)

- [ ] **Step 1: Add the field to each entry**

For each material listed above, add `"legacyHighlightClip": true,` as a new property immediately after the `"name":` line. Example for `HD_LAVA_1`:

Before:
```json
  {
    "name": "HD_LAVA_1",
    "flowMap": "LAVA_FLOW_MAP",
    "overrideBaseColor": true,
    "unlit": true,
    "flowMapStrength": 0.04,
    "flowMapDuration": [
      36.0,
      12.0
    ]
  },
```

After:
```json
  {
    "name": "HD_LAVA_1",
    "legacyHighlightClip": true,
    "flowMap": "LAVA_FLOW_MAP",
    "overrideBaseColor": true,
    "unlit": true,
    "flowMapStrength": 0.04,
    "flowMapDuration": [
      36.0,
      12.0
    ]
  },
```

Repeat for each of the 11 entries listed.

- [ ] **Step 2: Validate JSON**

Run: `python -c "import json; json.load(open('src/main/resources/rs117/hd/scene/materials.json'))"`
Expected: no output (parses cleanly).

- [ ] **Step 3: Commit**

```bash
git add src/main/resources/rs117/hd/scene/materials.json
git commit -m "Tag lava/fire-cape materials with legacyHighlightClip=true"
```

---

### Task 8: Tag the LAVABUBBLES override (including LARGE variants and instance copies)

**Files:**
- Modify: `src/main/resources/rs117/hd/scene/model_overrides.json`

- [ ] **Step 1: Extend the existing LAVABUBBLES entry**

Edit `src/main/resources/rs117/hd/scene/model_overrides.json`. Around line 5773–5779 the existing entry reads:

```json
  {
    "description": "LAVABUBBLES",
    "baseMaterial": "GRAY_110",
    "upwardsNormals": true,
    "objectIds": [
      "LAVABUBBLES"
    ]
  },
```

Replace with:

```json
  {
    "description": "LAVABUBBLES",
    "baseMaterial": "GRAY_110",
    "upwardsNormals": true,
    "legacyHighlightClip": true,
    "objectIds": [
      "LAVABUBBLES",
      "LAVABUBBLES_LARGE",
      "RC_ZMI_LAVABUBBLES",
      "RC_ZMI_LAVABUBBLES_LARGE",
      "RAIDS_LAVABUBBLES",
      "RAIDS_LAVABUBBLES_LARGE"
    ]
  },
```

The added `objectIds` are all the bubble variants found in `gamevals.json` (3609, 29632, 29633, 29890, 29891). They share the same vanilla geometry/material, so a single override entry covers them all.

- [ ] **Step 2: Validate JSON**

Run: `python -c "import json; json.load(open('src/main/resources/rs117/hd/scene/model_overrides.json'))"`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add src/main/resources/rs117/hd/scene/model_overrides.json
git commit -m "Tag LAVABUBBLES/_LARGE/raids/zmi variants with legacyHighlightClip"
```

---

### Task 9: Build, launch, visual verification

**Files:** none modified. This task gates merge.

- [ ] **Step 1: Full build**

Run: `./gradlew build`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 2: Launch RuneLite with the plugin**

If you cannot launch from this dispatch, report DONE_WITH_CONCERNS and hand the visual verification to the user.

- [ ] **Step 3: Karamja volcano lava tiles**

Travel to Karamja volcano (e.g. region near Karamja dungeon entry). Press Ctrl+F3 for Tile Info. Hover a lava tile — confirm `Overlay ID 19 → LAVA → HD_LAVA_*`. The lava should now display with legacy-clip character (saturated, hard highlights) while the surrounding dirt and rocks stay on AgX appearance.

- [ ] **Step 4: LAVABUBBLES_LARGE popping**

Stay in the same area and watch for bubbles popping on the lava surface. They should pop with the same saturated/hard-highlight character as the lava beneath them, scaled by the current `agxSurfaceVibrance` slider value (default 70%).

- [ ] **Step 5: TZHAAR sanity**

Travel to TZHAAR. The lava there should look unchanged from before this work — env mix is already 1.0, so the additive combination (envMix + tag) saturates at 1.0 regardless of whether the material/override flags add tag contributions.

- [ ] **Step 6: Fire cape on character**

If a fire cape is equippable, equip and check the cape's appearance against the legacy renderer reference. Cape should now clip-toward-legacy (more saturated reds, harder highlights). Same expectation for infernal cape if available.

- [ ] **Step 7: GOTR rewards guardian regression**

Travel to GOTR. The rewards guardian and barrier (existing attached-light tagged glow) should look essentially the same as before this work. The math change moved `* agxSurfaceVibrance` from tonemap to scene_frag write — the product is the same when nothing else writes to the same fragment. Sanity-check by toggling the `agxSurfaceVibrance` slider 0% / 70% / 100% and confirming the existing tagged glow surfaces still respond correctly.

- [ ] **Step 8: Lumbridge regression**

No lava, no flagged materials, no flagged objects, no env mix — should be byte-for-byte identical to before this work.

- [ ] **Step 9: Hot-reload sanity**

With the plugin running and standing on Karamja lava, edit `materials.json` to remove `legacyHighlightClip` from `HD_LAVA_1` and save. The lava tiles using HD_LAVA_1 specifically (per the rotation in `ground_materials.json` HD_LAVA) should revert to AgX appearance live. Restore the field after.

- [ ] **Step 10: Final commit (only if verification surfaced a fix)**

If a small tweak was needed:
```bash
git add <changed-files>
git commit -m "<fix description>"
```
Otherwise no commit needed — prior eight tasks already committed atomic chunks.

---

## Self-Review

**Spec coverage:**
- Per-material flag (Layer A) → Tasks 1, 2, 5, 7 ✓
- Per-ModelOverride flag (Layer B) → Tasks 3, 4, 5, 8 ✓
- max-combine of two strengths in scene_frag → Task 5 ✓
- Drop vibrance from tonemap → Task 6 ✓
- Tag lava family + fire cape variants → Task 7 ✓
- Tag LAVABUBBLES + variants → Task 8 ✓
- Verification of all listed surfaces (Karamja, bubbles, TZHAAR, fire cape, GOTR, Lumbridge) → Task 9 ✓

**Placeholder scan:** No "TBD"/"TODO". One conditional fallback in Task 4 Step 3 (if streamed override variable has different name, substitute) — this is a real codebase-grounded instruction, not a placeholder; the BLOCKED guidance is explicit.

**Type consistency:**
- `legacyHighlightClip` (boolean) used consistently in Tasks 2 (Material field), 3 (ModelOverride field), 4 (override read), 7 (materials.json key), 8 (model_overrides.json key).
- `MaterialStruct.flags` bit 3 introduced in Task 1 (GLSL getter), consumed in Task 5 (scene_frag dot-product).
- `getMaterialIsLegacyClip(material)` defined in Task 1, called in Task 5.
- `legacyHighlightBlend` variable named in Task 5 and consumed at the `fragTag` write within the same task.
- `MATERIAL_FLAG_HAS_ATTACHED_LIGHT` bit reuse for override path documented in Task 4 (the bit is repurposed as "either source wants vibrance-scaled legacy mix").

**Scope:** Nine tasks, all small atomic edits with build verification between them. No new uniforms, no new MRT attachments, no new bit allocation. Single implementation cycle, no decomposition needed.
