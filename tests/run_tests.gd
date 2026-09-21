extends SceneTree

## Engine-free tests for the native transport, run headless:
##
##   godot --headless --path . --script tests/run_tests.gd
##
## The two scripts under test take their HTTP, their delay and their clock as arguments precisely
## so this file can hold all three still. Nothing here touches the network, and a test that waits
## twenty minutes for a pairing deadline finishes instantly because the clock is a variable.

const PairingFlow := preload("res://addons/prototir/native/pairing_flow.gd")
const SessionRecorder := preload("res://addons/prototir/native/session_recorder.gd")
const ExportMenu := preload("res://addons/prototir/export_menu.gd")
const SessionQueue := preload("res://addons/prototir/native/session_queue.gd")

var _checks := 0
var _failures := 0
var _current := ""


class Clock:
	extends RefCounted
	var ms := 0
	func now() -> int:
		return ms


## Answers from a queue, and records what it was asked. Deliberately not a coroutine: awaiting a
## plain value returns it immediately, which keeps every test synchronous.
class FakeHttp:
	extends RefCounted
	var responses := []
	var calls := []
	func post_json(url: String, body: String, token: String) -> Dictionary:
		calls.append({"url": url, "body": body, "token": token})
		if responses.is_empty():
			return {"status": 0, "body": ""}
		return responses.pop_front()


## Advances the clock instead of sleeping, so a poll loop runs at full speed while still moving
## towards its deadline exactly as it would in real time.
class FakeDelay:
	extends RefCounted
	var waits := []
	var _clock: Clock
	func _init(clock: Clock) -> void:
		_clock = clock
	func wait(seconds: float) -> void:
		waits.append(seconds)
		_clock.ms += int(seconds * 1000.0)


func _initialize() -> void:
	await _run_all()
	print("\n%d checks, %d failed" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _run_all() -> void:
	_recorder_tests()
	await _pairing_tests()
	_queue_tests()
	_export_menu_tests()


# --- session recorder ---------------------------------------------------------------------------

func _recorder_tests() -> void:
	var clock := Clock.new()
	var recorder := SessionRecorder.new(clock.now)

	_current = "a session with no sign of life is not reported"
	_check(not recorder.has_anything_to_report())

	_current = "ready starts the clock and duration follows it"
	recorder.ready()
	clock.ms = 4321
	_check(recorder.has_anything_to_report())
	_check_eq(recorder.snapshot()["durationMs"], 4321)

	_current = "calling ready again does not restart the clock"
	recorder.ready()
	_check_eq(recorder.snapshot()["durationMs"], 4321)

	_current = "an event without ready still gives the session a real duration"
	var bare := SessionRecorder.new(clock.now)
	clock.ms = 1000
	bare.event("jump")
	clock.ms = 3000
	_check_eq(bare.snapshot()["durationMs"], 2000)

	_current = "signals are ordered by count, then by name"
	var counted := SessionRecorder.new(clock.now)
	for i in 3:
		counted.event("jump")
	counted.event("zeta")
	counted.event("alpha")
	var signals: Array = counted.snapshot()["signals"]
	_check_eq(signals.size(), 3)
	_check_eq(signals[0], {"name": "jump", "count": 3})
	_check_eq(signals[1], {"name": "alpha", "count": 1})
	_check_eq(signals[2], {"name": "zeta", "count": 1})
	_check_eq(counted.snapshot()["eventCount"], 5)

	_current = "past the cap the total still counts but the breakdown stops growing"
	var flooded := SessionRecorder.new(clock.now)
	for i in SessionRecorder.MAX_DISTINCT_SIGNALS + 20:
		flooded.event("event_%d" % i)
	_check_eq(flooded.snapshot()["signals"].size(), SessionRecorder.MAX_DISTINCT_SIGNALS)
	_check_eq(flooded.snapshot()["eventCount"], SessionRecorder.MAX_DISTINCT_SIGNALS + 20)

	_current = "an already counted name still increments past the cap"
	flooded.event("event_0")
	_check_eq(flooded.snapshot()["signals"][0], {"name": "event_0", "count": 2})

	_current = "event names are normalized the way the platform normalizes them"
	_check_eq(SessionRecorder.normalize_event_name("  Level.Up  "), "level.up")
	_check_eq(SessionRecorder.normalize_event_name("a-b:c_d.9"), "a-b:c_d.9")
	_check_eq(SessionRecorder.normalize_event_name(""), "")
	_check_eq(SessionRecorder.normalize_event_name("   "), "")
	_check_eq(SessionRecorder.normalize_event_name("has space"), "")
	_check_eq(SessionRecorder.normalize_event_name("hash#tag"), "")
	_check_eq(SessionRecorder.normalize_event_name("x".repeat(65)), "")
	_check_eq(SessionRecorder.normalize_event_name("x".repeat(64)).length(), 64)

	_current = "a rejected name changes nothing at all"
	var strict := SessionRecorder.new(clock.now)
	strict.event("has space")
	_check(not strict.has_anything_to_report())
	_check_eq(strict.snapshot()["eventCount"], 0)

	_current = "a play that never scored reports no score, because zero is a real score"
	var scored := SessionRecorder.new(clock.now)
	_check(not scored.snapshot().has("score"))

	_current = "the session keeps the best score, not the last"
	scored.score(70.0)
	scored.score(120.4)
	scored.score(30.0)
	_check_eq(scored.snapshot()["score"], 120)

	_current = "a real score of zero is still reported"
	var zeroed := SessionRecorder.new(clock.now)
	zeroed.score(0.0)
	_check_eq(zeroed.snapshot()["score"], 0)

	_current = "a score that is not a number is ignored rather than reported"
	scored.score(NAN)
	scored.score(INF)
	_check_eq(scored.snapshot()["score"], 120)

	_current = "scoring alone does not make a session worth reporting"
	var only_score := SessionRecorder.new(clock.now)
	only_score.score(10.0)
	_check(not only_score.has_anything_to_report())

	_current = "a session the server has not seen does not claim an id"
	# The server models it as an optional GUID: an empty string is unparseable, it answers 500,
	# and the queue treats 5xx as retry-later, so every session piles up and none are sent.
	_check(not counted.snapshot().has("sessionId"))

	_current = "the session id travels in the payload so a second flush updates one row"
	counted.session_id = "sess_123"
	_check_eq(counted.snapshot()["sessionId"], "sess_123")

	_current = "reset clears everything, including the id"
	counted.reset()
	_check(not counted.has_anything_to_report())
	_check_eq(counted.snapshot()["eventCount"], 0)
	_check_eq(counted.snapshot()["signals"], [])
	_check(not counted.snapshot().has("sessionId"))


# --- pairing flow -------------------------------------------------------------------------------

func _pairing_tests() -> void:
	_current = "a token is finished only when the server refuses it outright"
	_check(PairingFlow.is_token_terminal(401))
	_check(PairingFlow.is_token_terminal(403))
	_check(not PairingFlow.is_token_terminal(404))
	_check(not PairingFlow.is_token_terminal(500))
	_check(not PairingFlow.is_token_terminal(0))

	_current = "a missing interval falls back to the floor rather than to zero"
	_check_eq(PairingFlow.interval(0.0), PairingFlow.DEFAULT_POLL_INTERVAL)
	_check_eq(PairingFlow.interval(-3.0), PairingFlow.DEFAULT_POLL_INTERVAL)
	_check_eq(PairingFlow.interval(2.0), 2.0)

	_current = "the QR arrives as a data URL and is handed over as SVG"
	var svg := "<svg/>"
	_check_eq(
		PairingFlow.decode_qr("data:image/svg+xml;base64," + Marshalls.utf8_to_base64(svg)), svg)

	_current = "a QR that cannot be decoded costs the code and the link nothing"
	_check_eq(PairingFlow.decode_qr("data:image/svg+xml;base64,!!!not base64!!!"), "")
	_check_eq(PairingFlow.decode_qr("https://example.com/qr.svg"), "")
	_check_eq(PairingFlow.decode_qr(""), "")

	_current = "start asks the prototype pairing endpoint and reports what to show"
	var clock := Clock.new()
	var http := FakeHttp.new()
	http.responses.append({"status": 200, "body": JSON.stringify({
		"code": "ABCD-1234",
		"verificationUrl": "https://prototir.com/pair",
		"qrSvgDataUrl": "data:image/svg+xml;base64," + Marshalls.utf8_to_base64("<svg/>"),
		"prototypeTitle": "My game",
		"expiresInSeconds": 600,
		"intervalSeconds": 3,
	})})
	var flow := PairingFlow.new(http, FakeDelay.new(clock), clock.now, "https://prototir.com/api/", "my game")
	var request: Dictionary = await flow.start("Studio PC", "build-1")
	_check_eq(request.get("code"), "ABCD-1234")
	_check_eq(request.get("prototype_title"), "My game")
	_check_eq(request.get("qr_svg"), "<svg/>")
	_check_eq(request.get("expires_in"), 600.0)
	_check_eq(request.get("poll_interval"), 3.0)

	_current = "the slug is escaped, the trailing slash on the base is not doubled"
	_check_eq(http.calls[0]["url"], "https://prototir.com/api/prototypes/my%20game/pair")

	_current = "the device label and build id are what the tester approves against"
	var sent: Dictionary = JSON.parse_string(http.calls[0]["body"])
	_check_eq(sent.get("deviceLabel"), "Studio PC")
	_check_eq(sent.get("buildId"), "build-1")
	_check_eq(http.calls[0]["token"], "")

	_current = "a refused or empty start is reported as no request at all"
	_check_eq(await _start_with({"status": 403, "body": ""}), {})
	_check_eq(await _start_with({"status": 200, "body": "{}"}), {})
	_check_eq(await _start_with({"status": 200, "body": "not json"}), {})
	_check_eq(await _start_with({"status": 0, "body": ""}), {})

	_current = "a start without an interval still polls at the floor"
	var defaulted: Dictionary = await _start_with({"status": 200, "body": JSON.stringify({"code": "X"})})
	_check_eq(defaulted.get("poll_interval"), PairingFlow.DEFAULT_POLL_INTERVAL)
	_check_eq(defaulted.get("expires_in"), 1.0)

	_current = "approval hands back the token"
	var approved: Dictionary = await _poll([
		{"status": 202, "body": JSON.stringify({"pending": true})},
		{"status": 200, "body": JSON.stringify({"token": "tok_1"})},
	], 600.0, 5.0)
	_check_eq(approved["result"].get("outcome"), PairingFlow.Outcome.APPROVED)
	_check_eq(approved["result"].get("token"), "tok_1")

	_current = "the server owns the cadence"
	var paced: Dictionary = await _poll([
		{"status": 202, "body": JSON.stringify({"intervalSeconds": 11})},
		{"status": 202, "body": JSON.stringify({"pending": true})},
		{"status": 200, "body": JSON.stringify({"token": "tok_2"})},
	], 600.0, 5.0)
	_check_eq(paced["delay"].waits, [11.0, 11.0])

	_current = "an approval with no token is a failure, not a silent success"
	var empty: Dictionary = await _poll([{"status": 200, "body": "{}"}], 600.0, 5.0)
	_check_eq(empty["result"].get("outcome"), PairingFlow.Outcome.FAILED)
	_check(str(empty["result"].get("message")).contains("no token"))

	_current = "410 is final and says nothing about which codes exist"
	var gone: Dictionary = await _poll([{"status": 410, "body": ""}], 600.0, 5.0)
	_check_eq(gone["result"].get("outcome"), PairingFlow.Outcome.EXPIRED)

	_current = "400 stops rather than looping on a code the server will never take"
	var refused: Dictionary = await _poll([{"status": 400, "body": ""}], 600.0, 5.0)
	_check_eq(refused["result"].get("outcome"), PairingFlow.Outcome.FAILED)

	_current = "a dropped request does not make the tester start over"
	var flaky: Dictionary = await _poll([
		{"status": 0, "body": ""},
		{"status": 500, "body": ""},
		{"status": 200, "body": JSON.stringify({"token": "tok_3"})},
	], 600.0, 5.0)
	_check_eq(flaky["result"].get("outcome"), PairingFlow.Outcome.APPROVED)
	_check_eq(flaky["http"].calls.size(), 3)

	_current = "nobody approving in time expires, and it stops polling"
	var late: Dictionary = await _poll([], 12.0, 5.0)
	_check_eq(late["result"].get("outcome"), PairingFlow.Outcome.EXPIRED)
	_check(str(late["result"].get("message")).contains("in time"))
	# Four polls, not two: the deadline is checked after each answer, so the last wait is allowed
	# to overshoot rather than cutting a tester off mid-approval.
	_check_eq(late["http"].calls.size(), 4)
	_check_eq(late["delay"].waits.size(), 3)

	_current = "a zero interval polls at the floor rather than in a tight loop"
	var floored: Dictionary = await _poll([], 12.0, 0.0)
	_check_eq(floored["delay"].waits, [
		PairingFlow.DEFAULT_POLL_INTERVAL,
		PairingFlow.DEFAULT_POLL_INTERVAL,
		PairingFlow.DEFAULT_POLL_INTERVAL,
	])

	_current = "cancelling is not a failure"
	var cancel_clock := Clock.new()
	var cancel_http := FakeHttp.new()
	var cancelled_flow := PairingFlow.new(
		cancel_http, FakeDelay.new(cancel_clock), cancel_clock.now, "https://prototir.com/api", "slug")
	cancelled_flow.cancel()
	var cancelled: Dictionary = await cancelled_flow.await_approval("ABCD", 600.0, 5.0)
	_check_eq(cancelled.get("outcome"), PairingFlow.Outcome.CANCELLED)
	_check_eq(cancel_http.calls.size(), 0)

	_current = "polling posts the code, unauthenticated, to the poll endpoint"
	var polled: Dictionary = await _poll([{"status": 410, "body": ""}], 600.0, 5.0)
	var poll_http: FakeHttp = polled["http"]
	_check_eq(poll_http.calls[0]["url"], "https://prototir.com/api/prototypes/slug/pair/poll")
	_check_eq(JSON.parse_string(poll_http.calls[0]["body"]).get("code"), "ABCD")
	_check_eq(poll_http.calls[0]["token"], "")


func _start_with(response: Dictionary) -> Dictionary:
	var clock := Clock.new()
	var http := FakeHttp.new()
	http.responses.append(response)
	var flow := PairingFlow.new(http, FakeDelay.new(clock), clock.now, "https://prototir.com/api", "slug")
	return await flow.start("Device", "")


func _poll(responses: Array, timeout: float, interval: float) -> Dictionary:
	var clock := Clock.new()
	var http := FakeHttp.new()
	http.responses = responses.duplicate()
	var delay := FakeDelay.new(clock)
	var flow := PairingFlow.new(http, delay, clock.now, "https://prototir.com/api", "slug")
	var result: Dictionary = await flow.await_approval("ABCD", timeout, interval)
	return {"result": result, "http": http, "delay": delay}


# --- session queue ------------------------------------------------------------------------------

func _queue_tests() -> void:
	var directory := "user://queue_test_%d" % Time.get_ticks_usec()
	var queue := SessionQueue.new(directory)

	_current = "a queue nobody has written to is empty, not an error"
	_check_eq(queue.pending().size(), 0)

	_current = "a stored session comes back exactly as it was written"
	_check(queue.store({"durationMs": 1200, "eventCount": 3, "sessionId": "sess_a"}))
	_check_eq(queue.pending().size(), 1)
	var body: Dictionary = JSON.parse_string(queue.read(queue.pending()[0]))
	_check_eq(body.get("durationMs"), 1200)
	_check_eq(body.get("sessionId"), "sess_a")

	_current = "two sessions stored back to back do not overwrite each other"
	queue.store({"durationMs": 2400})
	_check_eq(queue.pending().size(), 2)

	_current = "sessions come back oldest first, so plays land in the order they happened"
	var paths := queue.pending()
	_check_eq(int(JSON.parse_string(queue.read(paths[0])).get("durationMs")), 1200)
	_check_eq(int(JSON.parse_string(queue.read(paths[1])).get("durationMs")), 2400)

	_current = "a sent session is dropped, and dropping one twice is harmless"
	queue.discard(paths[0])
	queue.discard(paths[0])
	_check_eq(queue.pending().size(), 1)

	_current = "a build that never reaches the network keeps the newest plays, not every play"
	var full := SessionQueue.new(directory + "_full")
	for i in SessionQueue.MAX_PENDING + 5:
		full.store({"durationMs": i})
	_check_eq(full.pending().size(), SessionQueue.MAX_PENDING)
	var oldest_kept = JSON.parse_string(full.read(full.pending()[0])).get("durationMs")
	_check_eq(int(oldest_kept), 5)
	var newest_kept = JSON.parse_string(full.read(full.pending()[-1])).get("durationMs")
	_check_eq(int(newest_kept), SessionQueue.MAX_PENDING + 4)

	for path in queue.pending():
		queue.discard(path)
	for path in full.pending():
		full.discard(path)


# --- export buttons ---------------------------------------------------------------------------

func _export_menu_tests() -> void:
	var menu = ExportMenu.new(null)
	var path := "user://test_export_presets.cfg"

	_current = "a preset is matched by platform, and its options section is not mistaken for one"
	var config := ConfigFile.new()
	config.set_value("preset.0", "name", "Web")
	config.set_value("preset.0", "platform", "Web")
	config.set_value("preset.0", "export_path", "build/index.html")
	config.set_value("preset.0.options", "platform", "Web")
	config.set_value("preset.1", "name", "Win")
	config.set_value("preset.1", "platform", "Windows Desktop")
	config.set_value("preset.1", "export_path", "build/game.exe")
	config.save(path)
	_check_eq(menu._find_preset(["Web"], path).get("section"), "preset.0")
	_check_eq(menu._find_preset(["Windows Desktop"], path).get("name"), "Win")
	_check_eq(menu._find_preset(["macOS"], path), {})
	_check_eq(menu._find_preset(["Web"], "user://does_not_exist.cfg"), {})

	_current = "the unused transport is excluded from the preset that ships it"
	menu._exclude_other_transport(menu._find_preset(["Web"], path), ExportMenu.WEB_EXCLUDES, path)
	var written := ConfigFile.new()
	written.load(path)
	_check_eq(written.get_value("preset.0", "exclude_filter"), ExportMenu.WEB_EXCLUDES)

	_current = "a filter the creator already set is kept, and the pattern is not added twice"
	written.set_value("preset.1", "exclude_filter", "*.psd")
	written.save(path)
	for i in 2:
		menu._exclude_other_transport(
			menu._find_preset(["Windows Desktop"], path), ExportMenu.DOWNLOAD_EXCLUDES, path)
	var reread := ConfigFile.new()
	reread.load(path)
	_check_eq(reread.get_value("preset.1", "exclude_filter"), "*.psd," + ExportMenu.DOWNLOAD_EXCLUDES)

	_current = "the executable name comes from the preset, so the platform gets the extension it needs"
	_check_eq(menu._executable_name({"export_path": "build/My Game.exe"}), "My Game.exe")
	_check_eq(menu._executable_name({"export_path": ""}).is_empty(), false)

	_current = "the archive holds every file, including the ones in subfolders"
	var folder := OS.get_user_data_dir().path_join("ziptest")
	DirAccess.make_dir_recursive_absolute(folder.path_join("data/deep"))
	FileAccess.open(folder.path_join("index.html"), FileAccess.WRITE).store_string("<html>")
	FileAccess.open(folder.path_join("data/deep/pack.bin"), FileAccess.WRITE).store_string("bytes")
	var archive := OS.get_user_data_dir().path_join("ziptest.zip")
	_check(menu._zip(folder, archive))
	var reader := ZIPReader.new()
	_check_eq(reader.open(archive), OK)
	# ZIPPacker also records the folders it walked through, which every unpacker ignores.
	var names := Array(reader.get_files())
	_check(names.has("index.html"))
	_check(names.has("data/deep/pack.bin"))
	_check_eq(reader.read_file("data/deep/pack.bin").get_string_from_utf8(), "bytes")
	reader.close()

	_current = "a re-export leaves nothing of the previous one behind"
	menu._remove_tree(folder)
	_check(not DirAccess.dir_exists_absolute(folder))


# --- harness ------------------------------------------------------------------------------------

func _check(condition: bool) -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % _current)


func _check_eq(actual, expected) -> void:
	_checks += 1
	if actual == expected:
		return
	_failures += 1
	printerr("FAIL: %s\n  expected %s\n  actual   %s" % [_current, expected, actual])
