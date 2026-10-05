extends SceneTree
## witness-cpp's suite on the GDScript port (addons/witness), each case with its falsifiability
## control, then properties of util/cassie_alive.gd's split rule.
##   godot --path . --script tests/witness_test.gd

const W := preload("res://addons/witness/witness.gd")

var failed := PackedStringArray()
var count := 0


func _initialize() -> void:
	_core()
	_assume_classify()
	_generators()
	_combinators()
	_shrinkers()
	_reproducer()
	_cassie_split()
	print("RESULT: %s (%d checks)" % ["PASS" if failed.is_empty() else "FAIL " + ", ".join(failed), count])
	quit(0 if failed.is_empty() else 1)


func _check(name: String, ok: bool, info: String = "") -> void:
	count += 1
	print("%s %s%s" % ["PASS" if ok else "FAIL", name, "" if info.is_empty() else ": " + info])
	if not ok:
		failed.append(name)


func _found(name: String, t: W.Trial) -> void:
	_check(name, t.outcome == W.Outcome.FOUND, t.message)


func _holds(name: String, t: W.Trial) -> void:
	_check(name, t.outcome == W.Outcome.PROVABLY_NONE, t.message)


func _int_vec(rng: RandomNumberGenerator, lvl: W.Level) -> Array:
	var v := []
	for i in rng.randi_range(0, lvl.fin_bound / 32):
		v.append(rng.randi_range(-100, 100))
	return v


func _core() -> void:
	var gen := _int_vec
	_holds("reverse . reverse is identity", W.resolve("involution", gen, func(v):
		var r: Array = v.duplicate()
		r.reverse()
		r.reverse()
		return r == v))
	var t := W.resolve("vectors are always empty", gen, func(v): return v.is_empty())
	_found("control: a planted-false property is caught", t)
	_check("control: caught at rung 0", t.level == 0)
	_holds("sort is non-decreasing", W.resolve("sorted", gen, func(v):
		var s: Array = v.duplicate()
		s.sort()
		for i in range(1, s.size()):
			if s[i - 1] > s[i]:
				return false
		return true))
	_found("control: sorted is strictly increasing is false", W.resolve("strict", gen, func(v):
		var s: Array = v.duplicate()
		s.sort()
		for i in range(1, s.size()):
			if s[i - 1] >= s[i]:
				return false
		return true))


func _assume_classify() -> void:
	var gen := W.gen_int_range(-50, 50)
	var seen := [0]
	var t := W.resolve("assume even", gen, func(x):
		W.assume(x % 2 == 0)
		if x % 2 == 0:
			seen[0] += 1
		return x % 2 == 0)
	_holds("assume: rejected inputs do not falsify", t)
	_check("assume: counted trials are the ladder's num_inst", seen[0] == 3000, str(seen[0]))
	_check("control: an always-rejecting predicate does not FOUND",
			W.resolve("reject", gen, func(_x):
				W.assume(false)
				return false).outcome != W.Outcome.FOUND)
	t = W.resolve("classify", gen, func(x):
		W.classify(x < 0, "negative")
		return true)
	_check("classify: the label is reported", t.message.contains("negative"), t.message)
	t = W.resolve("classify never", gen, func(x):
		W.classify(x > 1000, "huge")
		return true)
	_check("control: a label that never matches does not appear", not t.message.contains("huge"), t.message)
	t = W.resolve("collect", W.gen_int_range(0, 2), func(x):
		W.collect(x)
		return true)
	_check("collect: value bins appear", t.message.contains(" 0 ") and t.message.contains(" 2 "), t.message)
	_check("control: an ungenerated bin does not appear", not t.message.contains(" 3 "), t.message)


func _generators() -> void:
	var bools := {}
	W.resolve("bools", W.gen_bool, func(b):
		bools[b] = true
		return true)
	_check("gen_bool: produces both values", bools.size() == 2)
	_found("control: gen_bool is not always true", W.resolve("all true", W.gen_bool, func(b): return b))
	_holds("gen_int: inside the rung's window", W.resolve("window", W.gen_int, func(x): return absi(x) <= 128))
	_found("control: a narrower window is caught", W.resolve("narrow", W.gen_int, func(x): return absi(x) <= 4))
	_holds("gen_int_range: respects bounds", W.resolve("bounds", W.gen_int_range(3, 9), func(x): return x >= 3 and x <= 9))
	_found("control: a stricter bound is falsified", W.resolve("stricter", W.gen_int_range(3, 9), func(x): return x < 9))
	_holds("gen_double: stays finite", W.resolve("finite", W.gen_double, func(x): return is_finite(x)))
	_found("control: doubles are not all integers", W.resolve("integer", W.gen_double, func(x): return x == floorf(x)))
	_holds("gen_string: printable ASCII", W.resolve("ascii", W.gen_string, func(s):
		for i in s.length():
			if s.unicode_at(i) < 32 or s.unicode_at(i) > 126:
				return false
		return true))
	_found("control: strings are not all empty", W.resolve("empty", W.gen_string, func(s): return s.is_empty()))
	_holds("gen_string_of: stays in the alphabet", W.resolve("alphabet", W.gen_string_of("xyz"), func(s):
		for c in s:
			if not "xyz".contains(c):
				return false
		return true))
	_found("control: an off-alphabet check falsifies", W.resolve("no z", W.gen_string_of("xyz"), func(s): return not s.contains("z")))
	_holds("gen_vector: respects its size cap", W.resolve("cap", W.gen_vector(W.gen_int), func(v): return v.size() <= 128))
	_found("control: a tighter cap is falsified", W.resolve("tight", W.gen_vector(W.gen_int), func(v): return v.size() <= 2))
	_holds("gen_set: distinct elements", W.resolve("distinct", W.gen_set(W.gen_int_range(0, 20)), func(s):
		var d := {}
		for x in s:
			d[x] = true
		return d.size() == s.size()))
	_found("control: a set-size lower bound is falsified", W.resolve("big sets", W.gen_set(W.gen_int_range(0, 20)), func(s): return s.size() >= 3))
	_found("control: a map-size lower bound is falsified", W.resolve("big maps", W.gen_map(W.gen_int, W.gen_bool), func(m): return m.size() >= 3))
	var kinds := {}
	W.resolve("optional", W.gen_optional(W.gen_int), func(o):
		kinds[o.size()] = true
		return true)
	_check("gen_optional: both empty and value", kinds.has(0) and kinds.has(1))
	_found("control: optionals are not always present", W.resolve("present", W.gen_optional(W.gen_int), func(o): return o.size() == 1))


func _combinators() -> void:
	var tup := W.gen_tuple([W.gen_int_range(0, 3), W.gen_int_range(10, 13), W.gen_bool])
	_holds("gen_tuple: populates every slot", W.resolve("tuple", tup, func(t):
		return t.size() == 3 and t[0] <= 3 and t[1] >= 10 and t[2] is bool))
	_found("control: a slot outside its range is caught", W.resolve("tuple out", tup, func(t): return t[1] < 13))
	var seen := {}
	W.resolve("oneof", W.gen_oneof([W.gen_constant(1), W.gen_constant(2), W.gen_constant(3)]), func(x):
		seen[x] = true
		return true)
	_check("gen_oneof: every alternative", seen.size() == 3)
	_holds("control: a single-alternative oneof", W.resolve("one", W.gen_oneof([W.gen_constant(7)]), func(x): return x == 7))
	_found("control: a value not in gen_element's list never appears, so this falsifies",
			W.resolve("element", W.gen_element(["a", "b"]), func(x): return x == "a"))
	var heavy := [0, 0]
	W.resolve("frequency", W.gen_frequency([[9, W.gen_constant(0)], [1, W.gen_constant(1)]]), func(x):
		heavy[x] += 1
		return true)
	_check("gen_frequency: favors the heavier weight", heavy[0] > 4 * heavy[1], str(heavy))
	_holds("gen_transform: doubled values are even", W.resolve("double", W.gen_transform(W.gen_int, func(x): return 2 * x), func(x): return x % 2 == 0))
	_found("control: doubled values are not odd", W.resolve("odd", W.gen_transform(W.gen_int, func(x): return 2 * x), func(x): return x % 2 != 0))
	_check("gen_filter: an unsatisfiable filter never FOUNDs",
			W.resolve("filter", W.gen_filter(W.gen_int, func(_x): return false), func(_x): return false).outcome != W.Outcome.FOUND)
	var sized := W.gen_bind(W.gen_int_range(0, 5), func(n): return W.gen_array(n, W.gen_bool))
	_holds("gen_bind: a size then an array of it", W.resolve("bind", sized, func(v): return v.size() <= 5))
	_found("control: a tighter cap than the size range", W.resolve("bind cap", sized, func(v): return v.size() <= 3))
	var calls := [0]
	W.resolve_with_ladder("custom", [W.Level.new(0, 1, 32, 7)], W.gen_int, func(_x):
		calls[0] += 1
		return true)
	_check("resolve_with_ladder: the ladder sets the trial count", calls[0] == 7, str(calls[0]))
	calls[0] = 0
	W.resolve_with_ladder("empty", [], W.gen_int, func(_x):
		calls[0] += 1
		return true)
	_check("control: an empty ladder runs no trials", calls[0] == 0)


func _shrinkers() -> void:
	_check("shrink_bool: toward false", W.shrink_bool(true) == [false] and W.shrink_bool(false) == [])
	_check("shrink_char: toward a", W.shrink_char("d") == ["a", "c"] and W.shrink_char("a") == [])
	_check("shrink_int: toward zero", W.shrink_int(-6) == [0, 6, -3] and W.shrink_int(0) == [])
	_check("shrink_double: strictly closer to zero", W.shrink_double(3.0).all(func(x): return absf(x) < 3.0))
	_check("shrink_string: every candidate shorter", W.shrink_string("abcd").all(func(s): return s.length() < 4))
	_check("shrink_vector: every candidate smaller", W.shrink_vector([1, 2, 3]).all(func(v): return v.size() < 3))
	_check("shrink_set: one fewer element", W.shrink_set([1, 2, 3]).all(func(s): return s.size() == 2))
	_check("control: an empty set has no candidates", W.shrink_set([]).is_empty())
	_check("shrink_map: one fewer entry", W.shrink_map({1: true, 2: false}).all(func(m): return m.size() == 1))
	_check("control: an empty map has no candidates", W.shrink_map({}).is_empty())
	var pair := W.shrink_pair([4, true], W.shrink_int, W.shrink_bool)
	_check("shrink_pair: one half at a time", pair.all(func(p): return p[0] == 4 or p[1] == true), str(pair))
	_check("shrink_optional: empty first", W.shrink_optional([5], W.shrink_int)[0] == [])
	_check("control: an empty optional has no candidates", W.shrink_optional([], W.shrink_int).is_empty())
	var shrunk := W.shrink_input([5, 6, 7, 8], func(v): return v.is_empty(), W.shrink_vector)
	_check("shrink_input: a falsifying vector reduces to size 1", shrunk[0].size() == 1, str(shrunk))
	_check("control: no shrinker never reduces", W.shrink_input([5, 6], func(v): return v.is_empty(), Callable())[0].size() == 2)


func _reproducer() -> void:
	var pred := func(v): return v.size() < 3
	var a := W.resolve("seeded", _int_vec, pred, W.shrink_vector, str, 0x1234)
	var b := W.resolve("seeded", _int_vec, pred, W.shrink_vector, str, 0x1234)
	_check("reproducer: the same seed gives the same message", a.message == b.message, a.message)
	_check("reproducer: the FOUND message names the seed", a.message.contains("property_seed=0x0000000000001234"))
	var c := W.resolve("seeded", _int_vec, func(v): return v.size() < 6, Callable(), Callable(), 0x1234)
	var d := W.resolve("seeded", _int_vec, func(v): return v.size() < 6, Callable(), Callable(), 0x5678)
	_check("control: different seeds give different messages", c.message != d.message)
	var e := W.resolve("negative", _int_vec, pred, Callable(), Callable(), -0x491d29c082e4b485)
	_check("reproducer: a negative seed prints as 16 hex digits", e.message.contains("property_seed=0xb6e2d63f7d1b4b7b"), e.message)


# Properties of the dress expectation's split rule.
func _cassie_split() -> void:
	# A patch of n old strokes, cut by stroke s (and its mirror s + 1) into k >= 2 pieces that
	# together cover it: the patch is never alive.
	var cut := func(rng: RandomNumberGenerator, lvl: W.Level) -> Array:
		var n := rng.randi_range(2, maxi(2, lvl.fin_bound / 64))
		var k := rng.randi_range(2, mini(n, 5))
		var pieces := []
		for i in k:
			pieces.append([])
		for x in range(1, n + 1):
			pieces[rng.randi_range(0, k - 1)].append(x * 2)
		return [n, pieces]
	var session := func(input: Array) -> Dictionary:
		var n: int = input[0]
		var s := (n + 1) * 2
		var states := []
		for x in range(1, n):
			states.append([CassieAlive.ADD_STROKE, x * 2])
		states.append([CassieAlive.ADD_PATCH, 1000])
		states.append([CassieAlive.ADD_STROKE, n * 2])
		var patches := [{"id": 1000, "foundByAlgo": true, "strokesID": range(1, n + 1).map(func(x): return x * 2)}]
		var id := 1001
		for piece in input[1]:
			states.append([CassieAlive.ADD_PATCH, id])
			var mirror := id % 2 == 0
			patches.append({"id": id, "foundByAlgo": true, "strokesID": piece + [s + 1 if mirror else s]})
			id += 1
		states.append([CassieAlive.ADD_STROKE, s])
		var st := []
		for e in states:
			st.append({"interactionType": e[0], "elementID": e[1]})
		return {"systemStates": st, "allCreatedPatches": patches}
	var old_alive := func(input: Array) -> bool:
		var a: Dictionary = CassieAlive.alive_patches(session.call(input))
		var whole: Array = range(1, input[0] + 1).map(func(x): return x * 2)
		return a["alive_strokes"].has(whole)
	_holds("a cut into k >= 2 covering pieces drops the patch", W.resolve("split", cut, func(i): return not old_alive.call(i)))
	# Control: the same pieces with one stroke left out cover nothing, so the patch stays.
	var partial := func(rng: RandomNumberGenerator, lvl: W.Level) -> Array:
		var i: Array = cut.call(rng, lvl)
		for p in i[1]:
			if p.size() > 0:
				p.remove_at(0)
				break
		return i
	_found("control: pieces that miss a stroke keep the patch", W.resolve("partial", partial, func(i): return not old_alive.call(i)))
