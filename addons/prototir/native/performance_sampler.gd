extends RefCounted

## Frame rate, slowest frame and memory while the Performance panel is open (Feedback & tools).
##
## Fed one frame time per frame, and only while the panel is open, so a build pays nothing for it
## otherwise. Frames are folded into BUCKET_SECONDS samples and one minute (HISTORY) is kept.

const BUCKET_SECONDS := 0.25
const HISTORY := 240

## Each {"fps", "worst_ms", "memory_mb"}; memory_mb is negative when unknown.
var samples := []
var version := 0

var _bucket_time := 0.0
var _worst := 0.0
var _recorded := 0.0
var _frames := 0


## Records one frame. Returns true when a new sample was completed.
func add_frame(delta: float, memory_mb := -1.0) -> bool:
	if delta <= 0.0 or is_nan(delta):
		return false
	_frames += 1
	_bucket_time += delta
	_recorded += delta
	_worst = maxf(_worst, delta * 1000.0)
	if _bucket_time < BUCKET_SECONDS:
		return false
	samples.append({"fps": _frames / _bucket_time, "worst_ms": _worst, "memory_mb": memory_mb})
	if samples.size() > HISTORY:
		samples.pop_front()
	_bucket_time = 0.0
	_frames = 0
	_worst = 0.0
	version += 1
	return true


func reset() -> void:
	samples.clear()
	_bucket_time = 0.0
	_frames = 0
	_worst = 0.0
	_recorded = 0.0
	version += 1


## A plain-text summary for Copy and comments, in the web and Unity SDKs' form.
func summary(platform: String) -> String:
	if samples.is_empty():
		return "No performance recorded yet."
	var fps := []
	var worst := 0.0
	var low_memory := INF
	var high_memory := -INF
	var total := 0.0
	for sample in samples:
		fps.append(sample.fps)
		total += sample.fps
		worst = maxf(worst, sample.worst_ms)
		if sample.memory_mb >= 0.0:
			low_memory = minf(low_memory, sample.memory_mb)
			high_memory = maxf(high_memory, sample.memory_mb)
	fps.sort()
	var low: float = fps[int(floor(fps.size() * 0.01))]
	var lines := [
		"[performance] %ds recorded, %s" % [roundi(_recorded), platform],
		"[performance] average %.1f fps, lowest 1%% %.1f fps, slowest frame %.1f ms" % [total / fps.size(), low, worst],
	]
	if high_memory >= 0.0:
		lines.append("[performance] static memory %d-%d MB" % [roundi(low_memory), roundi(high_memory)])
	return "\n".join(lines)
