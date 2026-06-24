package rs117.hd.utils;

import java.awt.image.BufferedImage;
import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import javax.imageio.ImageIO;
import lombok.extern.slf4j.Slf4j;
import org.lwjgl.BufferUtils;

import static org.lwjgl.opengl.GL43C.*;

@Slf4j
public class DebugProbe {
	public static final int SSBO_BINDING = 10;
	public static final int SLOT_COUNT = 96;
	// Buffer layout: vec4[SLOT_COUNT] then uint sceneFragHits. std430 pads the trailing
	// uint up to vec4 alignment, so total size is SLOT_COUNT*16 + 16 bytes.
	private static final int BYTES = SLOT_COUNT * 4 * Float.BYTES + 16;
	private static final int COUNTER_OFFSET = SLOT_COUNT * 4 * Float.BYTES;
	private static final int STACK_BASE_SLOT = 24;
	private static final int STACK_MAX_ENTRIES = 24;

	private int ssboId = 0;
	// armNextFrame is written from the AWT thread (keybind) and read from the render thread.
	// To avoid the race where it flips between the UBO upload and the SSBO bind in the same
	// frame, we snapshot it once at the start of each render frame via beginFrame() and use
	// the snapshot for the whole frame.
	private volatile boolean armNextFrame = false;
	private boolean armedThisFrame = false;
	private int[] sceneProbe = { -1, -1 };
	private int[] tonemapProbe = { -1, -1 };

	/** Toggle for the live cursor crosshair drawn into the framebuffer by tonemap_frag. */
	public static volatile boolean showCursorMarker = false;
	/** Last-computed tonemap-FB pixel for the cursor; updated each frame when showCursorMarker is on. */
	public static final int[] cursorTonemapPixel = { -1, -1 };

	/**
	 * Map a canvas-space cursor coord to (sceneFB pixel, tonemapFB pixel) in GL bottom-left origin.
	 * Returns [sceneX, sceneY, tmX, tmY] or null if state isn't ready or cursor invalid.
	 * Logs each call when {@code verbose} is true so we can correlate Java's view with shader hits.
	 */
	public static int[] mapCursorToProbePixels(
		int cursorX, int cursorY, int canvasW, int canvasH,
		int[] awt, int[] sceneViewport, int[] sceneResolution, boolean verbose
	) {
		if (cursorX < 0 || cursorY < 0 || canvasW <= 0 || canvasH <= 0
			|| awt == null || awt[0] <= 0 || awt[1] <= 0
			|| sceneViewport == null || sceneResolution == null
		) {
			return null;
		}
		int awtX = (int) Math.round(cursorX * (double) awt[0] / canvasW);
		int awtYTL = (int) Math.round(cursorY * (double) awt[1] / canvasH);
		int awtY = awt[1] - awtYTL; // GL bottom-left
		int tmX = awtX;
		int tmY = awtY;
		int vpRelX = awtX - sceneViewport[0];
		int vpRelY = awtY - sceneViewport[1];
		int sceneX = (int) Math.round(vpRelX * (double) sceneResolution[0] / sceneViewport[2]);
		int sceneY = (int) Math.round(vpRelY * (double) sceneResolution[1] / sceneViewport[3]);
		if (verbose) {
			log.info(
				"[probe] cursor=({}, {})  canvas={}x{}  awtFB={}x{}  vp=[{}, {}, {}, {}]  sr={}x{}"
					+ "  ->  awt=({}, {})  awtY_topLeft={}  sceneRel=({}, {})  scene=({}, {})  tonemap=({}, {})",
				cursorX, cursorY, canvasW, canvasH, awt[0], awt[1],
				sceneViewport[0], sceneViewport[1], sceneViewport[2], sceneViewport[3],
				sceneResolution[0], sceneResolution[1],
				awtX, awtY, awtYTL, vpRelX, vpRelY, sceneX, sceneY, tmX, tmY);
		}
		return new int[] { sceneX, sceneY, tmX, tmY };
	}

	public void initialize() {
		ssboId = glGenBuffers();
		glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssboId);
		glBufferData(GL_SHADER_STORAGE_BUFFER, BYTES, GL_DYNAMIC_DRAW);
		glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
	}

	public void destroy() {
		if (ssboId != 0) {
			glDeleteBuffers(ssboId);
			ssboId = 0;
		}
	}

	public void arm(int sceneX, int sceneY, int tonemapX, int tonemapY) {
		armNextFrame = true;
		sceneProbe[0] = sceneX;
		sceneProbe[1] = sceneY;
		tonemapProbe[0] = tonemapX;
		tonemapProbe[1] = tonemapY;
		log.info("[probe] armed scene=({},{}) tonemap=({},{})", sceneX, sceneY, tonemapX, tonemapY);
	}

	/**
	 * Snapshot the arm flag for the current render frame. Call once at the very start
	 * of the per-frame uniform setup so {@link #isArmedThisFrame()} returns a consistent
	 * answer for the rest of the frame regardless of when the AWT thread sets the flag.
	 */
	public void beginFrame() {
		armedThisFrame = armNextFrame;
	}

	public boolean isArmedThisFrame() {
		return armedThisFrame;
	}

	public boolean isArmed() {
		return armNextFrame;
	}

	public int[] sceneProbePixel() {
		return sceneProbe;
	}

	public int[] tonemapProbePixel() {
		return tonemapProbe;
	}

	public void bindBeforeFrame() {
		if (ssboId == 0)
			return;
		if (armedThisFrame) {
			ByteBuffer zero = BufferUtils.createByteBuffer(BYTES);
			glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssboId);
			glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, zero);
			glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
		}
		glBindBufferBase(GL_SHADER_STORAGE_BUFFER, SSBO_BINDING, ssboId);
	}

	/**
	 * Reads a small region around the tonemap probe pixel from the currently bound
	 * read framebuffer and writes a PNG with a crosshair on the sampled pixel so the
	 * user can visually verify what was sampled. Must be called while the AWT
	 * framebuffer (post-tonemap, pre-UI) is bound for reading.
	 */
	public void captureProbeCrop(int awtFbWidth, int awtFbHeight, int readBufferMode) {
		if (!armedThisFrame)
			return;
		int cx = tonemapProbe[0];
		int cy = tonemapProbe[1];
		int half = 32;
		int x0 = Math.max(0, cx - half);
		int y0 = Math.max(0, cy - half);
		int x1 = Math.min(awtFbWidth, cx + half + 1);
		int y1 = Math.min(awtFbHeight, cy + half + 1);
		int w = x1 - x0;
		int h = y1 - y0;
		if (w <= 0 || h <= 0)
			return;

		ByteBuffer buf = BufferUtils.createByteBuffer(w * h * 4);
		glReadBuffer(readBufferMode);
		glReadPixels(x0, y0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, buf);

		BufferedImage img = new BufferedImage(w, h, BufferedImage.TYPE_INT_RGB);
		// GL gives bottom-left origin; flip vertically to top-left for BufferedImage.
		for (int yy = 0; yy < h; yy++) {
			for (int xx = 0; xx < w; xx++) {
				int r = buf.get() & 0xff;
				int g = buf.get() & 0xff;
				int b = buf.get() & 0xff;
				buf.get(); // alpha
				img.setRGB(xx, h - yy - 1, (r << 16) | (g << 8) | b);
			}
		}

		// Crosshair on the sampled pixel (in top-left-origin image coords).
		int markX = cx - x0;
		int markY = (h - 1) - (cy - y0);
		int markRGB = 0xFF00FF;     // magenta center pixel
		int armRGB = 0xFFFF00;      // yellow arms
		for (int d = 2; d <= 8; d++) {
			plot(img, markX + d, markY, armRGB);
			plot(img, markX - d, markY, armRGB);
			plot(img, markX, markY + d, armRGB);
			plot(img, markX, markY - d, armRGB);
		}
		plot(img, markX, markY, markRGB);

		try {
			File out = new File("probe_" + System.currentTimeMillis() + ".png");
			ImageIO.write(img, "png", out);
			log.info("[probe] crop saved to {} (centered on tonemap probe pixel ({}, {}), {}x{} px from AWT FB)",
				out.getAbsolutePath(), cx, cy, w, h);
		} catch (IOException ex) {
			log.warn("[probe] failed to save crop PNG", ex);
		}
	}

	private static void plot(BufferedImage img, int x, int y, int rgb) {
		if (x >= 0 && x < img.getWidth() && y >= 0 && y < img.getHeight())
			img.setRGB(x, y, rgb);
	}

	public void readbackAndLog() {
		if (!armedThisFrame || ssboId == 0)
			return;
		armedThisFrame = false;
		armNextFrame = false;

		ByteBuffer raw = BufferUtils.createByteBuffer(BYTES);
		glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssboId);
		glGetBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, raw);
		glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);

		FloatBuffer f = raw.asFloatBuffer();
		java.nio.IntBuffer ii = raw.asIntBuffer();

		float[] s = new float[SLOT_COUNT * 4];
		f.get(s);

		int matFlag0 = ii.get(1 * 4 + 0);
		int matFlag1 = ii.get(1 * 4 + 1);
		int matFlag2 = ii.get(1 * 4 + 2);

		StringBuilder sb = new StringBuilder("\n[probe] dump (scene=").append(sceneProbe[0]).append(",").append(sceneProbe[1])
			.append(" tonemap=").append(tonemapProbe[0]).append(",").append(tonemapProbe[1]).append(")\n");

		sb.append("  scene_frag (pre-invert)        rgb=").append(rgb(s, 0)).append(" hasAttachedLightBlend=").append(s[3]).append("\n");
		sb.append("  scene_frag fMaterialData      = ").append(matFlag0).append(", ").append(matFlag1).append(", ").append(matFlag2).append("\n");
		sb.append("  scene_frag IN.texBlend        = ").append(s[2 * 4]).append(", ").append(s[2 * 4 + 1]).append(", ").append(s[2 * 4 + 2]).append("\n");
		sb.append("  scene_frag (post-invert)       rgb=").append(rgb(s, 3)).append(" t=").append(s[3 * 4 + 3]).append("\n");
		sb.append("  tonemap oklab from sceneTex    = ").append(rgb(s, 4)).append("\n");
		sb.append("  tonemap linear (oklabToLinear) = ").append(rgb(s, 5)).append(" exposure=").append(s[5 * 4 + 3]).append("\n");
		sb.append("  tonemap AgX input (linear*exp) = ").append(rgb(s, 6)).append("\n");
		sb.append("  tonemap AGX_INPUT_MATRIX*v     = ").append(rgb(s, 7)).append("\n");
		sb.append("  tonemap log-clamp-normalize    = ").append(rgb(s, 8)).append("\n");
		sb.append("  tonemap sigmoid                = ").append(rgb(s, 9)).append("\n");
		sb.append("  tonemap punchy                 = ").append(rgb(s, 10)).append("\n");
		sb.append("  tonemap OUT_MATRIX*v (pre)     = ").append(rgb(s, 11)).append("\n");
		sb.append("  tonemap AgX final clamp        = ").append(rgb(s, 12)).append("\n");
		sb.append("  tonemap linearToSrgb(AgX)      = ").append(rgb(s, 13)).append("\n");
		sb.append("  legacy ref linearToSrgb(clamp) = ").append(rgb(s, 14)).append("\n");
		sb.append("  scene_frag outputColor post-blend pre-light  rgba=(")
			.append(s[16 * 4]).append(", ").append(s[16 * 4 + 1]).append(", ")
			.append(s[16 * 4 + 2]).append(") a=").append(s[16 * 4 + 3]).append("\n");
		sb.append("  scene_frag overlay/underlay counts + colorMap1/2 = ")
			.append((int) s[17 * 4]).append("/").append((int) s[17 * 4 + 1])
			.append(", colorMap1=").append((int) s[17 * 4 + 2])
			.append(", colorMap2=").append((int) s[17 * 4 + 3]).append("\n");
		sb.append("  scene_frag outputColor pre-light multiply     rgba=(")
			.append(s[18 * 4]).append(", ").append(s[18 * 4 + 1]).append(", ")
			.append(s[18 * 4 + 2]).append(") a=").append(s[18 * 4 + 3]).append("\n");
		sb.append("  scene_frag compositeLight (rgb) + unlit       = ").append(rgb(s, 19))
			.append(" unlit=").append(s[19 * 4 + 3]).append("\n");
		sb.append("  scene_frag tint (xyz,w)                       = (")
			.append(s[20 * 4]).append(", ").append(s[20 * 4 + 1]).append(", ")
			.append(s[20 * 4 + 2]).append(") w=").append(s[20 * 4 + 3]).append("\n");

		int totalHits = raw.getInt(COUNTER_OFFSET);
		int captured = Math.min(totalHits, STACK_MAX_ENTRIES);
		sb.append("  scene_frag fragment STACK at probe pixel (total hits=").append(totalHits)
			.append(", captured=").append(captured).append("):\n");
		sb.append("    [oklab = post-pipeline OKLab; a = blend alpha; tag/matData/unlit/|light|; baseRGB = blended vertex color; cmap = colorMap1 texture layer]\n");
		for (int k = 0; k < captured; k++) {
			int o = (STACK_BASE_SLOT + 3 * k) * 4;
			int m = (STACK_BASE_SLOT + 3 * k + 1) * 4;
			int b = (STACK_BASE_SLOT + 3 * k + 2) * 4;
			int matDataBits = raw.getInt((m + 1) * Float.BYTES);
			int colorMapBits = raw.getInt((b + 3) * Float.BYTES);
			int matIdx = matDataBits >>> 21;
			sb.append(String.format(
				"    frag[%2d] oklab=(%+.4f, %+.4f, %+.4f) a=%.4f  matIdx=%d  tag=%.2f  unlit=%.2f  |light|=%.3f  baseRGB=(%.4f, %.4f, %.4f)  cmap=%d%n",
				k, s[o], s[o + 1], s[o + 2], s[o + 3],
				matIdx, s[m], s[m + 2], s[m + 3],
				s[b], s[b + 1], s[b + 2], colorMapBits));
		}

		float metaX = s[15 * 4 + 0];
		float metaY = s[15 * 4 + 1];
		float metaHits = s[15 * 4 + 2];
		sb.append("  meta last-writer gl_FragCoord  = (").append(metaX).append(", ").append(metaY)
			.append(") shaderHits=").append(metaHits)
			.append("  (>=100 means a tonemap fragment wrote; +1 per scene_frag fragment)");
		log.info(sb.toString());
	}

	private static String rgb(float[] s, int slot) {
		int o = slot * 4;
		return String.format("(%.5f, %.5f, %.5f)", s[o], s[o + 1], s[o + 2]);
	}
}
