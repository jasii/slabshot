shader_type spatial;
render_mode unshaded, shadows_disabled;

// Bullets move on the GPU: each instance stores its current path segment
// (origin in the instance transform, velocity + start time in CUSTOM), so the
// CPU only touches a bullet when it spawns, bounces or dies.
uniform float now_ticks;

varying vec3 tint;

void vertex() {
	vec3 vel = INSTANCE_CUSTOM.xyz;
	float t0 = INSTANCE_CUSTOM.w;
	float radius = COLOR.a;
	VERTEX = VERTEX * radius + vel * max(now_ticks - t0, 0.0);
	tint = COLOR.rgb;
}

void fragment() {
	// bright core, saturated rim; >1.0 so glow picks it up
	float core = pow(clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	ALBEDO = mix(tint * 1.6, vec3(2.0), core * 0.85);
}
