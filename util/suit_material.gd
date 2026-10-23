# suit_material -- the body's ChArUco suit (weftspun RFD 2332), so the surface reads:
# where a garment sits, where it clips, and how the body turns.
#
# xr/suit/charuco-suit.png comes from tools/suit_texture.py, drawn from the SOMA suit
# detector's own board (49 by 65 squares of 30 mm, DICT_4X4_1000 markers of 22 mm). The
# body meshes have no UVs, so xr/suit/suit.gdshader projects the image from three sides in
# the body's own frame at its real size, 1.47 m across and 1.95 m tall, each side turned so
# its markers read unmirrored from outside.
extends RefCounted

const TEXTURE := "res://xr/suit/charuco-suit.png"
const SHADER := "res://xr/suit/suit.gdshader"

static func make(tint: Color = Color.WHITE) -> Material:
	var tex = load(TEXTURE)
	var sh = load(SHADER)
	if tex == null or sh == null:
		push_warning("suit_material: %s or %s did not load; the body is drawn plain" % [TEXTURE, SHADER])
		var m := StandardMaterial3D.new()
		m.albedo_color = tint
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		return m
	var s := ShaderMaterial.new()
	s.shader = sh
	s.set_shader_parameter("suit", tex)
	s.set_shader_parameter("tint", tint)
	return s
