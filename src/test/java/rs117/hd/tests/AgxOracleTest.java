package rs117.hd.tests;

import java.awt.image.BufferedImage;
import java.io.File;
import javax.imageio.ImageIO;
import org.junit.Assert;
import org.junit.Test;
import rs117.hd.utils.ColorUtils;

/**
 * Oracle test for the AgX forward pipeline. Reproduces what tonemap.glsl does
 * (INPUT_MATRIX -> log2/normalize on [agxMinEv, agxMaxEv] -> sigmoid polynomial ->
 * punchy look (sat, pow) -> OUTPUT_MATRIX -> clamp [0,1] -> linearToSrgb) in plain
 * Java, then validates each stage against captured probe rows from 117hd.log so we
 * can use this code as a trusted oracle to ask "what AgX-input linear value would
 * produce display sRGB closest to target X?" without involving GPU state.
 *
 * Baseline AgX parameters for the captured probe rows: ev -10/4, exposure 0.8,
 * agxPunchSaturation = 1.05, agxPunchPower = 1.35.
 */
public class AgxOracleTest {

	// Mirrors AGX_INPUT_MATRIX in tonemap.glsl. GLSL mat3 is column-major.
	// COL[c] is column c. result[r] = sum_c COL[c][r] * v[c].
	static final float[][] AGX_INPUT_COLS = {
		{ 0.842479062253094f, 0.0784335999999992f, 0.0792237451477643f }, // col 0
		{ 0.0423282422610123f, 0.878468636469772f, 0.0791661274605434f }, // col 1
		{ 0.0423756549057051f, 0.0784336f, 0.879142973793104f },           // col 2
	};
	static final float[][] AGX_OUTPUT_COLS = {
		{ 1.19687900512017f, -0.0980208811401368f, -0.0990297440797205f },
		{ -0.0528968517574562f, 1.15190312990417f, -0.0989611768448433f },
		{ -0.0529716355144438f, -0.0980434501171241f, 1.15107367264116f },
	};

	static float[] mul(float[][] cols, float[] v) {
		float r = cols[0][0] * v[0] + cols[1][0] * v[1] + cols[2][0] * v[2];
		float g = cols[0][1] * v[0] + cols[1][1] * v[1] + cols[2][1] * v[2];
		float b = cols[0][2] * v[0] + cols[1][2] * v[1] + cols[2][2] * v[2];
		return new float[] { r, g, b };
	}

	static float[] applyVec3(float[] v, java.util.function.DoubleUnaryOperator f) {
		return new float[] { (float) f.applyAsDouble(v[0]), (float) f.applyAsDouble(v[1]), (float) f.applyAsDouble(v[2]) };
	}

	static float sigmoidScalar(double x) {
		double x2 = x * x;
		double x4 = x2 * x2;
		return (float) (15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232);
	}

	static float[] sigmoid(float[] v) {
		return new float[] { sigmoidScalar(v[0]), sigmoidScalar(v[1]), sigmoidScalar(v[2]) };
	}

	static float[] punchy(float[] ldr, float sat, float pow) {
		// Same as tonemap.glsl agxLookPunchy. Note BT.709 luma weights.
		float[] safe = applyVec3(ldr, x -> Math.max(0, x));
		float luma = 0.2126f * safe[0] + 0.7152f * safe[1] + 0.0722f * safe[2];
		float[] graded = applyVec3(safe, x -> Math.pow(x, pow));
		return new float[] {
			luma + sat * (graded[0] - luma),
			luma + sat * (graded[1] - luma),
			luma + sat * (graded[2] - luma),
		};
	}

	/** Forward AgX. Returns the linear display value after clamp, BEFORE linearToSrgb. */
	static float[] agxForwardLinear(float[] hdrLinear, float minEv, float maxEv, float punchSat, float punchPow) {
		float[] v = applyVec3(hdrLinear, x -> Math.max(0, x));
		v = mul(AGX_INPUT_COLS, v);
		v = applyVec3(v, x -> Math.max(1e-10, x));
		v = applyVec3(v, x -> {
			double l = Math.log(x) / Math.log(2);
			if (l < minEv) l = minEv;
			if (l > maxEv) l = maxEv;
			return (l - minEv) / (maxEv - minEv);
		});
		v = sigmoid(v);
		v = punchy(v, punchSat, punchPow);
		v = mul(AGX_OUTPUT_COLS, v);
		v = applyVec3(v, x -> Math.max(0, Math.min(1, x)));
		return v;
	}

	static float[] agxForwardSrgb(float[] hdrLinear, float minEv, float maxEv, float punchSat, float punchPow) {
		return ColorUtils.linearToSrgb(agxForwardLinear(hdrLinear, minEv, maxEv, punchSat, punchPow));
	}

	// ---------------- Validation against actual probe rows ----------------

	/** One probe row pulled from 117hd.log. All vectors below match the per-stage output the shader produced. */
	static final class ProbeRow {
		final String label;
		final float[] agxInputLinear; // post-exposure linear fed to agxTonemap
		final float[] inputMatrixOut;
		final float[] logNormalized;
		final float[] sigmoidOut;
		final float[] punchyOut;
		final float[] outputMatrixPreClamp;
		final float[] finalSrgb;
		final float minEv, maxEv, sat, pow;

		ProbeRow(String label, float[] agxInputLinear, float[] inputMatrixOut, float[] logNormalized,
				 float[] sigmoidOut, float[] punchyOut, float[] outputMatrixPreClamp, float[] finalSrgb,
				 float minEv, float maxEv, float sat, float pow) {
			this.label = label;
			this.agxInputLinear = agxInputLinear;
			this.inputMatrixOut = inputMatrixOut;
			this.logNormalized = logNormalized;
			this.sigmoidOut = sigmoidOut;
			this.punchyOut = punchyOut;
			this.outputMatrixPreClamp = outputMatrixPreClamp;
			this.finalSrgb = finalSrgb;
			this.minEv = minEv;
			this.maxEv = maxEv;
			this.sat = sat;
			this.pow = pow;
		}
	}

	// Probe: scene=1710,1351 (middle of eye) at ev -10/4, exposure 0.8, sat 1.05, pow 1.35.
	// Copied verbatim from 04:30:32 log entry.
	static final ProbeRow PROBE_MIDDLE_EYE = new ProbeRow(
		"middle of eye glow",
		new float[] { 0.53790f, 0.34233f, 0.11017f },
		new float[] { 0.47233f, 0.35156f, 0.16657f },
		new float[] { 0.63699f, 0.60656f, 0.52959f },
		new float[] { 0.56050f, 0.49776f, 0.34498f },
		new float[] { 0.45558f, 0.38441f, 0.22458f },
		new float[] { 0.51305f, 0.37613f, 0.17535f },
		new float[] { 0.74389f, 0.64696f, 0.45575f },
		-10f, 4f, 1.05f, 1.35f
	);

	private static void assertVecClose(String stage, float[] expected, float[] actual, float tol) {
		Assert.assertEquals(stage + ".r", expected[0], actual[0], tol);
		Assert.assertEquals(stage + ".g", expected[1], actual[1], tol);
		Assert.assertEquals(stage + ".b", expected[2], actual[2], tol);
	}

	@Test
	public void agxForwardMatchesProbeStages_middleOfEye() {
		ProbeRow r = PROBE_MIDDLE_EYE;
		final float TOL = 1e-3f;

		// Stage 1: AGX_INPUT_MATRIX
		float[] v = mul(AGX_INPUT_COLS, applyVec3(r.agxInputLinear, x -> Math.max(0, x)));
		assertVecClose(r.label + " INPUT_MATRIX", r.inputMatrixOut, v, TOL);

		// Stage 2: log2 -> clamp -> normalize
		float[] vSafe = applyVec3(v, x -> Math.max(1e-10, x));
		float[] logNorm = applyVec3(vSafe, x -> {
			double l = Math.log(x) / Math.log(2);
			if (l < r.minEv) l = r.minEv;
			if (l > r.maxEv) l = r.maxEv;
			return (l - r.minEv) / (r.maxEv - r.minEv);
		});
		assertVecClose(r.label + " log-normalize", r.logNormalized, logNorm, TOL);

		// Stage 3: sigmoid polynomial
		float[] sigOut = sigmoid(logNorm);
		assertVecClose(r.label + " sigmoid", r.sigmoidOut, sigOut, TOL);

		// Stage 4: punchy
		float[] punchOut = punchy(sigOut, r.sat, r.pow);
		assertVecClose(r.label + " punchy", r.punchyOut, punchOut, TOL);

		// Stage 5: AGX_OUTPUT_MATRIX (pre-clamp)
		float[] outMat = mul(AGX_OUTPUT_COLS, punchOut);
		assertVecClose(r.label + " OUTPUT_MATRIX", r.outputMatrixPreClamp, outMat, TOL);

		// Final: clamp + linearToSrgb
		float[] finalSrgb = ColorUtils.linearToSrgb(applyVec3(outMat, x -> Math.max(0, Math.min(1, x))));
		assertVecClose(r.label + " final sRGB", r.finalSrgb, finalSrgb, TOL);
	}

	// ---------------- Reference pixel sampling from legacy/zone PNGs ----------------

	private static float byteToFloat(int b) {
		return (b & 0xFF) / 255f;
	}

	/** Returns mean RGB over a region of an image, in display sRGB-byte form (0..1). */
	static float[] sampleAverage(BufferedImage img, int x0, int y0, int w, int h) {
		long r = 0, g = 0, bl = 0;
		int n = 0;
		for (int y = y0; y < y0 + h; y++) {
			for (int x = x0; x < x0 + w; x++) {
				int argb = img.getRGB(x, y);
				r += (argb >> 16) & 0xFF;
				g += (argb >> 8) & 0xFF;
				bl += argb & 0xFF;
				n++;
			}
		}
		return new float[] { r / 255f / n, g / 255f / n, bl / 255f / n };
	}

	// Candidate sample location in legacy barrier.png — middle of eye glow (per visual inspection).
	// To verify, the markCandidateLegacySample test writes a marked-up copy.
	static final int LEGACY_SAMPLE_X = 1710;
	static final int LEGACY_SAMPLE_Y = 735;
	static final int SAMPLE_RADIUS = 4; // 9x9 px averaging window

	@Test
	public void markCandidateLegacySample() throws Exception {
		File legacy = new File("legacy barrier.png");
		Assert.assertTrue("legacy barrier.png missing", legacy.exists());
		BufferedImage img = ImageIO.read(legacy);

		float[] avg = sampleAverage(img,
			LEGACY_SAMPLE_X - SAMPLE_RADIUS, LEGACY_SAMPLE_Y - SAMPLE_RADIUS,
			SAMPLE_RADIUS * 2 + 1, SAMPLE_RADIUS * 2 + 1);
		System.out.printf("Sampled legacy barrier.png at (%d, %d), 9x9 mean RGB = (%d, %d, %d) = sRGB (%.4f, %.4f, %.4f)%n",
			LEGACY_SAMPLE_X, LEGACY_SAMPLE_Y,
			Math.round(avg[0] * 255), Math.round(avg[1] * 255), Math.round(avg[2] * 255),
			avg[0], avg[1], avg[2]);

		// Draw a thick magenta crosshair and a large ring around the sample location so it's
		// clearly visible even when the image preview is downscaled.
		BufferedImage marked = new BufferedImage(img.getWidth(), img.getHeight(), BufferedImage.TYPE_INT_RGB);
		marked.getGraphics().drawImage(img, 0, 0, null);
		int cx = LEGACY_SAMPLE_X, cy = LEGACY_SAMPLE_Y;
		// Thick yellow arms ~120 px long (5 px wide)
		for (int d = 6; d <= 120; d++) {
			for (int w = -2; w <= 2; w++) {
				plot(marked, cx + d, cy + w, 0xFFFF00);
				plot(marked, cx - d, cy + w, 0xFFFF00);
				plot(marked, cx + w, cy + d, 0xFFFF00);
				plot(marked, cx + w, cy - d, 0xFFFF00);
			}
		}
		// Cyan ring at radius=SAMPLE_RADIUS to show the actual sampling region
		drawCircle(marked, cx, cy, SAMPLE_RADIUS + 0, 0x00FFFF);
		// Magenta solid filled square at center (5x5) so it's visible
		for (int dx = -2; dx <= 2; dx++)
			for (int dy = -2; dy <= 2; dy++)
				plot(marked, cx + dx, cy + dy, 0xFF00FF);

		File out = new File("legacy barrier - candidate sample.png");
		ImageIO.write(marked, "png", out);
		System.out.printf("Wrote %s%n", out.getAbsolutePath());

		// Also write a 400x400 crop centered on the marker so the small preview is useful.
		int cropSize = 400;
		int x0 = Math.max(0, Math.min(img.getWidth() - cropSize, cx - cropSize / 2));
		int y0 = Math.max(0, Math.min(img.getHeight() - cropSize, cy - cropSize / 2));
		BufferedImage crop = marked.getSubimage(x0, y0, cropSize, cropSize);
		File cropOut = new File("legacy barrier - candidate crop.png");
		ImageIO.write(crop, "png", cropOut);
		System.out.printf("Wrote %s (crop at (%d, %d) size %d)%n", cropOut.getAbsolutePath(), x0, y0, cropSize);
	}

	private static void drawCircle(BufferedImage img, int cx, int cy, int r, int rgb) {
		for (int t = 0; t < 360; t++) {
			double rad = Math.toRadians(t);
			int x = cx + (int) Math.round(Math.cos(rad) * r);
			int y = cy + (int) Math.round(Math.sin(rad) * r);
			plot(img, x, y, rgb);
		}
	}

	private static void plot(BufferedImage img, int x, int y, int rgb) {
		if (x >= 0 && x < img.getWidth() && y >= 0 && y < img.getHeight())
			img.setRGB(x, y, rgb);
	}

	// ---------------- Analysis: legacy target vs current input ----------------

	// Sampled from legacy barrier.png at (1710, 735), 9x9 mean. User-confirmed.
	static final float[] LEGACY_TARGET_SRGB = { 0.8441f, 0.7317f, 0.1878f };

	// From the middle-of-eye probe (ev -10/4, exposure 0.8, sat 1.05, pow 1.35):
	// "tonemap AgX input (linear*exp)" — the post-exposure linear value handed to agxTonemap.
	static final float[] CURRENT_AGX_INPUT = PROBE_MIDDLE_EYE.agxInputLinear;
	static final float EXPOSURE = 0.8f;

	private static float dist(float[] a, float[] b) {
		float dr = a[0] - b[0];
		float dg = a[1] - b[1];
		float db = a[2] - b[2];
		return (float) Math.sqrt(dr * dr + dg * dg + db * db);
	}

	private static String fmt(float[] v) {
		return String.format("(%+.4f, %+.4f, %+.4f)", v[0], v[1], v[2]);
	}

	/** Coordinate-descent over pre-AgX linear input to minimize sRGB distance to a target. */
	private static float[] searchInverse(float[] targetSrgb, float[] start,
										 float minEv, float maxEv, float sat, float pow) {
		float[] best = start.clone();
		float bestDist = dist(agxForwardSrgb(best, minEv, maxEv, sat, pow), targetSrgb);
		float[] steps = { 4f, 1f, 0.3f, 0.1f, 0.03f, 0.01f, 0.003f, 0.001f, 0.0003f };
		for (float step : steps) {
			boolean improved = true;
			int iter = 0;
			while (improved && iter < 2000) {
				improved = false;
				iter++;
				for (int i = 0; i < 3; i++) {
					for (int sign = -1; sign <= 1; sign += 2) {
						float[] candidate = best.clone();
						candidate[i] = Math.max(0, candidate[i] + sign * step);
						float d = dist(agxForwardSrgb(candidate, minEv, maxEv, sat, pow), targetSrgb);
						if (d < bestDist - 1e-7f) {
							bestDist = d;
							best = candidate;
							improved = true;
						}
					}
				}
			}
		}
		return best;
	}

	@Test
	public void analyzeLegacyTargetVsCurrentInput() {
		final float minEv = -10f, maxEv = 4f, sat = 1.05f, pow = 1.35f;

		float[] currentSrgb = agxForwardSrgb(CURRENT_AGX_INPUT, minEv, maxEv, sat, pow);
		Assert.assertEquals("oracle vs probe sRGB R", PROBE_MIDDLE_EYE.finalSrgb[0], currentSrgb[0], 1e-3f);
		Assert.assertEquals("oracle vs probe sRGB G", PROBE_MIDDLE_EYE.finalSrgb[1], currentSrgb[1], 1e-3f);
		Assert.assertEquals("oracle vs probe sRGB B", PROBE_MIDDLE_EYE.finalSrgb[2], currentSrgb[2], 1e-3f);

		System.out.printf("%n=== Middle-of-eye glow: current vs legacy target ===%n");
		System.out.printf("Current pre-AgX linear (post-exposure):  %s%n", fmt(CURRENT_AGX_INPUT));
		System.out.printf("Current HDR scene linear (pre-exposure): %s%n",
			fmt(new float[] { CURRENT_AGX_INPUT[0] / EXPOSURE, CURRENT_AGX_INPUT[1] / EXPOSURE, CURRENT_AGX_INPUT[2] / EXPOSURE }));
		System.out.printf("Current display sRGB:                    %s%n", fmt(currentSrgb));
		System.out.printf("Legacy target display sRGB:              %s%n", fmt(LEGACY_TARGET_SRGB));
		System.out.printf("Current vs target sRGB delta:            %s  (||.||=%.4f)%n",
			fmt(new float[] {
				LEGACY_TARGET_SRGB[0] - currentSrgb[0],
				LEGACY_TARGET_SRGB[1] - currentSrgb[1],
				LEGACY_TARGET_SRGB[2] - currentSrgb[2]
			}),
			dist(currentSrgb, LEGACY_TARGET_SRGB));

		float[] best = searchInverse(LEGACY_TARGET_SRGB, CURRENT_AGX_INPUT, minEv, maxEv, sat, pow);
		float[] bestSrgb = agxForwardSrgb(best, minEv, maxEv, sat, pow);
		System.out.printf("%n--- Closest reachable AgX input to target (coordinate-descent search) ---%n");
		System.out.printf("Search result pre-AgX linear:            %s%n", fmt(best));
		System.out.printf("Search result HDR scene linear:          %s%n",
			fmt(new float[] { best[0] / EXPOSURE, best[1] / EXPOSURE, best[2] / EXPOSURE }));
		System.out.printf("AgX output for search result:            %s%n", fmt(bestSrgb));
		System.out.printf("Residual sRGB error from target:         ||.||=%.4f%n", dist(bestSrgb, LEGACY_TARGET_SRGB));

		System.out.printf("%n--- Required input shift to hit target ---%n");
		System.out.printf("Pre-AgX linear delta (best - current):   %s%n",
			fmt(new float[] { best[0] - CURRENT_AGX_INPUT[0], best[1] - CURRENT_AGX_INPUT[1], best[2] - CURRENT_AGX_INPUT[2] }));
		System.out.printf("Per-channel ratio (best / current):      (%.3fx, %.3fx, %.3fx)%n",
			best[0] / Math.max(CURRENT_AGX_INPUT[0], 1e-6),
			best[1] / Math.max(CURRENT_AGX_INPUT[1], 1e-6),
			best[2] / Math.max(CURRENT_AGX_INPUT[2], 1e-6));
	}

	/**
	 * Candidate compensation that the MRT plan will apply per-pixel in tonemap_frag:
	 *   linear += (linear - luma) * boost
	 *   linear = max(linear, 0)
	 * Returns the post-compensation pre-AgX linear.
	 */
	private static float[] saturationBoost(float[] linear, float boost) {
		float luma = 0.2126f * linear[0] + 0.7152f * linear[1] + 0.0722f * linear[2];
		float r = Math.max(0, linear[0] + (linear[0] - luma) * boost);
		float g = Math.max(0, linear[1] + (linear[1] - luma) * boost);
		float b = Math.max(0, linear[2] + (linear[2] - luma) * boost);
		return new float[] { r, g, b };
	}

	@Test
	public void evaluateSaturationBoostCandidate() {
		final float minEv = -10f, maxEv = 4f, sat = 1.05f, pow = 1.35f;
		System.out.printf("%n=== Saturation-boost sweep on middle-of-eye AgX input ===%n");
		System.out.printf("Starting pre-AgX linear: %s%n", fmt(CURRENT_AGX_INPUT));
		System.out.printf("Legacy target sRGB:      %s%n", fmt(LEGACY_TARGET_SRGB));
		System.out.printf("%n%-6s  %-30s  %-30s  %-8s%n", "boost", "post-boost pre-AgX linear", "AgX output sRGB", "err");

		float[] bests = { Float.MAX_VALUE };
		float bestBoost = 0;
		float[] bestSrgb = null;
		float[] bestLinear = null;
		for (float boost = 0; boost <= 4f; boost += 0.25f) {
			float[] boosted = saturationBoost(CURRENT_AGX_INPUT, boost);
			float[] outSrgb = agxForwardSrgb(boosted, minEv, maxEv, sat, pow);
			float err = dist(outSrgb, LEGACY_TARGET_SRGB);
			System.out.printf("%-6.2f  %-30s  %-30s  %.4f%n", boost, fmt(boosted), fmt(outSrgb), err);
			if (err < bests[0]) {
				bests[0] = err;
				bestBoost = boost;
				bestSrgb = outSrgb;
				bestLinear = boosted;
			}
		}
		System.out.printf("%nBest sat-boost in sweep: %.2f  →  pre-AgX %s  →  display %s  err=%.4f%n",
			bestBoost, fmt(bestLinear), fmt(bestSrgb), bests[0]);

		// Compare to the unconstrained-search best
		float[] unconstrained = searchInverse(LEGACY_TARGET_SRGB, CURRENT_AGX_INPUT, minEv, maxEv, sat, pow);
		float[] unconstrainedSrgb = agxForwardSrgb(unconstrained, minEv, maxEv, sat, pow);
		System.out.printf("Unconstrained-search best: pre-AgX %s  →  display %s  err=%.4f%n",
			fmt(unconstrained), fmt(unconstrainedSrgb), dist(unconstrainedSrgb, LEGACY_TARGET_SRGB));
	}

	/**
	 * Alternate compensation: attenuate the channel(s) below luma (zero them out) and lift
	 * R/G uniformly. More general than pure saturation boost.
	 *   below_luma channels: linear[i] *= (1 - tag * vibrance)  (so vibrance=1 removes them)
	 *   above_luma channels: linear[i] *= (1 + tag * vibrance * lift)
	 */
	private static float[] subLumaAttenuationLift(float[] linear, float vibrance, float lift) {
		float luma = 0.2126f * linear[0] + 0.7152f * linear[1] + 0.0722f * linear[2];
		float[] out = new float[3];
		for (int i = 0; i < 3; i++) {
			if (linear[i] < luma) {
				out[i] = Math.max(0, linear[i] * (1 - vibrance));
			} else {
				out[i] = linear[i] * (1 + vibrance * lift);
			}
		}
		return out;
	}

	@Test
	public void evaluateSubLumaAttenuationLift() {
		final float minEv = -10f, maxEv = 4f, sat = 1.05f, pow = 1.35f;
		System.out.printf("%n=== Sub-luma attenuation + above-luma lift sweep ===%n");
		System.out.printf("Starting pre-AgX linear: %s%n", fmt(CURRENT_AGX_INPUT));
		System.out.printf("Legacy target sRGB:      %s%n", fmt(LEGACY_TARGET_SRGB));
		System.out.printf("%n%-8s %-8s  %-30s  %-30s  %-8s%n", "vibrance", "lift", "post pre-AgX linear", "AgX output sRGB", "err");

		float bestErr = Float.MAX_VALUE;
		float bestV = 0, bestL = 0;
		float[] bestSrgb = null;
		float[] bestPre = null;
		for (float v = 0; v <= 1.01f; v += 0.25f) {
			for (float lift = 0; lift <= 1.01f; lift += 0.1f) {
				float[] modded = subLumaAttenuationLift(CURRENT_AGX_INPUT, v, lift);
				float[] outSrgb = agxForwardSrgb(modded, minEv, maxEv, sat, pow);
				float err = dist(outSrgb, LEGACY_TARGET_SRGB);
				if (err < bestErr) {
					bestErr = err;
					bestV = v;
					bestL = lift;
					bestSrgb = outSrgb;
					bestPre = modded;
				}
			}
		}
		System.out.printf("Best in 2D sweep: vibrance=%.2f lift=%.2f  →  pre-AgX %s  →  display %s  err=%.4f%n",
			bestV, bestL, fmt(bestPre), fmt(bestSrgb), bestErr);

		// Also try vibrance=1 with finer lift sweep for the recommended setting
		System.out.printf("%n%-6s  %-30s  %-30s  %-8s%n", "lift", "post pre-AgX linear", "AgX output sRGB", "err");
		for (float lift = 0; lift <= 1.01f; lift += 0.1f) {
			float[] modded = subLumaAttenuationLift(CURRENT_AGX_INPUT, 1f, lift);
			float[] outSrgb = agxForwardSrgb(modded, minEv, maxEv, sat, pow);
			float err = dist(outSrgb, LEGACY_TARGET_SRGB);
			System.out.printf("%-6.2f  %-30s  %-30s  %.4f%n", lift, fmt(modded), fmt(outSrgb), err);
		}
	}
}
