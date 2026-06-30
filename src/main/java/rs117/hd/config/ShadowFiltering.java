package rs117.hd.config;

import lombok.Getter;
import lombok.RequiredArgsConstructor;

@Getter
@RequiredArgsConstructor
public enum ShadowFiltering {
	SMOOTH("Smooth"),
	DITHERED("Dithered"),
	PIXELATED("Pixelated"),
	JITTERED_PCF("Smoother");

	private final String name;

	@Override
	public String toString() {
		return name;
	}
}
