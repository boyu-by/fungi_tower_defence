shader_type canvas_item;
uniform float elapsed = 0.0;
uniform float grain = 0.025;
uniform float desaturation = 0.0;
uniform float darkness = 0.0;

void fragment() {
	vec4 ink = COLOR;
	float grey = dot(ink.rgb, vec3(0.299, 0.587, 0.114));
	ink.rgb = mix(ink.rgb, vec3(grey), desaturation);
	float noise = fract(sin(dot(floor(FRAGCOORD.xy), vec2(12.9898, 78.233)) + floor(elapsed * 8.0)) * 43758.5453);
	ink.rgb = ink.rgb * (1.0 - darkness) + (noise - 0.5) * grain;
	COLOR = ink;
}
