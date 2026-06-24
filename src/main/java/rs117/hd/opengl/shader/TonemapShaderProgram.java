package rs117.hd.opengl.shader;

import static org.lwjgl.opengl.GL33C.*;
import static rs117.hd.HdPlugin.TEXTURE_UNIT_TONEMAP_DEPTH;
import static rs117.hd.HdPlugin.TEXTURE_UNIT_TONEMAP_SCENE;
import static rs117.hd.HdPlugin.TEXTURE_UNIT_TONEMAP_TAG;

public class TonemapShaderProgram extends ShaderProgram {
	private final UniformTexture uniSceneTex   = addUniformTexture("sceneTex");
	private final UniformTexture uniSceneDepth = addUniformTexture("sceneDepth");
	private final UniformTexture uniTagTex     = addUniformTexture("tagTex");

	public TonemapShaderProgram() {
		super(t -> t
			.add(GL_VERTEX_SHADER, "post/tonemap_vert.glsl")
			.add(GL_FRAGMENT_SHADER, "post/tonemap_frag.glsl"));
	}

	@Override
	protected void initialize() {
		uniSceneTex.set(TEXTURE_UNIT_TONEMAP_SCENE);
		uniSceneDepth.set(TEXTURE_UNIT_TONEMAP_DEPTH);
		uniTagTex.set(TEXTURE_UNIT_TONEMAP_TAG);
	}
}
