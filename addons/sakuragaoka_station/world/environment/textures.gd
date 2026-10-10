# environment/textures.js: the canvas textures (ground, levee, masonry, fields ...). The port draws
# no canvases, so each is a sized stand-in with the original's key and tiling.
extends RefCounted

## [name, width, height, key, repeat or null]
const TEXTURES := [
	["ground", 512, 512, "env-ground", [1, 1]],
	["levee", 512, 512, "env-levee", [1, 1]],
	["masonry", 512, 512, "env-masonry2", [1, 1]],
	["path", 512, 512, "env-path", [1, 1]],
	["tufts", 1024, 512, "env-tufts2", null],
	["flowers", 1024, 512, "env-flowers2", null],
	["mats", 512, 512, "env-mats", null],
	["reeds", 512, 512, "env-reeds2", null],
	["railing", 256, 128, "env-railing", [1, 1]],
	["shrub", 256, 256, "env-shrub2", [1, 1]],
	["facade", 256, 128, "env-facade", null],
	["school", 512, 128, "env-school", null],
]
const FIELDS := ["dry", "veg", "renge", "wheat", "nano", "grass"]


static func create_env_textures(ctx):
	var bag = ctx.tex.bag()
	for t in TEXTURES:
		var opts := {"key": t[3]}
		if t[4] != null:
			opts["repeat"] = t[4]
		bag._m[t[0]] = ctx.tex.draw(t[1], t[2], null, opts)
	var fields = bag.sub("fields")
	for f in FIELDS:
		fields._m[f] = ctx.tex.draw(256, 256, null, {"key": "env-field-" + f, "repeat": [1, 1]})
	return bag
