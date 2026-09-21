extends Node

## Everything a downloadable build needs at runtime: where it points, the token it was given, the
## session it is accumulating, and the pairing state a game draws.
##
## The Prototir autoload creates this as a child when the build is not a Web export, and never
## touches it otherwise. Web exports strip this whole folder from the pack (see export_guard.gd),
## which is why nothing here is preloaded from prototir.gd.

const PairingFlow := preload("res://addons/prototir/native/pairing_flow.gd")
const SessionRecorder := preload("res://addons/prototir/native/session_recorder.gd")
const SessionQueue := preload("res://addons/prototir/native/session_queue.gd")
const Transport := preload("res://addons/prototir/native/native_transport.gd")

const SLUG_SETTING := "prototir/prototype_slug"
const API_BASE_SETTING := "prototir/api_base_url"
const DEVICE_LABEL_SETTING := "prototir/device_label"
## Where a downloadable build talks to Prototir.
##
## Its own hostname, not prototir.com/api: the site serves no /api path, so that default reached
## nothing and the whole native path was dead in production until a real build was run against it.
## Not the Azure hostname behind it either, which carries a generated id that changes if the app is
## recreated. This URL ships inside executables that can never be updated, so it has to outlive the
## infrastructure under it.
const DEFAULT_API_BASE := "https://api.prototir.com/api"
const BUILD_ID_FILE := "prototir-build.json"
const REVOKED_MESSAGE := "Access to this build was withdrawn. Pair it again."

## How often a play in progress is reported.
##
## Without this the only moment a session was ever sent was the next launch, so a tester who plays
## once and never opens the build again reported nothing at all, which is the most common way a
## prototype gets tried. Repeating costs no duplicates: the first report returns an id the rest
## carry, so the server updates one row.
const FLUSH_INTERVAL_SECONDS := 30.0

enum State { NOT_PAIRED, REQUESTING, AWAITING_APPROVAL, PAIRED, FAILED }

## Emitted when a pairing code is ready to show. The SDK never draws it: it cannot know the game
## art direction, its input model, or whether it is in VR.
signal pairing_started(request: Dictionary)
signal pairing_succeeded()
## A human-readable reason, meant to be shown. Also emitted when a paired build is refused later,
## which means the tester revoked it and it has to pair again.
signal pairing_failed(message: String)

var state: State = State.NOT_PAIRED

var _http
var _delay
var _tokens
var _queue
var _session
var _flow
var _slug := ""
var _api_base := DEFAULT_API_BASE
var _device_label := ""
var _configuration_warned := false
var _stored_on_close := false


func _ready() -> void:
	_http = Transport.Http.new(self)
	_delay = Transport.Delay.new(self)
	_tokens = Transport.TokenStore.new()
	_queue = SessionQueue.new()
	_session = SessionRecorder.new(Time.get_ticks_msec)
	_read_project_settings()
	if is_paired():
		state = State.PAIRED
	send_pending()

	var heartbeat := Timer.new()
	heartbeat.wait_time = FLUSH_INTERVAL_SECONDS
	heartbeat.autostart = true
	# Keeps reporting while the tree is paused, so a game sitting on its own pause menu still
	# accounts for the play it is in the middle of.
	heartbeat.process_mode = Node.PROCESS_MODE_ALWAYS
	heartbeat.timeout.connect(flush_session)
	add_child(heartbeat)


## Overrides the project settings, for a game that decides its slug at runtime.
func configure(slug: String, api_base := "", device_label := "") -> void:
	_slug = slug.strip_edges()
	if not api_base.strip_edges().is_empty():
		_api_base = api_base.strip_edges()
	if not device_label.strip_edges().is_empty():
		_device_label = device_label.strip_edges()
	_flow = null
	_configuration_warned = false
	if is_paired():
		state = State.PAIRED

	# The drain in _ready has already been and gone, and it gave up because nothing knew where to
	# send yet. This is the first moment that is true, so the queue gets its chance here too;
	# otherwise a build that learns its prototype at runtime keeps every session it ever recorded
	# and sends none of them. Cheap when the queue is empty.
	send_pending()


func is_paired() -> bool:
	return not _token().is_empty()


func ready() -> void:
	_session.ready()


func event(name: String) -> void:
	_session.event(name)


func score(value: float) -> void:
	_session.score(value)


## Sends the session so far. Safe to call repeatedly: the server updates the same row once it has
## given the session an id.
func flush_session() -> void:
	if not _session.has_anything_to_report():
		return
	if not _ensure_configured():
		return
	var token := _token()
	if token.is_empty():
		# Unpaired builds report nothing, by design.
		return

	var response: Dictionary = await _http.post_json(
		_url("sessions"), JSON.stringify(_session.snapshot()), token)
	var status := int(response.get("status", 0))
	if PairingFlow.is_token_terminal(status):
		# Revoked, or aimed at a prototype this token was not issued for. Retrying just repeats
		# the refusal.
		unpair()
		pairing_failed.emit(REVOKED_MESSAGE)
		return
	if status == 200:
		var payload := PairingFlow.parse_object(str(response.get("body", "")))
		if not str(payload.get("sessionId", "")).is_empty():
			_session.session_id = str(payload.get("sessionId", ""))


## Asks Prototir for a pairing code and waits for a tester to approve it on prototir.com. Connect
## to pairing_started to show the code, the link and the QR.
func begin_pairing() -> Dictionary:
	if not _ensure_configured():
		return _fail("This build has no Prototir settings, so it cannot be paired.")
	if state == State.REQUESTING or state == State.AWAITING_APPROVAL:
		return _fail("This build is already waiting to be paired.")

	state = State.REQUESTING
	_flow = PairingFlow.new(_http, _delay, Time.get_ticks_msec, _api_base, _slug)

	var request: Dictionary = await _flow.start(_device_label, read_build_id())
	if request.is_empty():
		return _fail("Prototir would not start a pairing for this prototype. Check the slug and "
			+ "that feedback is turned on for it.")

	state = State.AWAITING_APPROVAL
	pairing_started.emit(request)

	var result: Dictionary = await _flow.await_approval(
		str(request.get("code", "")),
		float(request.get("expires_in", 0.0)),
		float(request.get("poll_interval", 0.0)))

	var outcome := int(result.get("outcome", PairingFlow.Outcome.FAILED))
	# Reported as a string, not the internal enum: the enum lives in a script that Web exports
	# strip, so a number crossing this boundary would name something the caller cannot look up.
	result["outcome"] = describe_outcome(outcome)
	if outcome == PairingFlow.Outcome.APPROVED:
		_tokens.write(_slug, str(result.get("token", "")))
		state = State.PAIRED
		pairing_succeeded.emit()
		return result

	state = State.NOT_PAIRED if outcome == PairingFlow.Outcome.CANCELLED else State.FAILED
	if outcome != PairingFlow.Outcome.CANCELLED:
		var message := str(result.get("message", ""))
		pairing_failed.emit("Pairing did not finish." if message.is_empty() else message)
	return result


func cancel_pairing() -> void:
	if _flow != null:
		_flow.cancel()
	state = State.PAIRED if is_paired() else State.NOT_PAIRED


## Forgets the stored token, so the build pairs again next time.
func unpair() -> void:
	if not _slug.is_empty():
		_tokens.clear(_slug)
	state = State.NOT_PAIRED


## Posts feedback as the tester who approved this build.
##
## No session is needed first. Commenting is normally gated on having played, and that gate is
## waived for a paired device on purpose: approving the pairing is the stronger signal, since the
## tester signed in and authorised this exact build for this exact prototype.
func send_feedback(text: String) -> bool:
	if text.strip_edges().is_empty():
		return false
	if not _ensure_configured():
		return false
	var token := _token()
	if token.is_empty():
		pairing_failed.emit("Pair this build before sending feedback.")
		return false

	var response: Dictionary = await _http.post_json(
		_url("comments"), JSON.stringify({"text": text.strip_edges()}), token)
	var status := int(response.get("status", 0))
	if PairingFlow.is_token_terminal(status):
		unpair()
		pairing_failed.emit(REVOKED_MESSAGE)
		return false
	return status == 200 or status == 201


## The id the export plugin wrote beside the executable. Missing is normal for a build made before
## the plugin emitted one, and pairing works without it.
func read_build_id() -> String:
	var path := OS.get_executable_path().get_base_dir().path_join(BUILD_ID_FILE)
	if not FileAccess.file_exists(path):
		return ""
	return str(PairingFlow.parse_object(FileAccess.get_file_as_string(path)).get("buildId", ""))


## Both notifications, because which one arrives depends on how the game was closed and on whether
## the project accepts quit automatically. Storing twice is prevented by the flag rather than by
## guessing which one fires.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		_store_session()
	# Alt-tabbing away is where a play most often ends for good, and the tree is still running to
	# carry the request.
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		flush_session()


## A session that is never sent is a play the creator never sees, and quitting is the normal way a
## desktop game ends. There is no time to send one here, so it is written down instead.
func _store_session() -> void:
	if _stored_on_close or _queue == null:
		return
	_stored_on_close = true
	if not _session.has_anything_to_report() or _token().is_empty():
		return
	_queue.store(_session.snapshot())


## Sends what earlier runs left behind. Anything the server takes, or refuses in a way that will not
## change, is dropped; anything that failed because the network did is kept for next time.
func send_pending() -> void:
	if _slug.is_empty() or _queue == null:
		return
	var token := _token()
	if token.is_empty():
		return
	for path in _queue.pending():
		var body: String = _queue.read(path)
		if body.strip_edges().is_empty():
			_queue.discard(path)
			continue
		var response: Dictionary = await _http.post_json(_url("sessions"), body, token)
		var status := int(response.get("status", 0))
		if PairingFlow.is_token_terminal(status):
			unpair()
			pairing_failed.emit(REVOKED_MESSAGE)
			return
		if status == 0 or status >= 500:
			# Offline, or the server is unwell. Keeping the rest is the whole point of the queue.
			return
		_queue.discard(path)


func _read_project_settings() -> void:
	_slug = str(ProjectSettings.get_setting(SLUG_SETTING, "")).strip_edges()
	var base := str(ProjectSettings.get_setting(API_BASE_SETTING, "")).strip_edges()
	_api_base = DEFAULT_API_BASE if base.is_empty() else base
	_device_label = str(ProjectSettings.get_setting(DEVICE_LABEL_SETTING, "")).strip_edges()
	if _device_label.is_empty():
		# What a tester approving from their phone needs in order to recognise the request as
		# their own rather than someone else attempting to pair against their account.
		_device_label = OS.get_model_name() + " (" + OS.get_name() + ")"


func _token() -> String:
	if _slug.is_empty() or _tokens == null:
		return ""
	return _tokens.read(_slug)


func _url(suffix: String) -> String:
	return "%s/prototypes/%s/%s" % [_api_base.rstrip("/"), _slug.uri_encode(), suffix]


func _ensure_configured() -> bool:
	if not _slug.is_empty():
		return true
	# Once, not every frame: a game calling event() in _process would otherwise fill the log with
	# the same line and bury everything else.
	if not _configuration_warned:
		_configuration_warned = true
		push_warning("Prototir: no prototype slug is set, so this build cannot pair or report "
			+ "anything. Set it in Project Settings under Prototir, or call Prototir.configure().")
	return false


static func describe_outcome(outcome: int) -> String:
	if outcome == PairingFlow.Outcome.APPROVED:
		return "approved"
	if outcome == PairingFlow.Outcome.EXPIRED:
		return "expired"
	if outcome == PairingFlow.Outcome.CANCELLED:
		return "cancelled"
	return "failed"


func _fail(message: String) -> Dictionary:
	state = State.FAILED
	pairing_failed.emit(message)
	return {"outcome": "failed", "token": "", "message": message}
