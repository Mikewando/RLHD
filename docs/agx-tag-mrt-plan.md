# MRT tag-mask compensation for AgX (plan, branch `feature/agx-tag-mrt`)

## Why

Probe + oracle work (see `AgxOracleTest`) established:

- For a representative middle-of-eye glow pixel, current pre-AgX linear is
  `(0.538, 0.342, 0.110)` → AgX → display sRGB `(0.744, 0.647, 0.456)`.
- The closest reachable display through AgX for the legacy-target sRGB
  `(0.844, 0.732, 0.188)` requires pre-AgX linear `(0.694, 0.455, 0.000)`.
- The current pipeline cannot reach that target because the post-OKLab,
  post-exposure linear at this pixel carries B ≈ 0.110 (background's lit B
  bleeds through the alpha blend in OKLab space, even though the glow's own
  authored B is near zero).
- Layer B (per-fragment inverse-AgX in `scene_frag`) is in the wrong place:
  the per-layer lit color is not what AgX eventually sees, so any compensation
  computed there is degraded by sRGB round-trip, OKLab encode, alpha blend
  with other layers, and exposure scaling before reaching AgX.

The right place to apply compensation is in `tonemap_frag`, where the final
pre-AgX linear value at the pixel actually exists. To do that, `tonemap_frag`
needs a per-pixel signal saying "how much of this pixel came from tagged
geometry," which is what this plan adds.

## Approach

Add a second color attachment to the scene FBO that carries a per-pixel
"tagged-contribution fraction" mask, written by `scene_frag` with the same
alpha blending used for color, then read in `tonemap_frag` to apply a
chroma/saturation shift before AgX.

The compensation strength is the existing `agxSurfaceVibrance` slider.
The per-fragment Layer B path in `scene_frag` gets removed (it's been wrong).
Layer A (point-light pre-multiplication in `lights.glsl`) is unrelated; it
stays.

## Pieces

### 1. FBO infrastructure

- Add a second color attachment to `fboScene` (multisampled, same MSAA as the
  main color attachment) at `GL_COLOR_ATTACHMENT1`. Format `R8` is enough
  (256 levels of [0..1] mask). If precision becomes an issue we can switch to
  `R16F`, but R8 first.
- Add the matching attachment to `fboSceneResolve`.
- `glDrawBuffers({GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1})` before scene
  pass so `scene_frag` writes both.
- Blit copies both attachments: do two blits with single-attachment read/draw
  bindings, or use `glDrawBuffers` for the resolve. (Need to confirm what
  `glBlitFramebuffer(GL_COLOR_BUFFER_BIT)` does with multiple attachments —
  spec says it blits whichever is bound as `GL_COLOR_ATTACHMENTN` on both
  sides via `glReadBuffer` / `glDrawBuffer`.)
- Clear both attachments at the start of the scene pass. Tag clears to 0.

### 2. `scene_frag` writes the tag

- `layout(location = 1) out float fragTag;`
- At the end of `main()`, alongside `FragColor = outputColor;`:
  `fragTag = _probeHasAttachedLightBlend;` (already computed for the surface
  vibrance path; rename out of `_probe*` since it's no longer probe-only)
- The same blend func (`GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA`) operates on
  this attachment using the alpha of `FragColor`. Result: tag accumulates the
  alpha-weighted fraction of the pixel that came from tagged fragments. For
  the example glow stack (3 translucent tagged glow draws at α=0.17 over
  opaque untagged background, then a near-transparent tagged barrier), the
  final tag value is ≈ 0.43.
- For untagged fragments, `fragTag = 0.0`. Background draws first with α=1
  will overwrite the tag to 0; tagged draws on top accumulate from there.

### 3. `tonemap_frag` reads the tag and applies compensation

```glsl
uniform sampler2D tagTex;
...
vec3 linear = oklabToLinear(oklab) * exposure;
float tag = texture(tagTex, fUv).r;
if (tag > 0.0) {
    linear = applyTagCompensation(linear, tag * agxSurfaceVibrance);
}
vec3 srgb = linearToSrgb(agxTonemap(linear));
```

Starting `applyTagCompensation` formula (saturation boost — gets to err≈0.108
on the example pixel vs unconstrained-optimum err≈0.083, per
`evaluateSaturationBoostCandidate`):

```glsl
vec3 applyTagCompensation(vec3 linear, float strength) {
    float luma = dot(linear, vec3(0.2126, 0.7152, 0.0722));
    vec3 chroma = linear - vec3(luma);
    return max(linear + chroma * strength, vec3(0.0));
}
```

This pushes each channel away from luma proportional to `strength`. For our
warm-orange example with strength≈1, B goes to 0 and R increases ~30%, very
close to what the oracle says AgX needs. The formula is hue-preserving — it
works for any chroma direction (lava red, magic blue, etc.) — but is not
optimal per pixel; we can iterate later (e.g., a "subtract min channel, then
brighten" variant if needed for other colors).

### 4. Configuration

- Reuse the existing `agxSurfaceVibrance` slider — its meaning becomes
  "strength of tag-driven chroma boost in tonemap" instead of "strength of
  per-fragment inverse-AgX."
- Default value to be picked after probing the eye and a few other tagged
  scenes with the live shader.

### 5. Cleanup

- Remove `agxInverseToHdrInput` GLSL function (no longer used) and the per-
  fragment Layer B block in `scene_frag` (the `_probePreInvert` capture and
  the `mix(outputColor.rgb, inverted * max(t, 1.0), min(t, 1.0))` line).
- Keep the probe SSBO infrastructure for now (useful for ongoing validation).
  Make the new tag attachment also accessible to the probe so we can capture
  per-pixel tag value alongside other data.

## Validation plan

1. Unit test (already drafted) — `evaluateSaturationBoostCandidate` predicts
   what the saturation-boost formula produces through AgX given an input.
   After implementation, probe the same eye pixel and compare actual
   compensated pre-AgX linear vs the oracle's prediction. Should match to
   within float precision.
2. Visual test — probe the eye middle, eye edge (white outline, where tag=1
   for the opaque outline and the compensation should still apply but the
   outline is near-neutral so saturation boost is a no-op), coral (tag=0,
   compensation must not fire), and a daylit overworld scene (regression
   check — no tagged objects, no behaviour change).
3. Animation-phase robustness: the eye samples vary between frames; pick
   several probes across an animation cycle and verify the post-compensation
   pre-AgX is in the expected zone each time.
4. Different colored attached lights: check GOTR_BARRIER_CLOSED (red-tinted
   light), Karuulm lava (red-orange), and a magic portal (blue) to confirm
   the hue-preserving formula doesn't push them in the wrong direction.

## Risks / open questions

- **R8 quantization on a near-zero tag.** With tag accumulating from
  fractional alpha-blends, intermediate values could be small (e.g., 1/256 ≈
  0.004). For the glow case the final tag is ~0.43 so plenty of headroom,
  but worth confirming with a real probe before assuming R8 is enough.
- **Blit semantics for multi-attachment FBOs.** May need two blits (one per
  attachment) instead of one. If `texSceneDepthResolve` is needed too, that's
  a third blit. Performance impact should be tiny (resolve, not extra
  rasterization) but worth measuring.
- **MRT support across drivers.** RLHD targets GL 4.3+ for the zone renderer
  so two color attachments + MSAA are well-supported. No expected portability
  issue.
- **Compensation formula coverage.** Saturation-boost works well for chroma-
  away-from-grey targets (warm yellow, saturated red, saturated blue). For
  targets that need a hue *shift* rather than chroma push, this formula
  won't help — but no probed example needs that yet.
- **What about untagged-but-warm pixels?** They won't be compensated. That's
  intentional — untagged scenery should keep AgX's natural rolloff.
- **Interaction with Layer A** (point-light pre-multiplication for OFF-tagged
  surfaces lit by tagged lights). Layer A pre-saturates the light
  contribution per fragment; this tonemap-pass compensation pre-saturates the
  final pixel. They stack additively for surfaces lit by tagged lights — may
  need to attenuate one or the other. Tune after testing.

## Order of work on this branch

1. Plumb the second color attachment (FBO + clear + blit).
2. Write `fragTag` from `scene_frag`. Probe to confirm tag values match the
   stack analysis (e.g., glow-only pixel ≈ 0.43, white outline pixel ≈ 1.0,
   coral pixel = 0).
3. Sample `tagTex` in `tonemap_frag`. Add a debug mode to visualize the tag
   directly (e.g., render `vec3(tag)` to screen) so we can see the mask shape
   before applying compensation.
4. Implement `applyTagCompensation` with the saturation-boost formula.
5. Compare in-game vs the oracle prediction at the probe pixel.
6. Remove the now-dead per-fragment Layer B path from `scene_frag`.
7. Iterate on the compensation formula / default vibrance value.
