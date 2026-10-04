extends RefCounted

## The build's console, recorded from start so the error a tester saw before opening the Console
## panel is already there (Feedback & tools).
##
## A fixed ring of CAPACITY short entries. Godot logs from any thread, so every access holds a
## mutex. Recording is one lock and one append; formatting happens only when the panel or Copy asks.

const CAPACITY := 300
const MAX_ENTRY := 2000
enum Level { LOG, WARNING, ERROR }

## Changes whenever an entry is added or the buffer cleared, so a panel redraws only when needed.
var version := 0

var _ring := []
var _next := 0
var _count := 0
var _mutex := Mutex.new()


func _init() -> void:
	_ring.resize(CAPACITY)


## Records one entry. `time` is a Unix time in seconds; leave it at -1 for now.
func add(level: int, message: String, time := -1.0) -> void:
	var text := message.strip_edges(false, true)
	if text.length() > MAX_ENTRY:
		text = text.left(MAX_ENTRY - 1) + "…"
	var entry := {"time": Time.get_unix_time_from_system() if time < 0 else time, "level": level, "text": text}
	_mutex.lock()
	_ring[_next] = entry
	_next = (_next + 1) % CAPACITY
	_count = mini(_count + 1, CAPACITY)
	version += 1
	_mutex.unlock()


## The recorded entries, oldest first: each {"time", "level", "text"}.
func entries() -> Array:
	_mutex.lock()
	var result := []
	for i in _count:
		result.append(_ring[(_next - _count + i + CAPACITY) % CAPACITY])
	_mutex.unlock()
	return result


func clear() -> void:
	_mutex.lock()
	_ring.fill(null)
	_next = 0
	_count = 0
	version += 1
	_mutex.unlock()


## The log as plain text, one line per entry: the form Copy and comments use, the same as the web
## and Unity SDKs ("HH:MM:SS.mmm [level] text").
func text() -> String:
	var lines := PackedStringArray()
	for entry in entries():
		lines.append("%s [%s] %s" % [clock(entry.time, true), label(entry.level), entry.text])
	return "\n".join(lines)


static func label(level: int) -> String:
	if level == Level.WARNING:
		return "warn"
	if level == Level.ERROR:
		return "error"
	return "log"


## Local wall-clock time, with milliseconds when asked.
static func clock(unix: float, millis := false) -> String:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var t := Time.get_time_dict_from_unix_time(int(unix) + bias)
	var base := "%02d:%02d:%02d" % [t.hour, t.minute, t.second]
	if not millis:
		return base
	return base + ".%03d" % int(fposmod(unix, 1.0) * 1000.0)
