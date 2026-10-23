// The ChArUco suit on a body with no UVs (util/suit_material.gd): projected from three
// sides in the mesh's own frame, at the suit's real size. Each side's image is turned so
// it reads unmirrored from outside the body, front, back, left, right and top alike.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D suit : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec2 size_m = vec2(1.47, 1.95);
uniform vec4 tint : source_color = vec4(1.0);
uniform float sharpness = 8.0;

varying vec3 p;
varying vec3 n;

void vertex() {
	p = VERTEX;
	n = NORMAL;
}

float side(float v) {
	return v >= 0.0 ? 1.0 : -1.0;
}

void fragment() {
	vec3 w = pow(abs(normalize(n)), vec3(sharpness));
	w /= w.x + w.y + w.z;
	vec2 uz = vec2(p.x * side(n.z), -p.y) / size_m;
	vec2 ux = vec2(-p.z * side(n.x), -p.y) / size_m;
	vec2 uy = vec2(p.x, p.z * side(n.y)) / size_m.xx;
	vec3 c = texture(suit, uz).rgb * w.z + texture(suit, ux).rgb * w.x + texture(suit, uy).rgb * w.y;
	ALBEDO = c * tint.rgb;
	ROUGHNESS = 1.0;
}
