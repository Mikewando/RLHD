# Per-Environment AgX Legacy-Highlight Mix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-environment scalar (`legacyHighlightMix`, 0–1) that, when > 0, blends each fragment's AgX-tonemapped color toward `clamp(linear, 0, 1)` — restoring legacy clip+sRGB highlight behavior for stylized zones like TZHAAR. TZHAAR opts in at 1.0; all other environments keep current AgX behavior.

**Architecture:** Six small layers stack from data to pixel:
1. `Environment.java` exposes the field, defaulting to 0.
2. `EnvironmentManager.java` snapshots and cross-fades it like other scalar environment params (3s lerp, instant snap on big jumps).
3. `UBOGlobal.java` + `global.glsl` declare the matching uniform `agxLegacyMix` (kept in std140 order with the surrounding AgX block).
4. `ZoneRenderer.scenePass()` uploads `environmentManager.currentLegacyHighlightMix → uboGlobal.agxLegacyMix` each frame.
5. `tonemap_frag.glsl` adds the env strength to the existing per-fragment tag strength inside the legacy-target mix (clamped to 1.0).
6. `environments.json` TZHAAR entry sets `"legacyHighlightMix": 1.0`.

The Java-side authoring name (`legacyHighlightMix`) intentionally differs from the shader-side name (`agxLegacyMix`) — the former describes the effect for authors editing JSON, the latter matches the `agx*` naming convention used by neighboring uniforms (`agxSurfaceVibrance`, `agxPunchPower`, etc.). The bridge happens at one line in `ZoneRenderer.scenePass()`.

**Tech Stack:** Java 11, GLSL 330, LWJGL, std140 UBO layout. No new dependencies. No new test infrastructure — the changes are pipeline plumbing whose correctness is validated by build success, `DebugProbe` slot inspection (existing infrastructure), and in-game visual verification against the saved `legacy lava.png` and `zone lava.png` references.

**Note on test discipline:** This plan is glue code across data-class fields, transition arithmetic that mirrors ~20 existing scalars, a UBO property, a GLSL uniform, and one shader mix line. There is no unit-test surface that adds confidence over the build-success + visual checks. Don't fabricate tests; the verification task at the end is the real acceptance gate.

---

### Task 1: Add `legacyHighlightMix` field to `Environment.java`

**Files:**
- Modify: `src/main/java/rs117/hd/scene/environments/Environment.java` (add field around line 75, alongside other scalar environment fields like `windAngle`/`windSpeed`)

- [ ] **Step 1: Read the file's existing scalar-field section to choose an insertion point**

Run: read `src/main/java/rs117/hd/scene/environments/Environment.java` lines 60–80.

The existing scalar/JSON-authored fields cluster near `windAngle`, `windSpeed`, `windStrength`, `windCeiling` (currently lines 72–75). Insert the new field at the end of that cluster (immediately after `windCeiling`).

- [ ] **Step 2: Add the field**

Edit `src/main/java/rs117/hd/scene/environments/Environment.java`. After the existing `public float windCeiling = 1280.0f;` line, add:

```java
public float legacyHighlightMix = 0;
```

Indent with tabs to match the file (the rest of the file uses tab indentation).

- [ ] **Step 3: Verify build**

Run: `./gradlew compileJava`
Expected: BUILD SUCCESSFUL. No new warnings related to `Environment`.

- [ ] **Step 4: Commit**

```bash
git add src/main/java/rs117/hd/scene/environments/Environment.java
git commit -m "Add Environment.legacyHighlightMix field (default 0)"
```

---

### Task 2: Add transition state and arithmetic in `EnvironmentManager.java`

**Files:**
- Modify: `src/main/java/rs117/hd/scene/EnvironmentManager.java`
  - Declare three fields (around line 152, after `currentWindCeiling`)
  - Add interpolation line in the transition block (after line 288 — last `mix(...)` line before the closing brace of the `else` branch)
  - Add snapshot write in `changeEnvironment(...)` (after line 339 — last `start... = current...` line before the `for` loop that handles sunAngles)
  - Add target write in `changeEnvironment(...)` (after line 372 — last `target... = env...` line; see Step 4 for exact location)

- [ ] **Step 1: Add the three transition state fields**

Edit `src/main/java/rs117/hd/scene/EnvironmentManager.java`. After the existing `currentWindCeiling` block (lines 150–152), add a blank line then:

```java
	private float startLegacyHighlightMix = 0f;
	public float currentLegacyHighlightMix = 0f;
	private float targetLegacyHighlightMix = 0f;
```

(Use tabs; the file is tab-indented.)

- [ ] **Step 2: Add the interpolation line**

In the same file, locate the transition `else` branch that starts at line 264 (`} else {`) and contains the `mix(...)` calls. The last `mix(...)` line is currently `currentWindCeiling = mix(startWindCeiling, targetWindCeiling, t);` (line 288). Immediately after that line, add:

```java
				currentLegacyHighlightMix = mix(startLegacyHighlightMix, targetLegacyHighlightMix, t);
```

- [ ] **Step 3: Add the snapshot write in `changeEnvironment(...)`**

In the same file, locate `changeEnvironment(...)`. After the existing `startWindCeiling = currentWindCeiling;` line (currently line 339), add:

```java
		startLegacyHighlightMix = currentLegacyHighlightMix;
```

- [ ] **Step 4: Add the target write in `changeEnvironment(...)`**

Still in `changeEnvironment(...)`. Find the block that sets target values from the resolved `env`. The last existing assignment of this kind is around line 372 (it currently reads `targetWindCeiling = env.windCeiling;` or similar — confirm by searching `targetWind`). Immediately after that block, add:

```java
		targetLegacyHighlightMix = env.legacyHighlightMix;
```

(Place it outside the `if (!config.atmosphericLighting() && !env.force)` reassignment block if one wraps the surrounding lines — `legacyHighlightMix` is not subject to the atmospheric-lighting override.)

- [ ] **Step 5: Verify build**

Run: `./gradlew compileJava`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 6: Smoke-check at runtime (optional but recommended)**

If you can launch RuneLite with the plugin attached, add a temporary log line in `update(...)` after the transition arithmetic:

```java
log.debug("legacyHighlightMix current={} target={}", currentLegacyHighlightMix, targetLegacyHighlightMix);
```

Walk into TZHAAR (any region matching the existing TZHAAR area) and verify the log shows the value transitioning from 0 → 0 (since no environment opts in yet). Then revert the log line.

This step verifies the transition arithmetic doesn't NaN/crash even without any opted-in environment.

- [ ] **Step 7: Commit**

```bash
git add src/main/java/rs117/hd/scene/EnvironmentManager.java
git commit -m "Plumb legacyHighlightMix through EnvironmentManager transitions"
```

---

### Task 3: Add `agxLegacyMix` to UBO and GLSL uniform block

**Files:**
- Modify: `src/main/java/rs117/hd/opengl/uniforms/UBOGlobal.java` (insert after line 28, between `agxSurfaceVibrance` and `debugAttachedLightTint`)
- Modify: `src/main/resources/rs117/hd/uniforms/global.glsl` (insert after line 17, between `agxSurfaceVibrance` and `debugAttachedLightTint`)

**Critical:** std140 layout requires identical declaration order in both files. Do both edits in the same commit; if order diverges, subsequent uniforms will read wrong values silently.

- [ ] **Step 1: Add the UBO property in `UBOGlobal.java`**

Edit `src/main/java/rs117/hd/opengl/uniforms/UBOGlobal.java`. Currently line 28 reads:

```java
	public Property agxSurfaceVibrance = addProperty(PropertyType.Float, "agxSurfaceVibrance");
```

Insert a new line immediately after it:

```java
	public Property agxLegacyMix = addProperty(PropertyType.Float, "agxLegacyMix");
```

- [ ] **Step 2: Add the matching GLSL uniform in `global.glsl`**

Edit `src/main/resources/rs117/hd/uniforms/global.glsl`. Currently line 17 reads:

```glsl
    float agxSurfaceVibrance;
```

Insert a new line immediately after it:

```glsl
    float agxLegacyMix;
```

(Indent with 4 spaces to match the rest of the block.)

- [ ] **Step 3: Verify build**

Run: `./gradlew compileJava`
Expected: BUILD SUCCESSFUL. (Shader compilation happens at runtime, not at build, so a GLSL syntax error would only surface in-game. The text edits here are mechanical enough that a syntax issue is unlikely; double-check the trailing semicolon if anything looks off.)

- [ ] **Step 4: Commit**

```bash
git add src/main/java/rs117/hd/opengl/uniforms/UBOGlobal.java src/main/resources/rs117/hd/uniforms/global.glsl
git commit -m "Add agxLegacyMix UBO property and GLSL uniform"
```

---

### Task 4: Upload `agxLegacyMix` each frame in `ZoneRenderer.scenePass()`

**Files:**
- Modify: `src/main/java/rs117/hd/renderer/zone/ZoneRenderer.java` (insert after line 623 — the existing `agxSurfaceVibrance` upload)

- [ ] **Step 1: Add the upload line**

Edit `src/main/java/rs117/hd/renderer/zone/ZoneRenderer.java`. Currently line 623 reads:

```java
		plugin.uboGlobal.agxSurfaceVibrance.set(config.agxSurfaceVibrance() / 100f);
```

Insert a new line immediately after it:

```java
		plugin.uboGlobal.agxLegacyMix.set(environmentManager.currentLegacyHighlightMix);
```

Note: this is sourced from `environmentManager` (not `config`), because the value is per-environment, not a config slider.

- [ ] **Step 2: Verify build**

Run: `./gradlew compileJava`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
git add src/main/java/rs117/hd/renderer/zone/ZoneRenderer.java
git commit -m "Upload agxLegacyMix to UBO from EnvironmentManager"
```

---

### Task 5: Wire the uniform into the shader's tag-mask block in `tonemap_frag.glsl`

**Files:**
- Modify: `src/main/resources/rs117/hd/post/tonemap_frag.glsl` (replace lines 45–49)

- [ ] **Step 1: Replace the tag-mask block**

Edit `src/main/resources/rs117/hd/post/tonemap_frag.glsl`. The existing block at lines 45–49 reads:

```glsl
    float tag = texture(tagTex, fUv).r;
    if (tag > 0.0 && agxSurfaceVibrance > 0.0) {
        vec3 legacyTarget = clamp(linear, 0.0, 1.0);
        agxOut = mix(agxOut, legacyTarget, min(tag * agxSurfaceVibrance, 1.0));
    }
```

Replace with:

```glsl
    float tag = texture(tagTex, fUv).r;
    float effective = min(agxLegacyMix + tag * agxSurfaceVibrance, 1.0);
    if (effective > 0.0) {
        vec3 legacyTarget = clamp(linear, 0.0, 1.0);
        agxOut = mix(agxOut, legacyTarget, effective);
    }
```

Also update the inline comment immediately above this block (the existing comment talks only about the tag-mask path; revise it to mention both contributions). Currently lines 41–44 read:

```glsl
    // Tag-driven compensation. The R8 mask was written by scene_frag and
    // alpha-blended through the scene pass; its value here is the fraction of the
    // pixel's color that came from tagged geometry. Where tag > 0, mix AgX's
    // output toward the literal legacy target = clamp(linear, 0, 1). Both values
    // live in the same [0,1] display-linear space, so no gamut juggling is needed
    // and the eventual display sRGB matches legacy clip+sRGB exactly at strength=1.
```

(That's actually lines 41–46.) Replace with:

```glsl
    // Legacy-clip compensation. Two strengths combine additively (clamped to 1):
    //   - agxLegacyMix: per-environment scalar set from environments.json; uniform
    //     across the scene, lets a whole zone (e.g. TZHAAR) hard-clip highlights.
    //   - tag * agxSurfaceVibrance: per-fragment, driven by the R8 tag mask that
    //     scene_frag writes for fragments with attached lights.
    // Both pull AgX's output toward clamp(linear, 0, 1) — the literal legacy
    // target. At combined strength=1 the result matches legacy clip+sRGB exactly.
```

- [ ] **Step 2: Verify build**

Run: `./gradlew compileJava`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Launch and confirm shader compiles**

If you can launch the plugin, the shader compiles at startup. A typo would produce a GLSL compile error logged at plugin init. With `agxLegacyMix = 0` (no env opts in yet), there should be no visible change anywhere in the game.

If you can't launch right now, defer this check to Task 7.

- [ ] **Step 4: Commit**

```bash
git add src/main/resources/rs117/hd/post/tonemap_frag.glsl
git commit -m "Combine agxLegacyMix and tag-mask in tonemap_frag legacy-clip block"
```

---

### Task 6: Opt TZHAAR into the new behavior in `environments.json`

**Files:**
- Modify: `src/main/resources/rs117/hd/scene/environments.json` (add field to TZHAAR entry at line 262)

- [ ] **Step 1: Add the field**

Edit `src/main/resources/rs117/hd/scene/environments.json`. The TZHAAR entry currently looks like:

```json
  {
    "area": "TZHAAR",
    "ambientColor": "#ffeacc",
    "ambientStrength": 0.8,
    "directionalColor": "#ffa400",
    "directionalStrength": 1.8,
    "sunAngles": [
      80,
      190
    ],
    "fogColor": "#1a0808",
    "fogDepth": 15
  },
```

Add `"legacyHighlightMix": 1.0,` immediately after `"area": "TZHAAR",`:

```json
  {
    "area": "TZHAAR",
    "legacyHighlightMix": 1.0,
    "ambientColor": "#ffeacc",
    "ambientStrength": 0.8,
    "directionalColor": "#ffa400",
    "directionalStrength": 1.8,
    "sunAngles": [
      80,
      190
    ],
    "fogColor": "#1a0808",
    "fogDepth": 15
  },
```

- [ ] **Step 2: Validate JSON**

Run: `python -c "import json; json.load(open('src/main/resources/rs117/hd/scene/environments.json'))"`
Expected: no output (parses cleanly).

If this errors with a syntax issue, fix the trailing comma / quoting before proceeding.

- [ ] **Step 3: Commit**

```bash
git add src/main/resources/rs117/hd/scene/environments.json
git commit -m "Opt TZHAAR into legacyHighlightMix=1.0"
```

---

### Task 7: Build, launch, visually verify

**Files:** none modified. This task gates merge — confirms the stack works end-to-end.

- [ ] **Step 1: Full build**

Run: `./gradlew build`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 2: Launch RuneLite with the plugin**

Use the project's standard launch procedure (typically a Gradle `runClient` task or running RuneLite with the plugin sideloaded). Log into a character and travel to TZHAAR.

If launching from this session is not possible, hand the task to the user with: "Please launch and verify per the steps below."

- [ ] **Step 3: Confirm region/environment match**

Press **Ctrl+F3** to enable the Tile Info overlay (`DeveloperTools.java:32` — `KEY_TOGGLE_TILE_INFO`). Hover any tile in TZHAAR. The overlay should show:

```
Region ID: 9551, 9552, or any region in box 9807–10064
Environment: TZHAAR
```

- [ ] **Step 4: Visually compare against legacy reference**

Compare the current TZHAAR rendering against the saved `legacy lava.png` reference at the repo root. Lava, walls, and bright stylized surfaces should now hard-clip toward legacy appearance (saturated, no AgX desaturation rolloff).

The `zone lava.png` reference shows the pre-fix appearance (desaturated by AgX) — the current render should look notably more like `legacy lava.png` than `zone lava.png`.

If the result looks wrong (e.g. midtones over-affected, ground looks flat-gray, or no change visible at all), capture a screenshot and check:
- `DebugProbe` slot 21 (post-compensation linear) — should be close to `clamp(linear, 0, 1)` for highlights.
- `DebugProbe` slot 22 (post-compensation display sRGB) — should be close to legacy display values.
- Tile Info overlay — confirm Environment is TZHAAR, not a different fallback.

- [ ] **Step 5: Regression check — outside TZHAAR**

Teleport to Lumbridge or another daylit area. Visual appearance should be unchanged from before this work (no environment opts in there, `agxLegacyMix = 0`, mix is a no-op).

- [ ] **Step 6: Regression check — legacy renderer**

Switch to the legacy renderer in plugin config. Visual appearance unchanged in TZHAAR (legacy renderer doesn't use `tonemap_frag.glsl`).

Switch back to the zone renderer before continuing.

- [ ] **Step 7: Hot-reload sanity**

With the plugin running and standing in TZHAAR, edit `src/main/resources/rs117/hd/scene/environments.json` and change TZHAAR's `legacyHighlightMix` from `1.0` to `0.5`. Save. The on-screen appearance should soften toward a partial mix without restarting the plugin (proves the FileWatcher path works end-to-end).

Restore the value to `1.0` after the check.

- [ ] **Step 8: Tagged-glow regression check**

Travel to GOTR (Guardians of the Rift). The rewards guardian's yellow glow and the barrier's saturated yellow should still be enhanced by the existing tag-mask path — confirm by toggling `agxSurfaceVibrance` config slider between 0% and 70% and observing the change. The new `agxLegacyMix` (which is 0 here, outside TZHAAR) doesn't replace this path; both should work independently.

- [ ] **Step 9: Final commit (only if any tweaks were made during verification)**

If verification surfaced a minor issue you fixed, commit it:

```bash
git add <changed-files>
git commit -m "<fix description>"
```

Otherwise no commit needed — the prior six tasks already committed the feature in atomic chunks.

---

## Self-Review

**Spec coverage:**
- Shader change → Task 5 ✓
- Environment schema → Task 1 ✓
- Transition plumbing → Task 2 ✓
- UBO upload → Tasks 3 + 4 (split: declare in 3, upload in 4) ✓
- Environment opt-in → Task 6 ✓
- Naming bridge → implicit in Tasks 1, 3, 4 (Environment field name `legacyHighlightMix`, UBO/GLSL name `agxLegacyMix`, bridge at the one upload line in Task 4) ✓
- Edge cases (no-env fallback, sky, boundary, probe slots) → covered by verification in Task 7 ✓
- "What's not changing" guarantees → verified by Tasks 7 steps 5, 6, 8 ✓

**Placeholder scan:** No "TBD"/"TODO" in plan. All code shown literally. All exact line numbers given.

**Type consistency:**
- `legacyHighlightMix` (float) used consistently in Task 1 (declaration), Task 2 (transition fields and `env.legacyHighlightMix` read), Task 6 (JSON key).
- `agxLegacyMix` (Property/uniform) used consistently in Task 3 (declaration in both files), Task 4 (upload), Task 5 (shader read).
- Bridge line in Task 4 reads `environmentManager.currentLegacyHighlightMix` → writes `plugin.uboGlobal.agxLegacyMix` — matches Task 2 field name and Task 3 property name.

**Scope:** One environment opts in. One uniform added. One shader mix line altered. Suitable for a single implementation cycle. No decomposition needed.
