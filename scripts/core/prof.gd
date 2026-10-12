## prof.gd - crude section timers for finding slow spots in the logic.
##   var t := Prof.t(); ...; Prof.add("name", t)      then Prof.report()
class_name Prof

static var acc := {}
static var calls := {}

static func t() -> int:
	return Time.get_ticks_usec()

static func add(name: String, t0: int) -> void:
	acc[name] = acc.get(name, 0) + (Time.get_ticks_usec() - t0)
	calls[name] = calls.get(name, 0) + 1

static func report() -> void:
	var names := acc.keys()
	names.sort_custom(func(a, b): return acc[a] > acc[b])
	for n in names: print("  %-28s %8.1f ms  %7d calls" % [n, acc[n] / 1000.0, calls[n]])
	acc.clear()
	calls.clear()
