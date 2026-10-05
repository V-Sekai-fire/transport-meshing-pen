class_name Witness
## A property-testing ladder in GDScript, ported from witness-cpp 5680e85 (MIT).
## Generators are Callable(rng: RandomNumberGenerator, lvl: Witness.Level) -> Variant and shrinkers
## Callable(value) -> Array of smaller candidates. Seeds drive Godot's PCG32, so a seed reproduces
## a run here but not in witness-cpp. Containers map to Array (vector, array, pair, tuple), a
## sorted Array of unique values (set), Dictionary (map), and an Array of zero or one (optional).

enum Outcome { FOUND, PROVABLY_NONE, BUDGET_HIT }
enum Verdict { HOLD, FALSIFY, SKIP }


class Level:
	var idx: int
	var walk_steps: int
	var fin_bound: int
	var num_inst: int

	func _init(p_idx: int, p_walk_steps: int, p_fin_bound: int, p_num_inst: int) -> void:
		idx = p_idx
		walk_steps = p_walk_steps
		fin_bound = p_fin_bound
		num_inst = p_num_inst


class Trial:
	var outcome: int = Outcome.PROVABLY_NONE
	var level: int = 0
	var trial_idx: int = 0
	var message: String = ""

	func _init(p_outcome: int, p_level: int, p_trial_idx: int, p_message: String) -> void:
		outcome = p_outcome
		level = p_level
		trial_idx = p_trial_idx
		message = p_message


static var verdict: int = Verdict.HOLD
static var class_hits: Dictionary = {}
static var trials_counted: int = 0


static func default_ladder() -> Array:
	return [Level.new(0, 64, 256, 200), Level.new(1, 512, 1024, 800), Level.new(2, 4000, 4096, 2000)]


static func assume(cond: bool) -> void:
	if not cond:
		verdict = Verdict.SKIP


static func classify(cond: bool, label: String) -> void:
	if cond:
		class_hits[label] = class_hits.get(label, 0) + 1


static func collect(value) -> void:
	var label := str(value)
	class_hits[label] = class_hits.get(label, 0) + 1


# --- primitive generators ----------------------------------------------------------

static func _scale32(lvl: Level) -> int:
	return maxi(1, lvl.fin_bound / 32)


static func gen_bool(rng: RandomNumberGenerator, _lvl: Level) -> bool:
	return rng.randi_range(0, 1) == 1


static func gen_char(rng: RandomNumberGenerator, _lvl: Level) -> String:
	return char(rng.randi_range(32, 126))


static func gen_int(rng: RandomNumberGenerator, lvl: Level) -> int:
	return rng.randi_range(-_scale32(lvl), _scale32(lvl))


static func gen_uint(rng: RandomNumberGenerator, lvl: Level) -> int:
	return rng.randi_range(0, _scale32(lvl))


static func gen_int64(rng: RandomNumberGenerator, lvl: Level) -> int:
	return rng.randi_range(-maxi(1, lvl.fin_bound), maxi(1, lvl.fin_bound))


static func gen_uint64(rng: RandomNumberGenerator, lvl: Level) -> int:
	return rng.randi_range(0, maxi(1, lvl.fin_bound))


static func gen_size(rng: RandomNumberGenerator, lvl: Level) -> int:
	return gen_uint64(rng, lvl)


static func gen_double(rng: RandomNumberGenerator, lvl: Level) -> float:
	var s := maxf(1.0, float(lvl.fin_bound))
	return rng.randf_range(-s, s)


static func gen_float(rng: RandomNumberGenerator, lvl: Level) -> float:
	return gen_double(rng, lvl)


static func gen_string(rng: RandomNumberGenerator, lvl: Level) -> String:
	var n := rng.randi_range(0, _scale32(lvl))
	var s := ""
	for i in n:
		s += char(rng.randi_range(32, 126))
	return s


# --- ranged and composite generators ------------------------------------------------

static func gen_int_range(lo: int, hi: int) -> Callable:
	return func(rng: RandomNumberGenerator, _lvl: Level) -> int: return rng.randi_range(lo, hi)


static func gen_double_range(lo: float, hi: float) -> Callable:
	return func(rng: RandomNumberGenerator, _lvl: Level) -> float: return rng.randf_range(lo, hi)


static func gen_vector(elem: Callable) -> Callable:
	return func(rng: RandomNumberGenerator, lvl: Level) -> Array:
		var n := rng.randi_range(0, _scale32(lvl))
		var v := []
		for i in n:
			v.append(elem.call(rng, lvl))
		return v


static func gen_array(size: int, elem: Callable) -> Callable:
	return func(rng: RandomNumberGenerator, lvl: Level) -> Array:
		var v := []
		for i in size:
			v.append(elem.call(rng, lvl))
		return v


static func gen_set(elem: Callable) -> Callable:
	return func(rng: RandomNumberGenerator, lvl: Level) -> Array:
		var n := rng.randi_range(0, _scale32(lvl))
		var v := []
		for i in n:
			var x = elem.call(rng, lvl)
			if not v.has(x):
				v.append(x)
		v.sort()
		return v


static func gen_map(key: Callable, value: Callable) -> Callable:
	return func(rng: RandomNumberGenerator, lvl: Level) -> Dictionary:
		var n := rng.randi_range(0, _scale32(lvl))
		var m := {}
		for i in n:
			var k = key.call(rng, lvl)
			var v = value.call(rng, lvl)
			if not m.has(k):
				m[k] = v
		return m


static func gen_pair(a: Callable, b: Callable) -> Callable:
	return gen_tuple([a, b])


static func gen_optional(elem: Callable) -> Callable:
	return func(rng: RandomNumberGenerator, lvl: Level) -> Array:
		if rng.randi_range(0, 3) == 0:
			return []
		return [elem.call(rng, lvl)]


static func gen_tuple(gens: Array) -> Callable:
	return func(rng: RandomNumberGenerator, lvl: Level) -> Array:
		var t := []
		for g in gens:
			t.append(g.call(rng, lvl))
		return t


static func gen_oneof(gens: Array) -> Callable:
	return func(rng: RandomNumberGenerator, lvl: Level) -> Variant:
		return gens[rng.randi_range(0, gens.size() - 1)].call(rng, lvl)


static func gen_element(values: Array) -> Callable:
	return func(rng: RandomNumberGenerator, _lvl: Level) -> Variant:
		return values[rng.randi_range(0, values.size() - 1)]


## weighted: Array of [weight, generator].
static func gen_frequency(weighted: Array) -> Callable:
	var total := 0
	for wg in weighted:
		total += int(wg[0])
	return func(rng: RandomNumberGenerator, lvl: Level) -> Variant:
		var pick := rng.randi_range(0, maxi(0, total - 1))
		var acc := 0
		for wg in weighted:
			acc += int(wg[0])
			if pick < acc:
				return wg[1].call(rng, lvl)
		return weighted.back()[1].call(rng, lvl)


static func gen_constant(v) -> Callable:
	return func(_rng: RandomNumberGenerator, _lvl: Level) -> Variant: return v


static func gen_string_of(alphabet: String) -> Callable:
	return func(rng: RandomNumberGenerator, lvl: Level) -> String:
		var n := rng.randi_range(0, _scale32(lvl))
		var s := ""
		if alphabet.is_empty():
			return s
		for i in n:
			s += alphabet[rng.randi_range(0, alphabet.length() - 1)]
		return s


static func gen_transform(gen: Callable, fn: Callable) -> Callable:
	return func(rng: RandomNumberGenerator, lvl: Level) -> Variant: return fn.call(gen.call(rng, lvl))


## Resample up to retries times until pred holds; on exhaustion the trial is SKIPped.
static func gen_filter(gen: Callable, pred: Callable, retries: int = 32) -> Callable:
	return func(rng: RandomNumberGenerator, lvl: Level) -> Variant:
		var v = gen.call(rng, lvl)
		for i in retries:
			if pred.call(v):
				return v
			v = gen.call(rng, lvl)
		if not pred.call(v):
			verdict = Verdict.SKIP
		return v


static func gen_bind(gen: Callable, fn: Callable) -> Callable:
	return func(rng: RandomNumberGenerator, lvl: Level) -> Variant:
		var next: Callable = fn.call(gen.call(rng, lvl))
		return next.call(rng, lvl)


# --- shrinkers -----------------------------------------------------------------------

static func shrink_bool(b: bool) -> Array:
	return [false] if b else []


static func shrink_char(c: String) -> Array:
	var out := []
	if c != "a":
		out.append("a")
	if c > "a":
		out.append(char(c.unicode_at(0) - 1))
	return out


static func shrink_int(n: int) -> Array:
	var out := []
	if n != 0:
		out.append(0)
	if n < 0:
		out.append(-n)
	@warning_ignore("integer_division")
	var halved := n / 2
	if halved != n:
		out.append(halved)
	return out


static func shrink_double(x: float) -> Array:
	var out := []
	if x != 0.0:
		out.append(0.0)
	if x < 0.0:
		out.append(-x)
	if x / 2.0 != x:
		out.append(x / 2.0)
	return out


static func shrink_string(s: String) -> Array:
	var out := []
	if s.is_empty():
		return out
	if s.length() > 1:
		out.append(s.substr(0, s.length() / 2))
	for i in s.length():
		out.append(s.substr(0, i) + s.substr(i + 1))
	return out


static func shrink_vector(v: Array) -> Array:
	var out := []
	if v.is_empty():
		return out
	if v.size() > 1:
		out.append(v.slice(0, v.size() / 2))
	for i in v.size():
		out.append(v.slice(0, i) + v.slice(i + 1))
	return out


static func shrink_set(s: Array) -> Array:
	var out := []
	for i in s.size():
		out.append(s.slice(0, i) + s.slice(i + 1))
	return out


static func shrink_map(m: Dictionary) -> Array:
	var out := []
	for k in m:
		var smaller := m.duplicate()
		smaller.erase(k)
		out.append(smaller)
	return out


static func shrink_optional(x: Array, t_shrink: Callable) -> Array:
	var out := []
	if not x.is_empty():
		out.append([])
		for c in t_shrink.call(x[0]):
			out.append([c])
	return out


## One shrinker per slot; candidates shrink one slot at a time, left to right.
static func shrink_tuple(t: Array, shrinks: Array) -> Array:
	var out := []
	for i in t.size():
		for c in shrinks[i].call(t[i]):
			var copy := t.duplicate()
			copy[i] = c
			out.append(copy)
	return out


static func shrink_pair(p: Array, a_shrink: Callable, b_shrink: Callable) -> Array:
	return shrink_tuple(p, [a_shrink, b_shrink])


static func no_shrink(_x) -> Array:
	return []


static func shrink_input(input, predicate: Callable, shrinker: Callable, budget: int = 128) -> Array:
	var iterations := 0
	if not shrinker.is_valid():
		return [input, 0]
	for i in budget:
		var improved := false
		for cand in shrinker.call(input):
			var saved := [verdict, class_hits, trials_counted]
			verdict = Verdict.HOLD
			class_hits = {}
			trials_counted = 0
			var held := bool(predicate.call(cand))
			var v := verdict
			verdict = saved[0]
			class_hits = saved[1]
			trials_counted = saved[2]
			if v == Verdict.SKIP:
				continue
			if not held:
				input = cand
				improved = true
				iterations += 1
				break
		if not improved:
			break
	return [input, iterations]


# --- seeds, messages and the resolvers ---------------------------------------------

static func pick_seed(caller_seed: int) -> int:
	if caller_seed != 0:
		return caller_seed
	var env := OS.get_environment("PROPERTY_SEED")
	if env.begins_with("0x") and env.length() > 2 and env.substr(2).is_valid_hex_number():
		var hex := env.substr(2).lpad(16, "0")
		var parsed := (hex.substr(0, 8).hex_to_int() << 32) | hex.substr(8).hex_to_int()
		if parsed != 0:
			return parsed
	if env.is_valid_int() and env.to_int() != 0:
		return env.to_int()
	var r := RandomNumberGenerator.new()
	r.randomize()
	var s := (r.randi() << 32) ^ r.randi()
	return s if s != 0 else 0xC0FFEE


static func _hex(seed: int) -> String:
	return "0x%08x%08x" % [(seed >> 32) & 0xFFFFFFFF, seed & 0xFFFFFFFF]


static func run_predicate(predicate: Callable, input) -> int:
	if verdict == Verdict.SKIP:
		return Verdict.SKIP
	verdict = Verdict.HOLD
	var held := bool(predicate.call(input))
	if verdict == Verdict.SKIP:
		return Verdict.SKIP
	verdict = Verdict.HOLD if held else Verdict.FALSIFY
	return verdict


## printer: Callable(value) -> String, or an empty Callable to leave the minimum out.
static func resolve_with_ladder(query: String, ladder: Array, make_input: Callable, predicate: Callable,
		shrinker: Callable = Callable(), printer: Callable = Callable(), seed: int = 0) -> Trial:
	var actual_seed := pick_seed(seed)
	var rng := RandomNumberGenerator.new()
	rng.seed = actual_seed
	class_hits = {}
	trials_counted = 0
	var last_idx := 0
	for lvl in ladder:
		last_idx = lvl.idx
		var trial_counter := 0
		var skipped := 0
		while trial_counter < lvl.num_inst:
			if skipped >= lvl.num_inst * 10:
				break
			verdict = Verdict.HOLD
			var input = make_input.call(rng, lvl)
			var v := run_predicate(predicate, input)
			if v == Verdict.SKIP:
				skipped += 1
				continue
			if v == Verdict.FALSIFY:
				var shrunk := shrink_input(input, predicate, shrinker)
				var msg := "%s falsified at level %d trial %d (walk_steps=%d fin_bound=%d)" % [
						query, lvl.idx, trial_counter, lvl.walk_steps, lvl.fin_bound]
				if shrunk[1] > 0:
					msg += "; shrunk %d step(s)" % shrunk[1]
				if printer.is_valid():
					var body: String = printer.call(shrunk[0])
					if not body.is_empty():
						msg += "; minimum=" + body
				msg += "; re-run with property_seed=" + _hex(actual_seed)
				return Trial.new(Outcome.FOUND, lvl.idx, trial_counter, msg)
			trials_counted += 1
			trial_counter += 1
	var msg := "%s held across the ladder; seed=%s" % [query, _hex(actual_seed)]
	if not class_hits.is_empty() and trials_counted > 0:
		var parts := PackedStringArray()
		var labels := class_hits.keys()
		labels.sort()
		for label in labels:
			var hits: int = class_hits[label]
			@warning_ignore("integer_division")
			var pct := (100 * hits + trials_counted / 2) / trials_counted
			parts.append(" %s %d%% (%d/%d)" % [label, pct, hits, trials_counted])
		msg += "; classifications:" + ",".join(parts)
	return Trial.new(Outcome.PROVABLY_NONE, last_idx, 0, msg)


static func resolve(query: String, make_input: Callable, predicate: Callable,
		shrinker: Callable = Callable(), printer: Callable = Callable(), seed: int = 0) -> Trial:
	return resolve_with_ladder(query, default_ladder(), make_input, predicate, shrinker, printer, seed)
