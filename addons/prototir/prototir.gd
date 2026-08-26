extends Node

## Godot-shaped adapter for Prototir protocol v1. Enable the addon to install this script as the
## `Prototir` autoload. Web exports use JavaScriptBridge; Editor/native runs use local mocks.

const PROTOCOL_VERSION := 1
const SOURCE := "prototir"
const STORAGE_MAX_BYTES := 64 * 1024
const EVENT_NAME_PATTERN := "^[a-z0-9_.:-]+$"

signal mock_ready_sent
signal mock_event_sent(name: String, data: Dictionary)
signal mock_score_sent(value: float)
signal shell_initialized(session_id: String)

var mock_ai_handler: Callable
var _mock_storage: Dictionary = {}
var _next_request_id := 1
var _storage_requests: Dictionary = {}
var _ai_requests: Dictionary = {}
var _bridge
var _message_callback


func _ready() -> void:
	if OS.has_feature("web"):
		install_web_bridge()


## Signal that the prototype is genuinely interactive, not only showing its loader.
func ready() -> void:
	if _is_web_bridge_ready():
		_post({"type": "ready"})
	else:
		mock_ready_sent.emit()


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


## Report a finite score.
func score(value: float) -> void:
	if is_nan(value) or is_inf(value):
		push_error("Prototir score must be finite.")
		return
	if _is_web_bridge_ready():
		_post({"type": "score", "value": value})
	else:
		mock_score_sent.emit(value)


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
