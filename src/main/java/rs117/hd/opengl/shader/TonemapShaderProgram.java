package rs117.hd.opengl.shader;

import static org.lwjgl.opengl.GL33C.*;
import static rs117.hd.HdPlugin.TEXTURE_UNIT_TONEMAP_DEPTH;
import static rs117.hd.HdPlugin.TEXTURE_UNIT_TONEMAP_SCENE;

public class TonemapShaderProgram extends ShaderProgram {
	private final UniformTexture uniSceneTex   = addUniformTexture("sceneTex");
	private final UniformTexture uniSceneDepth = addUniformTexture("sceneDepth");

	public TonemapShaderProgram() {
		super(t -> t
			.add(GL_VERTEX_SHADER, "post/tonemap_vert.glsl")
			.add(GL_FRAGMENT_SHADER, "post/tonemap_frag.glsl"));
	}

	@Override
	protected void initialize() {
		uniSceneTex.set(TEXTURE_UNIT_TONEMAP_SCENE);
		uniSceneDepth.set(TEXTURE_UNIT_TONEMAP_DEPTH);
	}
}
