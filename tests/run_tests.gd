extends Node

## Tests for the native transport and pairing UI, run headless in the configured project:
##
##   node tools/run-godot.mjs --headless --path . tests/run_tests.tscn --quit-after 600
##
## The two scripts under test take their HTTP, their delay and their clock as arguments precisely
## so this file can hold all three still. Nothing here touches the network, and a test that waits
## twenty minutes for a pairing deadline finishes instantly because the clock is a variable.

const PairingFlow := preload("res://addons/prototir/native/pairing_flow.gd")
const SessionRecorder := preload("res://addons/prototir/native/session_recorder.gd")
const ExportMenu := preload("res://addons/prototir/export_menu.gd")
const SessionQueue := preload("res://addons/prototir/native/session_queue.gd")
const Setup := preload("res://addons/prototir/setup.gd")
const EditorLink := preload("res://addons/prototir/editor/editor_link.gd")
const DirectUpload := preload("res://addons/prototir/editor/direct_upload.gd")

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


## The editor's network for Publish to Prototir: JSON calls and part uploads, answered from queues.
class FakeApi:
	extends RefCounted
	var responses := []
	var puts := []
	var calls := []
	var put_calls := []
	func send(method: String, url: String, body: String, token: String) -> Dictionary:
		calls.append({"method": method, "url": url, "body": body, "token": token})
		if responses.is_empty():
			return {"status": 0, "body": ""}
		return responses.pop_front()
	func put_bytes(url: String, bytes: PackedByteArray) -> Dictionary:
		put_calls.append({"url": url, "size": bytes.size()})
		if puts.is_empty():
			return {"status": 0, "body": "", "headers": {}}
		return puts.pop_front()


## Stands in for EditorSettings, which a headless test cannot write without touching the real one.
class FakeSettings:
	extends RefCounted
	var values := {}
	func has_setting(name: String) -> bool:
		return values.has(name)
	func get_setting(name: String):
		return values.get(name)
	func set_setting(name: String, value) -> void:
		values[name] = value


func _ready() -> void:
	# Let the project finish entering the tree before exercising UI nodes and autoload signals.
	_run_tests.call_deferred()


func _run_tests() -> void:
	await _run_all()
	print("\n%d checks, %d failed" % [_checks, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _run_all() -> void:
	_recorder_tests()
	await _pairing_tests()
	_queue_tests()
	_export_menu_tests()
	await _publish_tests()
	_setup_target_tests()
	_pairing_screen_tests()
	await _feedback_screen_tests()
	await _feedback_tools_tests()


# --- publish to prototir ---------------------------------------------------------------------------

func _publish_tests() -> void:
	var api_base := "http://local.test/api"
	var settings := FakeSettings.new()

	_current = "an editor with no link has none, and a link is kept per API address"
	_check_eq(EditorLink.stored(settings, api_base), {})
	EditorLink.remember(settings, api_base, {"token": "t1", "display_name": "Ada", "app_origin": "http://local.test"})
	_check_eq(EditorLink.stored(settings, api_base).get("token"), "t1")
	_check_eq(EditorLink.stored(settings, "https://api.prototir.com/api"), {})
	EditorLink.forget(settings, api_base)
	_check_eq(EditorLink.stored(settings, api_base), {})

	_current = "a stored link is checked: 401 means unlinked, no answer keeps it for later"
	var api := FakeApi.new()
	api.responses = [
		{"status": 200, "body": '{"displayName":"Ada Lovelace"}'},
		{"status": 401, "body": ""},
		{"status": 0, "body": ""},
	]
	var link := {"token": "t1"}
	_check_eq(await EditorLink.verify(api, api_base, link), "ok")
	_check_eq(link.get("display_name"), "Ada Lovelace")
	_check_eq(await EditorLink.verify(api, api_base, link), "unlinked")
	_check_eq(await EditorLink.verify(api, api_base, link), "error")
	_check_eq(api.calls[0].url, api_base + "/editor/me")
	_check_eq(api.calls[0].token, "t1")

	_current = "linking asks for a code as a Godot editor and keeps the API's own refusal"
	api = FakeApi.new()
	api.responses = [
		{"status": 200, "body": '{"code":"ABCD-1234","verificationUrl":"http://local.test/link/editor?code=ABCD-1234","intervalSeconds":3,"expiresInSeconds":600}'},
		{"status": 429, "body": '{"error":"Too many codes."}'},
	]
	var pending: Dictionary = await EditorLink.start(api, api_base, "Godot 4 on test")
	_check_eq(pending.get("code"), "ABCD-1234")
	_check_eq(pending.get("interval"), 3)
	_check_eq(JSON.parse_string(api.calls[0].body).get("engine"), "godot")
	_check_eq((await EditorLink.start(api, api_base, "x")).get("error"), "Too many codes.")

	_current = "approval waits through 'not yet' and dropped polls, then keeps the website's origin"
	var clock := Clock.new()
	var delay := FakeDelay.new(clock)
	api = FakeApi.new()
	api.responses = [
		{"status": 202, "body": ""},
		{"status": 0, "body": ""},
		{"status": 200, "body": '{"token":"editor-token","displayName":"Ada"}'},
	]
	var approved: Dictionary = await EditorLink.wait_for_approval(api, delay, clock, api_base, pending, func() -> bool: return false)
	_check_eq(approved.get("token"), "editor-token")
	_check_eq(approved.get("app_origin"), "http://local.test")
	_check_eq(delay.waits.size(), 3)

	_current = "a dead code stops the wait, and so does nobody approving before the deadline"
	api = FakeApi.new()
	api.responses = [{"status": 410, "body": '{"error":"This code expired."}'}]
	_check_eq((await EditorLink.wait_for_approval(api, delay, clock, api_base, pending, func() -> bool: return false)).get("error"), "This code expired.")
	api = FakeApi.new()
	for i in 400:
		api.responses.append({"status": 202, "body": ""})
	var expired: Dictionary = await EditorLink.wait_for_approval(api, delay, clock, api_base, pending, func() -> bool: return false)
	_check(str(expired.get("error", "")).begins_with("Nobody approved"))

	_current = "a build is uploaded in parts, each part's ETag is kept, and the claim comes back"
	var path := "user://publish_test.zip"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer("0123456789".to_utf8_buffer())
	file.close()
	api = FakeApi.new()
	api.responses = [
		{"status": 200, "body": '{"uploadRef":"ref1","uploadId":"up 1","partSizeBytes":4,"parts":[{"partNumber":1,"url":"s3://1"},{"partNumber":2,"url":"s3://2"},{"partNumber":3,"url":"s3://3"}]}'},
		{"status": 200, "body": '{"claim":"claim-1"}'},
	]
	api.puts = [
		{"status": 200, "headers": {"etag": "e1"}},
		{"status": 0, "headers": {}},
		{"status": 200, "headers": {"etag": "e2"}},
		{"status": 200, "headers": {"etag": "e3"}},
	]
	var sent := [0]
	var uploaded: Dictionary = await DirectUpload.upload(api, delay, api_base, "editor-token", path,
		func(bytes: int) -> void: sent[0] += bytes, func() -> bool: return false)
	_check_eq(uploaded.get("claim"), "claim-1")
	_check_eq(sent[0], 10)
	_check_eq(api.put_calls.map(func(call: Dictionary) -> int: return call.size), [4, 4, 4, 2])
	var completed = JSON.parse_string(api.calls[1].body)
	_check_eq(completed.get("parts").map(func(part: Dictionary) -> String: return part.etag), ["e1", "e2", "e3"])
	_check_eq(JSON.parse_string(api.calls[0].body).get("sizeBytes"), 10.0)

	_current = "a part storage refuses stops the upload and clears the parts already sent"
	api = FakeApi.new()
	api.responses = [
		{"status": 200, "body": '{"uploadRef":"ref2","uploadId":"up2","partSizeBytes":8,"parts":[{"partNumber":1,"url":"s3://1"},{"partNumber":2,"url":"s3://2"}]}'},
		{"status": 204, "body": ""},
	]
	api.puts = [{"status": 403, "headers": {}}]
	var refused: Dictionary = await DirectUpload.upload(api, delay, api_base, "editor-token", path,
		func(_bytes: int) -> void: pass, func() -> bool: return false)
	_check(refused.has("error"))
	_check_eq(api.calls[-1].method, "DELETE")
	_check_eq(api.calls[-1].url, api_base + "/me/uploads/direct/ref2?uploadId=up2")

	_current = "an editor unlinked on the website finds out from the first call"
	api = FakeApi.new()
	api.responses = [{"status": 401, "body": ""}]
	var unlinked: Dictionary = await DirectUpload.upload(api, delay, api_base, "old", path,
		func(_bytes: int) -> void: pass, func() -> bool: return false)
	_check_eq(unlinked.get("unlinked"), true)
	_check_eq(api.put_calls.size(), 0)

	_current = "registering the upload says it came from Godot"
	api = FakeApi.new()
	api.responses = [{"status": 200, "body": '{"id":"u1"}'}]
	_check_eq(await DirectUpload.register(api, api_base, "editor-token", {"claim": "c", "kind": "native", "platform": "windows"}), {})
	var registered = JSON.parse_string(api.calls[0].body)
	_check_eq([registered.engine, registered.kind, registered.platform], ["godot", "native", "windows"])
	_check_eq(api.calls[0].url, api_base + "/editor/uploads")

	_current = "a native build is labelled with its preset's architecture, in Prototir's words"
	var menu = ExportMenu.new(null)
	var presets := "user://test_arch_presets.cfg"
	var config := ConfigFile.new()
	config.set_value("preset.0", "platform", "Windows Desktop")
	config.set_value("preset.0.options", "binary_format/architecture", "arm64")
	config.set_value("preset.1", "platform", "macOS")
	config.save(presets)
	_check_eq(menu.native_architecture({"section": "preset.0", "platform": "Windows Desktop"}, presets), "arm64")
	_check_eq(menu.native_architecture({"section": "preset.1", "platform": "macOS"}, presets), "universal")
	_check_eq(menu.native_architecture({"section": "preset.9", "platform": "Linux"}, presets), "x64")

	_current = "the website origin is read from the approval address"
	_check_eq(EditorLink.origin_of("https://prototir.com/link/editor?code=1"), "https://prototir.com")
	_check_eq(EditorLink.origin_of("http://localhost:5173/link/editor"), "http://localhost:5173")

# --- setup targets -------------------------------------------------------------------------------

## A native project must never be told to follow the Web profile: that is what the dock used to do,
## asking creators of desktop builds to switch renderer and add a Web preset they did not need.
func _setup_target_tests() -> void:
	var web_only := ["renderer", "web-preset", "threads", "extensions", "pwa", "resize", "focus", "entry", "mobile-textures"]
	var ids := func(target: String) -> Array:
		return Setup.get_issues(target).map(func(issue: Dictionary) -> String: return str(issue.get("id", "")))

	_current = "a native target reports none of the Web profile rules"
	var native_ids: Array = ids.call(Setup.TARGET_NATIVE)
	_check(not native_ids.any(func(id: String) -> bool: return web_only.has(id)))

	_current = "this project exports only for the Web, so a native target asks for a desktop preset"
	_check(native_ids.has("native-preset"))

	_current = "a web target still reports the Web profile and never the native preset"
	_check(not (ids.call(Setup.TARGET_WEB) as Array).has("native-preset"))


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
			menu._find_preset(["Windows Desktop"], path), ExportMenu.NATIVE_EXCLUDES, path)
	var reread := ConfigFile.new()
	reread.load(path)
	_check_eq(reread.get_value("preset.1", "exclude_filter"), "*.psd," + ExportMenu.NATIVE_EXCLUDES)

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


# --- pairing screen -----------------------------------------------------------------------------

## The project scene provides the real autoload. Exercise both construction and signal wiring,
## without requesting a pairing code or touching the network.
func _pairing_screen_tests() -> void:
	_current = "the pairing screen and its theme parse"
	var screen := load("res://addons/prototir/native/ui/pairing_screen.gd")
	var theme_script := load("res://addons/prototir/native/ui/prototir_theme.gd")
	_check(screen != null)
	_check(theme_script != null)

	_current = "the theme carries the webapp's own colours, not Godot defaults"
	var theme: Theme = theme_script.build()
	_check(theme.get_stylebox("panel", "PanelContainer") != null)
	_check_eq(theme.get_color("font_color", "Label"), Color("#f4f4f5"))
	_check_eq(theme_script.ACCENT, Color("#60a5fa"))

	# The QR is the whole reason pairing is bearable on a headset or a TV, where typing a code is
	# the worst part of the flow. It arrives as SVG text, so rasterising one from a string has to
	# work or the screen silently shows no QR at all.
	_current = "a QR arrives as SVG text and rasterises"
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><rect width="8" height="8" fill="#fff"/><rect x="1" y="1" width="3" height="3"/></svg>'
	var image := Image.new()
	_check_eq(image.load_svg_from_string(svg, 2.0), OK)
	_check(image.get_width() > 0)
	_check(ImageTexture.create_from_image(image) != null)

	_current = "the screen builds its interface and connects to the project autoload"
	var panel = screen.new()
	add_child(panel)
	_check(panel._heading != null)
	_check(panel._code_label != null)
	_check(panel._qr != null)
	_check_eq(panel._code_panel.visible, false)
	_check_eq(panel._qr.visible, false)
	_check_eq(panel._heading.text, "Connect this build")
	_check(Prototir.pairing_started.is_connected(panel._on_started))
	_check(Prototir.pairing_succeeded.is_connected(panel._on_succeeded))
	_check(Prototir.pairing_failed.is_connected(panel._on_failed))

	_current = "autoload pairing signals update the built-in screen"
	Prototir.pairing_started.emit({"code": "ABCD-2345", "verification_url": "https://prototir.com/link"})
	_check_eq(panel._code_label.text, "ABCD-2345")
	_check_eq(panel._code_panel.visible, true)
	Prototir.pairing_failed.emit("Test rejection")
	_check_eq(panel._body.text, "Test rejection")

	_current = "a QR that arrives is drawn, and its absence is not an error"
	panel._show_qr(svg)
	_check_eq(panel._qr.visible, true)
	panel._show_qr("")
	_check_eq(panel._qr.visible, false)
	panel.free()


# A real CanvasLayer with a fake transport: no public comment or pairing request is sent.
class FeedbackTokens:
	extends RefCounted
	func read(_slug: String) -> String:
		return "test-token"
	func write(_slug: String, _token: String) -> void:
		pass


func _feedback_screen_tests() -> void:
	var native = Prototir._native
	var old_http = native._http
	var old_tokens = native._tokens
	var old_slug: String = native._slug
	var http := FakeHttp.new()
	native._http = http
	native._tokens = FeedbackTokens.new()
	native._slug = "feedback-ui-test"
	var screen = Prototir.show_feedback_screen("A useful comment")
	_current = "feedback calls reuse one screen and never post on opening"
	_check_eq(Prototir.show_feedback_screen(), screen)
	_check_eq(http.calls.size(), 0)
	_current = "failed posting keeps the draft and retries reuse its server id"
	http.responses = [{"status": 503}, {"status": 201}]
	await screen._submit()
	_check_eq(screen._text.text, "A useful comment")
	_check(screen._status.text.contains("draft is kept"))
	var first: Dictionary = JSON.parse_string(http.calls[0].body)
	await screen._submit()
	var retry: Dictionary = JSON.parse_string(http.calls[1].body)
	_check_eq(first.clientId, retry.clientId)
	_check_eq(screen._text.text, "")
	_current = "closing and reopening retains an unfinished comment"
	screen._text.text = "Another comment"
	screen._changed()
	screen._dismiss()
	await get_tree().process_frame
	screen = Prototir.show_feedback_screen()
	_check_eq(screen._text.text, "Another comment")
	screen.free()
	native._http = old_http
	native._tokens = old_tokens
	native._slug = old_slug


# --- feedback & tools ---------------------------------------------------------------------------

func _feedback_tools_tests() -> void:
	var ConsoleBuffer := load("res://addons/prototir/native/console_buffer.gd")
	var Sampler := load("res://addons/prototir/native/performance_sampler.gd")

	_current = "the console keeps the newest entries in order"
	var buffer = ConsoleBuffer.new()
	for i in ConsoleBuffer.CAPACITY + 20:
		buffer.add(ConsoleBuffer.Level.LOG, "tick %d" % (i + 1))
	var entries: Array = buffer.entries()
	_check_eq(entries.size(), ConsoleBuffer.CAPACITY)
	_check_eq(entries[0].text, "tick 21")
	_check_eq(entries[-1].text, "tick %d" % (ConsoleBuffer.CAPACITY + 20))

	_current = "console text matches the web and Unity form, and clearing changes the version"
	buffer.clear()
	buffer.add(ConsoleBuffer.Level.WARNING, "Texture too large\n")
	buffer.add(ConsoleBuffer.Level.ERROR, "boom\n  at Player.gd:3")
	var lines: PackedStringArray = buffer.text().split("\n")
	_check(lines[0].ends_with(" [warn] Texture too large"))
	_check(lines[1].ends_with(" [error] boom"))
	_check_eq(lines[2], "  at Player.gd:3")
	var regex := RegEx.create_from_string("^\\d\\d:\\d\\d:\\d\\d\\.\\d{3} ")
	_check(regex.search(lines[0]) != null)
	var version: int = buffer.version
	buffer.clear()
	_check(buffer.entries().is_empty())
	_check(buffer.version != version)

	_current = "Godot 4.5+ records print() and errors from the start of the run"
	if Prototir._native.console_captures_engine:
		print("feedback-tools probe line")
		_check(Prototir.console_text().contains("[log] feedback-tools probe line"))

	_current = "frames fold into quarter-second samples with the slowest frame"
	var sampler = Sampler.new()
	var completed := 0
	for i in 14:
		if sampler.add_frame(1.0 / 60.0, 120.0):
			completed += 1
	if sampler.add_frame(0.05, 121.0):
		completed += 1
	_check_eq(completed, 1)
	_check(absf(sampler.samples[0].worst_ms - 50.0) < 0.5)

	_current = "one minute of history is kept and summarised"
	sampler.reset()
	for i in 60 * 70:
		sampler.add_frame(1.0 / 60.0, 100.0 + (i / 15) % 3)
	_check_eq(sampler.samples.size(), Sampler.HISTORY)
	var summary: String = sampler.summary("Windows")
	_check(summary.contains("[performance] 70s recorded, Windows"))
	_check(summary.contains("average 60.0 fps"))
	_check(summary.contains("static memory 100-102 MB"))
	_check_eq(Sampler.new().summary("Windows"), "No performance recorded yet.")

	var native = Prototir._native
	var old_http = native._http
	var old_tokens = native._tokens
	var old_slug: String = native._slug
	var http := FakeHttp.new()
	native._http = http
	native._tokens = FeedbackTokens.new()
	native._slug = "feedback-tools-test"

	_current = "a comment body leaves out what was not attached"
	http.responses = [{"status": 201}, {"status": 201}]
	await native.send_feedback("  Jump feels late ")
	_check_eq(JSON.parse_string(http.calls[0].body), {"text": "Jump feels late"})

	_current = "a comment body carries the log and a pinned screenshot"
	await native.send_feedback("Boss freezes", "", "09:00:00.000 [error] boom", {"image": "data:image/jpeg;base64,AAA", "x": 0.25, "y": 1.4})
	var body: Dictionary = JSON.parse_string(http.calls[1].body)
	_check_eq(body.console, "09:00:00.000 [error] boom")
	_check_eq(body.screenshot, {"image": "data:image/jpeg;base64,AAA", "x": 0.25, "y": 1.0})

	_current = "the composer posts its attachments and needs a message"
	var screen = Prototir.show_feedback_screen()
	await get_tree().process_frame
	var image := Image.create(320, 180, false, Image.FORMAT_RGB8)
	image.fill(Color.DARK_GREEN)
	screen.attach_screenshot(image)
	screen.attach_log("line one\nline two", "console log")
	_check_eq(screen._heading.text, "Screenshot feedback")
	_check(screen._shot_box.visible)
	_check_eq(screen._attachment_label.text, "Console log attached · 2 lines")
	screen._text.text = ""
	screen._changed()
	_check(screen._post.disabled)
	screen._text.text = "The tree clips through the wall"
	screen._changed()
	http.responses = [{"status": 201}]
	await screen._submit()
	var posted: Dictionary = JSON.parse_string(http.calls[2].body)
	_check_eq(posted.console, "line one\nline two")
	_check(str(posted.screenshot.image).begins_with("data:image/jpeg;base64,"))
	_check_eq(posted.screenshot.x, 0.5)
	_check(not screen._shot_box.visible)
	_check(not screen._attachment_box.visible)
	_check_eq(screen._heading.text, "Comment")
	screen.free()

	_current = "the tools control builds folded, with every tool off"
	native.set_tools_visible(true)
	await get_tree().process_frame
	await get_tree().process_frame
	var tools = native._tools
	_check(tools != null)
	_check(not tools._tools.visible)
	_check(not tools.is_processing())
	tools.toggle()
	_check(tools._tools.visible)
	tools.set_console(true)
	tools.set_performance(true)
	_check(tools.is_processing())
	_check_eq(tools._console_state.text, "On")
	await get_tree().process_frame
	_check(tools._console_log.get_parsed_text().length() > 0)
	tools.set_console(false)
	tools.set_performance(false)
	_check(not tools.is_processing())
	native.set_tools_visible(false)
	_check(not native.tools_visible())

	native._http = old_http
	native._tokens = old_tokens
	native._slug = old_slug


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
