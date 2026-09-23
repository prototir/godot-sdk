extends Node

## Godot-shaped adapter for Prototir protocol v1. Enable the addon to install this script as the
## `Prototir` autoload. Web exports talk to the shell over JavaScriptBridge; downloadable builds
## pair with prototir.com and report sessions themselves; the Editor keeps emitting its mocks.

const PROTOCOL_VERSION := 1
const SOURCE := "prototir"
const STORAGE_MAX_BYTES := 64 * 1024
const EVENT_NAME_PATTERN := "^[a-z0-9_.:-]+$"
const NATIVE_RUNTIME_PATH := "res://addons/prototir/native/native_runtime.gd"

signal mock_ready_sent
signal mock_event_sent(name: String, data: Dictionary)
signal mock_score_sent(value: float)
signal shell_initialized(session_id: String)
signal review_visibility_changed(open: bool)

## Re-emitted from the native runtime, so a game connects to Prototir and never has to know that a
## separate node exists. A Web export never emits these: the page already carries the session.
signal pairing_started(request: Dictionary)
signal pairing_succeeded()
signal pairing_failed(message: String)

var mock_ai_handler: Callable
var _mock_storage: Dictionary = {}
var _next_request_id := 1
var _storage_requests: Dictionary = {}
var _ai_requests: Dictionary = {}
var _bridge
var _message_callback
var _review_bridge
var _review_visibility_callback
var _review_capture_callback
var _native


## Opt in to screenshot feedback. The export plugin bundles its local browser UI.
## launcher: "auto" lets Prototir draw the control on its own surfaces, "watermark" always shows
## the Prototir mark, "host" draws nothing so the game can call review_open() itself.
## theme: "auto" follows the player's light/dark preference.
## api_base + slug: set both to let a build hosted outside Prototir post feedback after the tester
## approves it in a browser. Leave empty and the panel saves review files instead.
## Connect review_visibility_changed to pause gameplay/input while writing feedback.
func review_enable(project: String, build: String = "", corner: String = "bottom-left", launcher: String = "auto", theme: String = "auto", api_base: String = "", slug: String = "") -> void:
	if not OS.has_feature("web"):
		push_warning("Screenshot Review Mode currently requires a Web export.")
		return
	_review_bridge = JavaScriptBridge.get_interface("__prototirReviewBridge")
	if _review_bridge == null:
		push_error("Review runtime missing. Re-export with the Prototir addon enabled.")
		return
	_review_visibility_callback = JavaScriptBridge.create_callback(_on_review_visibility)
	_review_capture_callback = JavaScriptBridge.create_callback(_on_review_capture)
	_review_bridge.enable(JSON.stringify({"project": project, "build": build, "corner": corner, "launcher": launcher, "theme": theme, "apiBase": api_base, "slug": slug}), _review_visibility_callback, _review_capture_callback)


func review_disable() -> void:
	if _review_bridge != null:
		_review_bridge.disable()
		_review_bridge = null


func _on_review_visibility(arguments: Array) -> void:
	if not arguments.is_empty():
		review_visibility_changed.emit(bool(arguments[0]))


func _on_review_capture(_arguments: Array) -> void:
	await RenderingServer.frame_post_draw
	if _review_bridge == null:
		return
	var screenshot := get_viewport().get_texture().get_image()
	var bytes := screenshot.save_jpg_to_buffer(0.8)
	_review_bridge.captured("data:image/jpeg;base64," + Marshalls.raw_to_base64(bytes))


func _ready() -> void:
	if OS.has_feature("web"):
		install_web_bridge()
	else:
		_install_native()


## Signal that the prototype is genuinely interactive, not only showing its loader.
func ready() -> void:
	if _is_web_bridge_ready():
		_post({"type": "ready"})
	else:
		mock_ready_sent.emit()
		if _is_reporting_natively():
			_native.ready()


## Record a stable analytics event with a small JSON-compatible Dictionary payload.
func event(name: String, data: Dictionary = {}) -> void:
	var normalized := name.strip_edges().to_lower()
	var regex := RegEx.new()
	regex.compile(EVENT_NAME_PATTERN)
	if normalized.is_empty() or normalized.length() > 64 or regex.search(normalized) == null:
		push_error("Prototir event names must use 1-64 lowercase letters, numbers, _, ., :, or -.")
		return
	if _is_web_bridge_ready():
		var message := {"type": "event", "name": normalized}
		if not data.is_empty():
			message["data"] = data
		_post(message)
	else:
		mock_event_sent.emit(normalized, data)
		if _is_reporting_natively():
			_native.event(normalized)


## Report a finite score.
func score(value: float) -> void:
	if is_nan(value) or is_inf(value):
		push_error("Prototir score must be finite.")
		return
	if _is_web_bridge_ready():
		_post({"type": "score", "value": value})
	else:
		mock_score_sent.emit(value)
		if _is_reporting_natively():
			_native.score(value)


## Return a request whose `completed(value)` signal resolves with String or null.
func storage_get(key: String) -> PrototirRequest:
	return _storage_request("get", key, "")


## Return a request whose `completed(null)` signal means the shell answered.
func storage_set(key: String, value: String) -> PrototirRequest:
	if value.to_utf8_buffer().size() > STORAGE_MAX_BYTES:
		var rejected := PrototirRequest.new(0)
		call_deferred("_reject_request", rejected, "value_too_large", "Storage values cannot exceed 64 KiB of UTF-8 data.")
		return rejected
	return _storage_request("set", key, value)


## Return a request whose `completed(null)` signal means the shell answered.
func storage_remove(key: String) -> PrototirRequest:
	return _storage_request("remove", key, "")


## Return a request that emits completed(text) or failed(code, message).
func ai_generate(prompt: String, max_tokens := 0) -> PrototirRequest:
	var id := _allocate_request_id()
	var request := PrototirRequest.new(id)
	if prompt.strip_edges().is_empty():
		call_deferred("_reject_request", request, "invalid_prompt", "AI prompt is required.")
		return request
	if max_tokens < 0:
		call_deferred("_reject_request", request, "invalid_max_tokens", "max_tokens cannot be negative.")
		return request

	if _is_web_bridge_ready():
		_ai_requests[id] = request
		_timeout_request(_ai_requests, id, 30.0)
		var message := {"type": "ai", "prompt": prompt, "id": id}
		if max_tokens > 0:
			message["maxTokens"] = max_tokens
		_post(message)
	elif mock_ai_handler.is_valid():
		_run_mock_ai(request, prompt, max_tokens)
	else:
		call_deferred("_reject_request", request, "mock_unavailable", "Configure Prototir.mock_ai_handler outside a Web export.")
	return request


## Idempotently connect to the CSP-safe adapter injected by the Prototir sandbox. The addon never
## calls JavaScriptBridge.eval(), because Prototir intentionally does not grant CSP unsafe-eval.
func install_web_bridge() -> bool:
	if not OS.has_feature("web"):
		return false
	if _bridge != null:
		return true

	_bridge = JavaScriptBridge.get_interface("__prototirGodotBridge")
	if _bridge == null:
		return false
	_message_callback = JavaScriptBridge.create_callback(_on_web_message)
	_bridge.install(_message_callback)
	return true


## Point a downloadable build at a prototype from code, instead of Project Settings > Prototir.
func configure(slug: String, api_base := "", device_label := "") -> void:
	if _native != null:
		_native.configure(slug, api_base, device_label)


## Whether this build may act for a person. Always false in a Web export, where the page already
## carries the visitor session and nothing needs pairing.
func is_paired() -> bool:
	return _native != null and _native.is_paired()


## Ask Prototir for a pairing code and wait for a tester to approve it on prototir.com. Connect to
## pairing_started to show the code, the link and the QR: the addon draws nothing, because it
## cannot know your art direction, your input model, or whether you are in VR.
## Returns {"outcome": "approved"|"expired"|"cancelled"|"failed", "token": String, "message": String}.
func begin_pairing() -> Dictionary:
	if _native == null:
		return {
			"outcome": "failed",
			"token": "",
			"message": "A Web export does not pair; the page already has the visitor session.",
		}
	return await _native.begin_pairing()


func cancel_pairing() -> void:
	if _native != null:
		_native.cancel_pairing()


## Show a ready-made pairing screen over the running game, and return it.
##
## The signals above remain the supported way to draw your own, and this changes nothing about
## them. It exists because "draw it yourself" meant every creator had to build a screen before
## collecting a single session, with only an unstyled example to copy. Ignoring it costs nothing.
##
## Returns null on a Web export, which has no pairing to do: the page already knows the visitor.
func show_pairing_screen() -> Node:
	if _native == null:
		return null
	# load(), never preload(): the whole native folder is stripped from a Web export, and a
	# preload would make the addon fail to resolve there instead of simply doing nothing.
	var screen: Node = load("res://addons/prototir/native/ui/pairing_screen.gd").new()
	get_tree().root.add_child(screen)
	return screen


## Forget the stored token, so this build pairs again next time.
func unpair() -> void:
	if _native != null:
		_native.unpair()


## Post feedback as the tester who approved this build. No session is needed first: approving the
## pairing is the stronger signal, so the usual played-it gate is waived for a paired device.
func send_feedback(text: String) -> bool:
	if _native == null:
		return false
	return await _native.send_feedback(text)


## Report the session so far. Called automatically when the window is closed; call it yourself at a
## natural break, such as the end of a run.
func flush_session() -> void:
	if _native != null:
		await _native.flush_session()


func _storage_request(operation: String, key: String, value: String) -> PrototirRequest:
	var id := _allocate_request_id()
	var request := PrototirRequest.new(id)
	var normalized := key.strip_edges()
	if normalized.is_empty() or normalized.length() > 128:
		call_deferred("_reject_request", request, "invalid_key", "Storage keys must contain 1-128 characters.")
		return request

	if _is_web_bridge_ready():
		_storage_requests[id] = request
		_timeout_request(_storage_requests, id, 3.0)
		var message := {"type": "storage", "op": operation, "key": normalized, "id": id}
		if operation == "set":
			message["value"] = value
		_post(message)
	else:
		if operation == "get":
			call_deferred("_resolve_request", request, _mock_storage.get(normalized))
		elif operation == "set":
			_mock_storage[normalized] = value
			call_deferred("_resolve_request", request, null)
		else:
			_mock_storage.erase(normalized)
			call_deferred("_resolve_request", request, null)
	return request


func _post(message: Dictionary) -> void:
	_bridge.post(JSON.stringify(message))


func _on_web_message(arguments: Array) -> void:
	if arguments.is_empty():
		return
	var parsed = JSON.parse_string(str(arguments[0]))
	if not parsed is Dictionary:
		return
	var message: Dictionary = parsed
	match message.get("type", ""):
		"init":
			shell_initialized.emit(str(message.get("sessionId", "")))
		"storage:result":
			var id := int(message.get("id", 0))
			var request: PrototirRequest = _storage_requests.get(id)
			if request != null:
				_storage_requests.erase(id)
				request.resolve(message.get("value"))
		"ai:result":
			var id := int(message.get("id", 0))
			var request: PrototirRequest = _ai_requests.get(id)
			if request != null:
				_ai_requests.erase(id)
				var error = message.get("error")
				if error is Dictionary:
					request.reject(str(error.get("code", "error")), str(error.get("message", "Prototir.ai request failed.")))
				else:
					var text := str(message.get("text", ""))
					if text.is_empty():
						request.reject("empty_response", "Prototir.ai returned an empty response.")
					else:
						request.resolve(text)


func _run_mock_ai(request: PrototirRequest, prompt: String, max_tokens: int) -> void:
	var result = await mock_ai_handler.call(prompt, max_tokens)
	request.resolve(str(result))


func _timeout_request(requests: Dictionary, id: int, seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	var request: PrototirRequest = requests.get(id)
	if request != null:
		requests.erase(id)
		request.reject("timeout", "The Prototir shell did not answer before the request timed out.")


## Loaded rather than preloaded: a Web export strips res://addons/prototir/native entirely, and a
## preload would both defeat that and fail to resolve in the stripped pack.
func _install_native() -> void:
	if _native != null or not ResourceLoader.exists(NATIVE_RUNTIME_PATH):
		return
	_native = load(NATIVE_RUNTIME_PATH).new()
	_native.name = "PrototirNative"
	add_child(_native)
	_native.pairing_started.connect(func(request: Dictionary) -> void: pairing_started.emit(request))
	_native.pairing_succeeded.connect(func() -> void: pairing_succeeded.emit())
	_native.pairing_failed.connect(func(message: String) -> void: pairing_failed.emit(message))


## Pairing is available while running from the Editor, so a creator can build their pairing UI
## without exporting every time. Reporting is not: an F5 run is not a play, and counting it would
## put the creator own testing in their own numbers.
func _is_reporting_natively() -> bool:
	return _native != null and not OS.has_feature("editor")


func _is_web_bridge_ready() -> bool:
	return OS.has_feature("web") and (_bridge != null or install_web_bridge())


func _allocate_request_id() -> int:
	var id := _next_request_id
	_next_request_id += 1
	if _next_request_id >= 2147483647:
		_next_request_id = 1
	return id


func _resolve_request(request: PrototirRequest, value) -> void:
	request.resolve(value)


func _reject_request(request: PrototirRequest, code: String, message: String) -> void:
	request.reject(code, message)
