## synth.gd - the fight's sounds, synthesised: no sound files, the same way
## the textures are painted in code.
##
## Every sound is worked out once as raw samples (a thump, a crack of noise
## and a few ringing partials for an impact; detuned saws for a drive motor;
## bands of noise for the crowd) and handed to the engine's own players,
## which then only change pitch and volume. Making them takes a few seconds,
## so audio.gd does it on a background thread and keeps the result on disk.
class_name Synth

const RATE := 22050
const VERSION := 3

# A two-pole filter (the usual "biquad"), one sample at a time.
class Biquad:
	var b0 := 1.0
	var b1 := 0.0
	var b2 := 0.0
	var a1 := 0.0
	var a2 := 0.0
	var x1 := 0.0
	var x2 := 0.0
	var y1 := 0.0
	var y2 := 0.0

	func setup(kind: String, freq: float, q: float) -> Biquad:
		var w := TAU * clampf(freq, 10.0, Synth.RATE * 0.45) / Synth.RATE
		var cs := cos(w)
		var alpha := sin(w) / (2.0 * maxf(0.05, q))
		var a0 := 1.0 + alpha
		match kind:
			"lowpass":
				b0 = (1.0 - cs) / 2.0 / a0; b1 = (1.0 - cs) / a0; b2 = b0
			"highpass":
				b0 = (1.0 + cs) / 2.0 / a0; b1 = -(1.0 + cs) / a0; b2 = b0
			_:
				b0 = alpha / a0; b1 = 0.0; b2 = -alpha / a0
		a1 = -2.0 * cs / a0
		a2 = (1.0 - alpha) / a0
		return self

	func run(x: float) -> float:
		var y := b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
		x2 = x1; x1 = x
		y2 = y1; y1 = y
		return y

static func _buf(seconds: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(int(seconds * RATE))
	return b

# Rise to `peak` over `attack`, die away over `decay` (both exponential).
static func _env(t: float, peak: float, attack: float, decay: float) -> float:
	if t < 0.0 or peak <= 0.0002: return 0.0
	if t < attack: return 0.0001 * pow(peak / 0.0001, t / attack)
	var u := (t - attack) / decay
	if u >= 1.0: return 0.0
	return peak * pow(0.0001 / peak, u)

static func _wave(kind: String, phase: float) -> float:
	var p := fposmod(phase, 1.0)
	match kind:
		"saw": return 2.0 * p - 1.0
		"square": return 1.0 if p < 0.5 else -1.0
		"triangle": return 4.0 * absf(p - 0.5) - 1.0
	return sin(TAU * p)

# A tone whose pitch slides from f0 to f1 over `slide` seconds, shaped by an
# envelope, added into `out` starting at `at` seconds.
static func _tone(out: PackedFloat32Array, kind: String, f0: float, f1: float, slide: float, peak: float, attack: float, decay: float, at := 0.0, expo := true) -> void:
	var start := int(at * RATE)
	var n := mini(out.size() - start, int((attack + decay) * RATE) + 1)
	var phase := 0.0
	for i in n:
		var t := float(i) / RATE
		var u := clampf(t / maxf(slide, 1e-4), 0.0, 1.0)
		var f := f0 * pow(f1 / f0, u) if expo else lerpf(f0, f1, u)
		phase += f / RATE
		out[start + i] += _wave(kind, phase) * _env(t, peak, attack, decay)

# Filtered noise with an envelope. The filter can sweep from f0 to f1.
static func _noise(out: PackedFloat32Array, rng: RandomNumberGenerator, kind: String, f0: float, f1: float, q: float, peak: float, attack: float, decay: float, at := 0.0, tremolo_hz := 0.0, tremolo := 0.0) -> void:
	var start := int(at * RATE)
	var n := mini(out.size() - start, int((attack + decay) * RATE) + 1)
	var f := Biquad.new().setup(kind, f0, q)
	for i in n:
		var t := float(i) / RATE
		if f1 != f0 and i % 32 == 0: f.setup(kind, f0 * pow(f1 / f0, clampf(t / (attack + decay), 0.0, 1.0)), q)
		var g := _env(t, peak, attack, decay)
		if tremolo > 0.0: g *= 1.0 + tremolo * sin(TAU * tremolo_hz * t)
		out[start + i] += f.run(rng.randf_range(-1.0, 1.0)) * g * 2.2

static func _mix(out: PackedFloat32Array, src: PackedFloat32Array, at: float) -> void:
	var start := int(at * RATE)
	for i in mini(src.size(), out.size() - start): out[start + i] += src[i]

# Steel on steel: a thump, a crack of noise and a few inharmonic rings.
static func _impact(rng: RandomNumberGenerator, ram: bool, seconds := 1.25) -> PackedFloat32Array:
	var out := _buf(seconds)
	var s := 0.85
	_tone(out, "sine", 70.0 if ram else 110.0, 38.0, 0.25, 0.9 * s, 0.004, 0.28 + s * 0.2)
	var band := 900.0 if ram else 2600.0 + rng.randf() * 1500.0
	_noise(out, rng, "bandpass", band, band, 0.8, 0.7 * s, 0.002, 0.08 + s * 0.18)
	# Ring: a weapon hit rings like struck plate.
	if not ram:
		var base := 300.0 + rng.randf() * 220.0
		for pr in [[1.0, 0.22], [2.76, 0.14], [5.4, 0.09], [8.9, 0.05]]:
			_tone(out, "sine", base * pr[0], base * pr[0], 1.0, pr[1] * s, 0.002, 0.25 + s * 0.7)
	return out

# A loop of something periodic: run it twice and keep the second pass, so
# the filters have settled and the end meets the start.
static func _loop_tone(seconds: float, parts: Array, lowpass := 0.0) -> PackedFloat32Array:
	var n := int(seconds * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var f := Biquad.new().setup("lowpass", lowpass, 0.7) if lowpass > 0.0 else null
	var phases := []
	for p in parts: phases.append(0.0)
	for pass_i in 2:
		for i in n:
			var x := 0.0
			for k in parts.size():
				phases[k] += parts[k][1] / RATE
				x += _wave(parts[k][0], phases[k]) * parts[k][2]
			if f != null: x = f.run(x)
			if pass_i == 1: out[i] = x
	return out

# A loop of filtered noise, its tail folded back into its head so it has no seam.
static func _loop_noise(rng: RandomNumberGenerator, seconds: float, freq: float, q: float, gain: float, am_hz := 0.0, am := 0.0) -> PackedFloat32Array:
	var n := int(seconds * RATE)
	var fade := int(0.25 * RATE)
	var raw := PackedFloat32Array()
	raw.resize(n + fade)
	var f := Biquad.new().setup("bandpass", freq, q)
	for i in 2000: f.run(rng.randf_range(-1.0, 1.0))
	for i in n + fade: raw[i] = f.run(rng.randf_range(-1.0, 1.0)) * gain
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var x := raw[i]
		if i < fade:
			var k := float(i) / fade
			x = x * sqrt(k) + raw[n + i] * sqrt(1.0 - k)
		# The blade going past: loudness beating at a whole number of beats a loop.
		if am > 0.0: x *= (1.0 - am) + am * (0.5 + 0.5 * sin(TAU * am_hz * float(i) / RATE))
		out[i] = x
	return out

static func _pcm(samples: PackedFloat32Array, gain := 1.0) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(samples.size() * 2)
	for i in samples.size():
		out.encode_s16(i * 2, int(clampf(samples[i] * gain, -1.0, 1.0) * 32767.0))
	return out

## Every sound, as 16-bit mono samples at RATE: { name: PackedByteArray }.
## Names ending in "_loop" are loops.
static func build_all() -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261012
	var out := {}
	for i in 4: out["impact_w%d" % i] = _pcm(_impact(rng, false))
	for i in 2: out["impact_r%d" % i] = _pcm(_impact(rng, true, 0.8))
	# A part giving way: a heavier crunch, and a fire's whoomph for a battery.
	var b := _buf(1.0)
	_noise(b, rng, "lowpass", 3000.0, 200.0, 0.7, 0.45, 0.01, 0.5)
	out["break"] = _pcm(b)
	b = _buf(1.5)
	_noise(b, rng, "lowpass", 600.0, 200.0, 0.7, 0.8, 0.01, 1.2)
	out["break_battery"] = _pcm(b)
	# The pulverizer: a pneumatic hiss, then the hammer landing.
	b = _buf(1.2)
	_noise(b, rng, "highpass", 2500.0, 2500.0, 0.7, 0.25, 0.01, 0.35)
	_mix(b, _impact(rng, true, 0.8), 0.26)
	out["pulverizer"] = _pcm(b)
	# A killsaw winding up out of the deck.
	b = _buf(1.3)
	var raw := _buf(1.3)
	_tone(raw, "saw", 120.0, 900.0, 0.7, 0.5, 0.05, 1.1)
	var bp := Biquad.new().setup("bandpass", 1500.0, 1.5)
	for i in raw.size(): b[i] = bp.run(raw[i]) * 1.2
	out["killsaw"] = _pcm(b)
	# The pit: a deep rumble as the floor goes.
	b = _buf(3.0)
	_noise(b, rng, "lowpass", 160.0, 160.0, 0.7, 1.0, 0.2, 2.5)
	_tone(b, "sine", 55.0, 35.0, 2.5, 0.5, 0.2, 2.4, 0.0, false)
	out["pit"] = _pcm(b)
	# A screw chewing.
	b = _buf(0.8)
	_noise(b, rng, "bandpass", 450.0, 450.0, 3.0, 0.5, 0.02, 0.6, 0.0, 28.0, 0.5)
	out["grind"] = _pcm(b)
	# The bell: struck metal partials, three times.
	b = _buf(1.8)
	for k in 3:
		for pr in [[880.0, 0.25], [2350.0, 0.12], [3900.0, 0.06]]:
			_tone(b, "sine", pr[0], pr[0], 1.0, pr[1], 0.003, 0.9, k * 0.32)
	out["bell"] = _pcm(b)
	# The start horn: three saws through a lowpass.
	var n := int(1.0 * RATE)
	b = _buf(1.0)
	var lp := Biquad.new().setup("lowpass", 1800.0, 0.7)
	var ph := [0.0, 0.0, 0.0]
	var fr := [233.0, 277.0, 349.0]
	for i in n:
		var t := float(i) / RATE
		var x := 0.0
		for k in 3:
			ph[k] += fr[k] / RATE
			x += _wave("saw", ph[k])
		var g := minf(1.0, t / 0.03) * (1.0 if t < 0.8 else maxf(0.0, 1.0 - (t - 0.8) / 0.15))
		b[i] = lp.run(x) * 0.12 * g
	out["horn"] = _pcm(b)
	# A beep (the count, the countdown, the pit's alarm): a square at 880 Hz,
	# played faster or slower for other notes.
	for spec in [["beep", 0.12], ["beep_long", 0.32]]:
		n = int((spec[1] + 0.02) * RATE)
		b = _buf(spec[1] + 0.02)
		lp = Biquad.new().setup("lowpass", 3000.0, 0.7)
		var phase := 0.0
		for i in n:
			phase += 880.0 / RATE
			b[i] = lp.run(_wave("square", phase)) * (0.15 if float(i) / RATE < spec[1] else 0.0)
		out[spec[0]] = _pcm(b)
	# A flipper or hammer firing.
	b = _buf(0.9)
	_noise(b, rng, "bandpass", 3000.0, 3000.0, 0.5, 0.35, 0.005, 0.3)
	var thud := _impact(rng, true, 0.8)
	for i in thud.size(): thud[i] *= 0.4
	_mix(b, thud, 0.0)
	out["pneumatic"] = _pcm(b)

	# ---- loops
	# Drive: two detuned waves through a lowpass (brushless motors and gearboxes).
	out["drive_loop"] = _pcm(_loop_tone(2.0, [["saw", 55.0, 0.5], ["square", 82.5, 0.32], ["saw", 55.5, 0.25]], 520.0), 0.9)
	# A spinner: a rising whine...
	out["whine_loop"] = _pcm(_loop_tone(1.0, [["triangle", 80.0, 0.7], ["triangle", 161.0, 0.2]]), 0.9)
	# ...and the whoosh of the blade going past.
	out["whoosh_loop"] = _pcm(_loop_noise(rng, 2.0, 900.0, 0.7, 1.6, 4.0, 0.75))
	# The crowd: a bed of murmur in two bands of noise, and a voice band for the "ooh".
	out["crowd_low_loop"] = _pcm(_loop_noise(rng, 4.0, 420.0, 0.7, 1.5))
	out["crowd_high_loop"] = _pcm(_loop_noise(rng, 4.0, 1300.0, 0.9, 1.5))
	out["crowd_voice_loop"] = _pcm(_loop_noise(rng, 3.0, 700.0, 4.0, 3.0))
	return out

## A sound as something the engine can play.
static func stream(pcm: PackedByteArray, loop: bool) -> AudioStreamWAV:
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = pcm
	if loop:
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
		s.loop_begin = 0
		s.loop_end = pcm.size() / 2
	return s
