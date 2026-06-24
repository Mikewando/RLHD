/*
 * Color utility functions
 * Written in 2023 by Hooder <ahooder@protonmail.com>
 * To the extent possible under law, the author(s) have dedicated all copyright and related and neighboring rights
 * to this software to the public domain worldwide. This software is distributed without any warranty.
 * You should have received a copy of the CC0 Public Domain Dedication along with this software.
 * If not, see <http://creativecommons.org/publicdomain/zero/1.0/>.
 */
package rs117.hd.utils;

import com.google.gson.stream.JsonReader;
import com.google.gson.stream.JsonToken;
import com.google.gson.stream.JsonWriter;
import java.awt.Color;
import java.io.IOException;
import java.util.Arrays;
import lombok.extern.slf4j.Slf4j;
import rs117.hd.utils.GsonUtils.DelegateFloatAdapter;

import static rs117.hd.utils.MathUtils.*;

public class ColorUtils {
	private static final float EPS = 1e-4f;

	/**
	 * Row-major transformation matrices for conversion between RGB and XYZ color spaces.
	 * Fairman, H. S., Brill, M. H., & Hemmendinger, H. (1997).
	 * How the CIE 1931 color-matching functions were derived from Wright-Guild data.
	 * Color Research & Application, 22(1), 11–23.
	 * doi:10.1002/(sici)1520-6378(199702)22:1<11::aid-col4>3.0.co;2-7
	 */
	private static final float[] RGB_TO_XYZ_MATRIX = {
		.49f, .31f, .2f,
		.1769f, .8124f, .0107f,
		.0f,    .0099f, .9901f
	};
	private static final float[] XYZ_TO_RGB_MATRIX = {
		2.36449f,    -.896553f,  -.467937f,
		-.514935f,   1.42633f,    .0886025f,
		 .00514883f, -.0142619f, 1.00911f
	};

	/**
	 * Approximate UV coordinates in the CIE 1960 UCS color space from a color temperature specified in degrees Kelvin.
	 * @param kelvin temperature in degrees Kelvin. Valid from 1000 to 15000.
	 * @see <a href="https://doi.org/10.1002/col.5080100109">
	 *     Krystek, M. (1985). An algorithm to calculate correlated colour temperature.
	 *     Color Research & Application, 10(1), 38–40. doi:10.1002/col.5080100109
	 * </a>
	 * @return UV coordinates in the UCS color space
	 */
	public static float[] colorTemperatureToLinearRgb(double kelvin) {
		// UV coordinates in CIE 1960 UCS color space
		double[] uv = new double[] {
			(0.860117757 + 1.54118254e-4 * kelvin + 1.28641212e-7 * kelvin * kelvin)
				/ (1 + 8.42420235e-4 * kelvin + 7.08145163e-7 * kelvin * kelvin),
			(0.317398726 + 4.22806245e-5 * kelvin + 4.20481691e-8 * kelvin * kelvin)
				/ (1 - 2.89741816e-5 * kelvin + 1.61456053e-7 * kelvin * kelvin)
		};

		// xy coordinates in CIES 1931 xyY space
		double divisor = 2 * uv[0] - 8 * uv[1] + 4;
		double[] xy = new double[] { 3 * uv[0] / divisor,  2 * uv[1] / divisor };

		// CIE XYZ space
		float Y = 1;
		float[] XYZ = { (float) (xy[0] * Y / xy[1]), Y, (float) ((1 - xy[0] - xy[1]) * Y / xy[1]) };

		return XYZtoRGB(XYZ);
	}

	/**
	 * Transform from CIE 1931 XYZ color space to linear RGB.
	 * @param XYZ coordinates
	 * @return linear RGB coordinates
	 */
	public static float[] XYZtoRGB(float[] XYZ) {
		float[] RGB = new float[3];
		mat3MulVec3(RGB, XYZ_TO_RGB_MATRIX, XYZ);
		return RGB;
	}

	/**
	 * Transform from linear RGB to CIE 1931 XYZ color space.
	 * @param RGB linear RGB color coordinates
	 * @return XYZ color coordinates
	 */
	public static float[] RGBtoXYZ(float[] RGB) {
		float[] XYZ = new float[3];
		mat3MulVec3(XYZ, RGB_TO_XYZ_MATRIX, RGB);
		return XYZ;
	}

	private static void mat3MulVec3(float[] out, float[] m, float[] v) {
		out[0] = m[0] * v[0] + m[1] * v[1] + m[2] * v[2];
		out[1] = m[3] * v[0] + m[4] * v[1] + m[5] * v[2];
		out[2] = m[6] * v[0] + m[7] * v[1] + m[8] * v[2];
	}

	// Conversion functions to and from sRGB and linear color space.
	// The implementation is based on the sRGB EOTF given in the Khronos Data Format Specification.
	// Source: https://web.archive.org/web/20220808015852/https://registry.khronos.org/DataFormat/specs/1.3/dataformat.1.3.pdf
	// Page number 130 (146 in the PDF)
	public static float linearToSrgb(float c) {
		return c <= 0.0031308f ?
			c * 12.92f :
			1.055f * pow(c, 1 / 2.4f) - 0.055f;
	}

	public static float srgbToLinear(float c) {
		return c <= 0.04045f ?
			c / 12.92f :
			pow((c + 0.055f) / 1.055f, 2.4f);
	}

	public static float[] linearToSrgb(float... c) {
		float[] result = new float[c.length];
		for (int i = 0; i < c.length; i++)
			result[i] = linearToSrgb(c[i]);
		return result;
	}

	public static float[] srgbToLinear(float... c) {
		float[] result = new float[c.length];
		for (int i = 0; i < c.length; i++)
			result[i] = srgbToLinear(c[i]);
		return result;
	}

	// OKLab conversion. Björn Ottosson's canonical matrices.
	// Reference: https://bottosson.github.io/posts/oklab/
	public static float[] linearToOklab(float[] c) {
		float l = 0.4122214708f * c[0] + 0.5363325363f * c[1] + 0.0514459929f * c[2];
		float m = 0.2119034982f * c[0] + 0.6806995451f * c[1] + 0.1073969566f * c[2];
		float s = 0.0883024619f * c[0] + 0.2817188376f * c[1] + 0.6299787005f * c[2];
		float l_ = Math.signum(l) * (float) Math.cbrt(Math.abs(l));
		float m_ = Math.signum(m) * (float) Math.cbrt(Math.abs(m));
		float s_ = Math.signum(s) * (float) Math.cbrt(Math.abs(s));
		return new float[] {
			0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_,
			1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_,
			0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_
		};
	}

	public static float[] oklabToLinear(float[] c) {
		float l_ = c[0] + 0.3963377774f * c[1] + 0.2158037573f * c[2];
		float m_ = c[0] - 0.1055613458f * c[1] - 0.0638541728f * c[2];
		float s_ = c[0] - 0.0894841775f * c[1] - 1.2914855480f * c[2];
		float l = l_ * l_ * l_;
		float m = m_ * m_ * m_;
		float s = s_ * s_ * s_;
		return new float[] {
			+4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s,
			-1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s,
			-0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s
		};
	}

	// AgX matrices — keep in sync with utils/tonemap.glsl.
	// (Stored row-major as 3 vec3 rows for clarity; helper does row × col mul.)
	private static final float[][] AGX_INPUT_MATRIX_ROWS = {
		{ 0.842479062253094f, 0.0423282422610123f, 0.0423756549057051f },
		{ 0.0784335999999992f, 0.878468636469772f, 0.0784336f },
		{ 0.0792237451477643f, 0.0791661274605434f, 0.879142973793104f }
	};
	private static final float[][] AGX_OUTPUT_MATRIX_ROWS = {
		{ 1.19687900512017f, -0.0980208811401368f, -0.0990297440797205f },
		{ -0.0528968517574562f, 1.15190312990417f, -0.0989611768448433f },
		{ -0.0529716355144438f, -0.0980434501171241f, 1.15107367264116f }
	};

	private static float[] agxMat3MulVec(float[][] rows, float[] v) {
		return new float[] {
			rows[0][0] * v[0] + rows[0][1] * v[1] + rows[0][2] * v[2],
			rows[1][0] * v[0] + rows[1][1] * v[1] + rows[1][2] * v[2],
			rows[2][0] * v[0] + rows[2][1] * v[1] + rows[2][2] * v[2]
		};
	}

	// AgX sigmoid polynomial — same coefficients as utils/tonemap.glsl.
	private static float agxSigmoid(float x) {
		float x2 = x * x;
		float x4 = x2 * x2;
		return 15.5f * x4 * x2
			- 40.14f * x4 * x
			+ 31.96f * x4
			- 6.868f * x2 * x
			+ 0.4298f * x2
			+ 0.1191f * x
			- 0.00232f;
	}

	// Numerical inverse of the AgX sigmoid via bisection.
	private static float inverseAgxSigmoid(float target) {
		float lo = 0, hi = 1;
		for (int i = 0; i < 32; i++) {
			float mid = (lo + hi) * 0.5f;
			if (agxSigmoid(mid) < target) lo = mid; else hi = mid;
		}
		return (lo + hi) * 0.5f;
	}

	/**
	 * Compute the HDR scene value (pre-exposure) that, when passed through the
	 * AgX tonemap with the given EV range, exposure, and punchy parameters,
	 * displays approximately as the given target linear color. Inverse follows:
	 *   v = INPUT_MATRIX * target → invPunchy → invSigmoid per channel →
	 *   denormalize → 2^ → scene = OUTPUT_MATRIX * v → clamp ≥0 → /exposure.
	 *
	 * The clamp at the end is because AgX's gamut after the matrix dance can
	 * require negative scene-RGB to hit highly saturated targets, but AgX's
	 * own max(hdr, 0) discards negatives — so we can't actually hit those.
	 * The returned value is the closest achievable in the non-negative gamut;
	 * the actual displayed sky may be slightly desaturated vs. the target.
	 */
	public static float[] agxInverseToHdrInput(
		float[] targetDisplayLinear,
		float minEv,
		float maxEv,
		float exposure,
		float punchSaturation,
		float punchPower
	) {
		float[] v = agxMat3MulVec(AGX_INPUT_MATRIX_ROWS, targetDisplayLinear);
		v = inverseAgxLookPunchy(v, punchSaturation, punchPower);
		for (int i = 0; i < 3; i++) {
			float sigIn = inverseAgxSigmoid(v[i]);
			float logVal = minEv + sigIn * (maxEv - minEv);
			v[i] = (float) Math.pow(2, logVal);
		}
		float[] scene = agxMat3MulVec(AGX_OUTPUT_MATRIX_ROWS, v);
		float invExp = 1f / Math.max(exposure, 1e-6f);
		for (int i = 0; i < 3; i++) scene[i] = Math.max(scene[i], 0f) * invExp;
		return scene;
	}

	// Inverse of agxLookPunchy. Forward per channel:
	//   out_i = (1 - sat) * luma_in + sat * max(ldr_i, 0)^power
	// where luma_in = dot(ldr, lw). Luma couples the channels, so iterate:
	// guess L = luma, solve each channel, recompute L. Converges in a few
	// passes for the slider ranges we expose (sat 0–2, power 0.5–2).
	private static float[] inverseAgxLookPunchy(float[] out, float sat, float power) {
		if (sat < 1e-3f) {
			// Forward collapses to a neutral grey, inverse is underdetermined.
			return new float[] { out[0], out[1], out[2] };
		}
		float invPow = 1f / power;
		float oneMinusSat = 1f - sat;
		float lwR = 0.2126f, lwG = 0.7152f, lwB = 0.0722f;
		float[] ldr = { out[0], out[1], out[2] };
		float L = lwR * ldr[0] + lwG * ldr[1] + lwB * ldr[2];
		for (int iter = 0; iter < 8; iter++) {
			float c = oneMinusSat * L;
			for (int i = 0; i < 3; i++) {
				float t = (out[i] - c) / sat;
				if (t < 0) t = 0;
				ldr[i] = (float) Math.pow(t, invPow);
			}
			L = lwR * ldr[0] + lwG * ldr[1] + lwB * ldr[2];
		}
		return ldr;
	}

	/**
	 * Convert sRGB in the range 0-1 to HSL in the range 0-1.
	 *
	 * @param srgb float[3]
	 * @return hsl float[3]
	 * @link <a href="https://web.archive.org/web/20230619214343/https://en.wikipedia.org/wiki/HSL_and_HSV#Color_conversion_formulae">Wikipedia: HSL and HSV</a>
	 */
	public static float[] srgbToHsl(float[] srgb) {
		float V = max(srgb);
		float X_min = min(srgb);
		float C = V - X_min;

		float H = 0;
		if (C > 0) {
			if (V == srgb[0]) {
				H = mod((srgb[1] - srgb[2]) / C, 6);
			} else if (V == srgb[1]) {
				H = (srgb[2] - srgb[0]) / C + 2;
			} else {
				H = (srgb[0] - srgb[1]) / C + 4;
			}
			assert H >= 0 && H <= 6;
		}

		float L = (V + X_min) / 2;
		float divisor = 1 - abs(2 * L - 1);
		float S_L = abs(divisor) < EPS ? 0 : C / divisor;
		return new float[] { H / 6, S_L, L };
	}

	/**
	 * Convert HSL in the range 0-1 to sRGB in the range 0-1.
	 *
	 * @param hsl float[3]
	 * @return srgb float[3]
	 * @link <a href="https://web.archive.org/web/20230619214343/https://en.wikipedia.org/wiki/HSL_and_HSV#Color_conversion_formulae">Wikipedia: HSL and HSV</a>
	 */
	public static float[] hslToSrgb(float[] hsl) {
		float C = hsl[1] * (1 - abs(2 * hsl[2] - 1));
		float H_prime = fract(hsl[0]) * 6;
		float m = hsl[2] - C / 2;

		float r = clamp(abs(H_prime - 3) - 1, 0, 1) * C + m;
		float g = clamp(2 - abs(H_prime - 2), 0, 1) * C + m;
		float b = clamp(2 - abs(H_prime - 4), 0, 1) * C + m;
		return new float[] { r, g, b };
	}

	/**
	 * Convert HSL in the range 0-1 to HSV in the range 0-1.
	 *
	 * @param hsl float[3]
	 * @return hsv float[3]
	 */
	public static float[] hslToHsv(float[] hsl) {
		float v = hsl[2] + hsl[1] * min(hsl[2], 1 - hsl[2]);
		return vec(hsl[0], abs(v) < EPS ? 0 : 2 * (1 - hsl[2] / v), v);
	}

	/**
	 * Convert HSV in the range 0-1 to HSL in the range 0-1.
	 *
	 * @param hsv float[3]
	 * @return hsl float[3]
	 */
	public static float[] hsvToHsl(float[] hsv) {
		float l = hsv[2] * (1 - hsv[1] / 2);
		float divisor = min(l, 1 - l);
		return vec(hsv[0], abs(divisor) < EPS ? 0 : (hsv[2] - l) / divisor, l);
	}

	/**
	 * Convert sRGB in the range 0-1 from sRGB to HSV (also known as HSB) in the range 0-1.
	 *
	 * @param srgb float[3]
	 * @return hsv float[3]
	 * @link <a href="https://web.archive.org/web/20230619214343/https://en.wikipedia.org/wiki/HSL_and_HSV#Color_conversion_formulae">Wikipedia: HSL and HSV</a>
	 */
	public static float[] srgbToHsv(float[] srgb) {
		return hslToHsv(srgbToHsl(srgb));
	}

	/**
	 * Convert HSV (also known as HSB) in the range 0-1 to sRGB in the range 0-1.
	 *
	 * @param hsv float[3]
	 * @return srgb float[3]
	 * @link <a href="https://web.archive.org/web/20230619214343/https://en.wikipedia.org/wiki/HSL_and_HSV#Color_conversion_formulae">Wikipedia: HSL and HSV</a>
	 */
	public static float[] hsvToSrgb(float[] hsv) {
		return hslToSrgb(hsvToHsl(hsv));
	}

	// Convenience functions for converting different formats into linear RGB, sRGB or packed HSL

	/**
	 * Convert red, green and blue in the range 0-255 from sRGB to linear RGB in the range 0-1.
	 *
	 * @param r red color
	 * @param g green color
	 * @param b blue color
	 * @return float[3] linear rgb values from 0-1
	 */
	public static float[] rgb(float r, float g, float b) {
		return srgbToLinear(srgb(r, g, b));
	}

	/**
	 * Convert hex color from sRGB to linear RGB in the range 0-1.
	 *
	 * @param hex RGB hex color
	 * @return float[3] linear rgb values from 0-1
	 */
	public static float[] rgb(String hex) {
		return srgbToLinear(srgb(hex));
	}

	/**
	 * Convert sRGB color packed as an int to linear RGB in the range 0-1.
	 *
	 * @param srgb packed sRGB
	 * @return float[3] linear rgb values from 0-1
	 */
	public static float[] rgb(int srgb) {
		return srgbToLinear(srgb(srgb));
	}

	/**
	 * Convert red, green and blue in the range 0-255 from sRGB to sRGB in the range 0-1.
	 *
	 * @param r red color
	 * @param g green color
	 * @param b blue color
	 * @return float[3] non-linear sRGB values from 0-1
	 */
	public static float[] srgb(float r, float g, float b) {
		return new float[] { r / 255f, g / 255f, b / 255f };
	}

	/**
	 * Convert hex color from sRGB to sRGB in the range 0-1.
	 *
	 * @param hex RGB hex color
	 * @return float[3] non-linear sRGB values from 0-1
	 */
	public static float[] srgb(String hex) {
		Color color = Color.decode(hex);
		return srgb(color.getRed(), color.getGreen(), color.getBlue());
	}

	/**
	 * Convert sRGB color packed as an int to sRGB in the range 0-1.
	 *
	 * @param srgb packed sRGB
	 * @return float[3] non-linear sRGB values from 0-1
	 */
	public static float[] srgb(int srgb) {
		return new float[] {
			(srgb >> 16 & 0xFF) / (float) 0xFF,
			(srgb >> 8 & 0xFF) / (float) 0xFF,
			(srgb & 0xFF) / (float) 0xFF,
		};
	}

	public static float[] srgb(Color c) {
		return srgb(c.getRed(), c.getGreen(), c.getBlue());
	}

	/**
	 * Convert alpha and sRGB color packed in an int as ARGB to sRGB in the range 0-1.
	 *
	 * @param alphaSrgb packed sRGB with a preceding alpha channel
	 * @return float[4] non-linear sRGB and alpha in the range 0-1
	 */
	public static float[] srgba(int alphaSrgb) {
		return new float[] {
			(alphaSrgb >> 16 & 0xFF) / (float) 0xFF,
			(alphaSrgb >> 8 & 0xFF) / (float) 0xFF,
			(alphaSrgb & 0xFF) / (float) 0xFF,
			(alphaSrgb >> 24 & 0xFF) / (float) 0xFF
		};
	}

	/**
	 * Convert red, green and blue in the range 0-255 from sRGB to packed HSL.
	 *
	 * @param r red color
	 * @param g green color
	 * @param b blue color
	 * @return int packed HSL
	 */
	public static int hsl(float r, float g, float b) {
		return srgbToPackedHsl(srgb(r, g, b));
	}

	/**
	 * Convert hex color from sRGB to packed HSL.
	 *
	 * @param rgbHex RGB hex color
	 * @return int packed HSL
	 */
	public static int hsl(String rgbHex) {
		return srgbToPackedHsl(srgb(rgbHex));
	}

	/**
	 * Convert sRGB color packed as an int to packed HSL.
	 *
	 * @param packedSrgb RGB hex color
	 * @return int packed HSL
	 */
	public static int hsl(int packedSrgb) {
		return srgbToPackedHsl(srgb(packedSrgb));
	}

	// Integer packing and unpacking functions

	public static int packRawRgb(int... rgb) {
		return rgb[0] << 16 | rgb[1] << 8 | rgb[2];
	}

	public static int packSrgb(float[] srgb) {
		return packRawRgb(ivec(multiply(saturate(srgb), 0xFF)));
	}

	public static int packRawHsl(int... hsl) {
		return hsl[0] << 10 | hsl[1] << 7 | hsl[2];
	}

	public static void unpackRawHsl(int[] out, int hsl) {
		// 6-bit hue | 3-bit saturation | 7-bit lightness
		out[0] = hsl >>> 10 & 0x3F;
		out[1] = hsl >>> 7 & 0x7;
		out[2] = hsl & 0x7F;
	}

	public static int[] unpackRawHsl(int hsl) {
		int[] out = new int[3];
		unpackRawHsl(out, hsl);
		return out;
	}

	public static int packHsl(float... hsl) {
		int H = clamp(round((hsl[0] - .0078125f) * (0x3F + 1)), 0, 0x3F);
		int S = clamp(round((hsl[1] - .0625f) * (0x7 + 1)), 0, 0x7);
		int L = clamp(round(hsl[2] * (0x7F + 1)), 0, 0x7F);
		return packRawHsl(H, S, L);
	}

	public static float[] unpackHsl(int hsl) {
		// 6-bit hue | 3-bit saturation | 7-bit lightness
		float H = (hsl >>> 10 & 0x3F) / (0x3F + 1f) + .0078125f;
		float S = (hsl >>> 7 & 0x7) / (0x7 + 1f) + .0625f;
		float L = (hsl & 0x7F) / (0x7F + 1f);
		return new float[] { H, S, L };
	}

	public static int srgbToPackedHsl(float[] srgb) {
		return packHsl(srgbToHsl(srgb));
	}

	public static float[] packedHslToSrgb(int packedHsl) {
		return hslToSrgb(unpackHsl(packedHsl));
	}

	public static int linearRgbToPackedHsl(float[] linearRgb) {
		return srgbToPackedHsl(linearToSrgb(linearRgb));
	}

	public static float[] packedHslToLinearRgb(int hsl) {
		return srgbToLinear(packedHslToSrgb(hsl));
	}

	public static String srgbToHex(float... srgb) {
		return String.format("#%06x", packSrgb(srgb));
	}

	public static String rgbToHex(float... linearRgb) {
		return srgbToHex(linearToSrgb(linearRgb));
	}

	@Slf4j
	public static class SrgbAdapter extends DelegateFloatAdapter<float[]> {
		@Override
		public float[] read(JsonReader in) throws IOException {
			var token = in.peek();
			if (token == JsonToken.STRING)
				return ColorUtils.srgb(in.nextString());

			if (token != JsonToken.BEGIN_ARRAY)
				throw new IOException("Expected hex color code or array of color channels at " + GsonUtils.location(in));

			in.beginArray();
			float[] rgba = { 0, 0, 0, 1 };
			int i = 0;
			while (in.hasNext() && in.peek() != JsonToken.END_ARRAY) {
				if (in.peek() == JsonToken.NULL) {
					log.warn("Skipping null value in color array at {}", GsonUtils.location(in));
					in.skipValue();
					continue;
				}

				if (in.peek() == JsonToken.NUMBER) {
					if (i > 3) {
						log.warn("Skipping extra elements in color array at {}", GsonUtils.location(in));
						break;
					}

					rgba[i++] = FLOAT_ADAPTER.read(in);
					continue;
				}

				throw new IOException("Unexpected type in color array: " + in.peek() + " at " + GsonUtils.location(in));
			}
			in.endArray();

			if (i < 3)
				throw new IOException("Too few elements in color array: " + i + " at " + GsonUtils.location(in));

			for (int j = 0; j < i; j++)
				rgba[j] /= 255;

			if (i == 4)
				return rgba;

			return slice(rgba, 0, 3);
		}

		@Override
		public void write(JsonWriter out, float[] src) throws IOException {
			if (src == null || src.length == 0) {
				out.nullValue();
				return;
			}

			if (src.length != 3 && src.length != 4)
				throw new IOException("The number of components must be 3 or 4 in a color array. Got " + Arrays.toString(src));

			float[] rgba = { 0, 0, 0, 1 };
			int[] rgbaInt = { 0, 0, 0, 255 };
			for (int i = 0; i < src.length; i++)
				rgba[i] = src[i] * 255;

			// See if it can fit in a hex color code
			boolean canfit = true;
			for (int i = 0; i < src.length; i++) {
				float f = rgba[i];
				rgbaInt[i] = round(f);
				if (abs(f - rgbaInt[i]) > EPS) {
					canfit = false;
					break;
				}
			}

			if (canfit) {
				// Serialize it as a hex color code
				if (src.length == 3) {
					out.value(String.format("#%02x%02x%02x", rgbaInt[0], rgbaInt[1], rgbaInt[2]));
				} else {
					out.value(String.format("#%02x%02x%02x%02x", rgbaInt[0], rgbaInt[1], rgbaInt[2], rgbaInt[3]));
				}
			} else {
				out.beginArray();
				for (int i = 0; i < src.length; i++)
					FLOAT_ADAPTER.write(out, rgba[i]);
				out.endArray();
			}
		}
	}

	@Slf4j
	public static class SrgbToLinearAdapter extends SrgbAdapter {
		@Override
		public float[] read(JsonReader in) throws IOException {
			return srgbToLinear(super.read(in));
		}

		@Override
		public void write(JsonWriter out, float[] src) throws IOException {
			super.write(out, linearToSrgb(src));
		}
	}

	public static class LinearAdapter extends DelegateFloatAdapter<Float> {
		@Override
		public Float read(JsonReader in) throws IOException {
			var value = FLOAT_ADAPTER.read(in);
			return value == null ? null : srgbToLinear(value);
		}

		@Override
		public void write(JsonWriter out, Float value) throws IOException {
			FLOAT_ADAPTER.write(out, value == null ? null : linearToSrgb(value));
		}
	}
}
