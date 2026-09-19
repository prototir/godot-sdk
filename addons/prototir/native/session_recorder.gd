extends RefCounted

## Accumulates a play so it can be reported as one session.
##
## The browser shell watches a prototype and reports for it. A download has no shell, so the build
## must keep its own count and send one session rather than a call per event: the endpoint records
## a session, and a request per event() would be both wrong and a good way to burn a connection.
##
## No class_name on purpose: web exports strip this folder (see export_guard.gd), and a stripped
## script that is still in the global class list fails to resolve at load.

## Distinct event names kept. Past this the counts still accumulate into the total, but the
## per-name breakdown stops growing: a runaway loop generating unique names must not turn one
## session into an unbounded payload.
##
## The same number the server keeps. Sending more would not record more: the server drops the
## surplus silently, so a larger number here would only mean a bigger payload and a different
## answer to "how many events can I use" depending on who you ask.
const MAX_DISTINCT_SIGNALS := 50
const MAX_EVENT_NAME_LENGTH := 64

## Set once the server has given this session a row, so a later flush updates it instead of
## recording a second session for the same play.
var session_id := ""

var _now_ms: Callable
var _started_at := -1
var _event_count := 0
var _score := 0.0
var _has_score := false
var _signals := {}


## now_ms returns milliseconds from any monotonic source, so a test can hold the clock still.
func _init(now_ms: Callable) -> void:
	_now_ms = now_ms


## The scene is interactive. Called again mid-session it is ignored rather than restarting the
## clock, because a game that calls it from two places should not silently halve its own play time.
func ready() -> void:
	if _started_at < 0:
		_started_at = int(_now_ms.call())


func event(name: String) -> void:
	var normalized := normalize_event_name(name)
	if normalized.is_empty():
		return
	# The clock starts at the first sign of life, whichever it is: a build that reports events
	# without ever calling ready() still has a real duration.
	if _started_at < 0:
		_started_at = int(_now_ms.call())
	_event_count += 1
	if _signals.has(normalized):
		_signals[normalized] += 1
	elif _signals.size() < MAX_DISTINCT_SIGNALS:
		_signals[normalized] = 1


## The best score of the session. A run that ends badly should not erase what the player already
## achieved, and the leaderboard takes the maximum anyway.
func score(value: float) -> void:
	if is_nan(value) or is_inf(value):
		return
	if not _has_score or value > _score:
		_score = value
		_has_score = true


func has_anything_to_report() -> bool:
	return _started_at >= 0


func snapshot() -> Dictionary:
	var duration := 0
	if _started_at >= 0:
		duration = maxi(0, int(_now_ms.call()) - _started_at)

	var ordered := _signals.keys()
	# Count descending, then name ascending, so the payload is stable between two flushes of the
	# same session and a diff of two uploads means something.
	ordered.sort_custom(func(a: String, b: String) -> bool:
		if _signals[a] == _signals[b]:
			return a < b
		return _signals[a] > _signals[b])

	var signals := []
	for name in ordered:
		signals.append({"name": name, "count": _signals[name]})

	return {
		"durationMs": duration,
		"eventCount": _event_count,
		"score": int(round(_score)) if _has_score else 0,
		"hasScore": _has_score,
		"signals": signals,
		"sessionId": session_id,
	}


func reset() -> void:
	_started_at = -1
	_event_count = 0
	_score = 0.0
	_has_score = false
	_signals.clear()
	session_id = ""


## Matches the name rule the platform already enforces, so a name the browser path would accept is
## not silently dropped natively, or the reverse. Returns "" when the name is unusable.
static func normalize_event_name(name: String) -> String:
	var trimmed := name.strip_edges().to_lower()
	if trimmed.is_empty() or trimmed.length() > MAX_EVENT_NAME_LENGTH:
		return ""
	for index in trimmed.length():
		var c := trimmed.unicode_at(index)
		var ok := (c >= 97 and c <= 122) or (c >= 48 and c <= 57)
		ok = ok or c == 95 or c == 46 or c == 58 or c == 45
		if not ok:
			return ""
	return trimmed
