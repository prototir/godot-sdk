extends RefCounted

## The device code flow, with no engine in it beyond what the injected http and delay provide.
##
## A downloaded build has no browser session: it shows a code, the tester approves it on
## prototir.com, and the build polls until a token comes back. Loopback redirects and custom URI
## schemes were both rejected for this, because a downloaded build is unsigned and opening a socket
## trips a firewall prompt at the worst moment, while nothing registers a URI scheme for a zip.

enum Outcome {
	APPROVED,
	## The code will never become valid: expired, unknown, already used, or revoked. The server
	## answers 410 for all of them on purpose, so a caller cannot probe which codes exist, and the
	## client must not distinguish them either.
	EXPIRED,
	CANCELLED,
	FAILED,
}

## Fallback cadence when the server does not say. Never poll faster than this.
const DEFAULT_POLL_INTERVAL := 5.0
const QR_DATA_URL_PREFIX := "data:image/svg+xml;base64,"

var _http
var _delay
var _now_ms: Callable
var _api_base: String
var _slug: String
var _cancelled := false


## http.post_json(url, body, token) -> {"status": int, "body": String}, where status 0 is a
## transport failure. delay.wait(seconds) simply returns when the time has passed.
func _init(http, delay, now_ms: Callable, api_base: String, slug: String) -> void:
	_http = http
	_delay = delay
	_now_ms = now_ms
	_api_base = api_base.rstrip("/")
	_slug = slug


## Returns the request a game shows a tester, or {} when Prototir would not start one.
func start(device_label: String, build_id: String) -> Dictionary:
	var body := JSON.stringify({"deviceLabel": device_label, "buildId": build_id})
	var response: Dictionary = await _http.post_json(_url("pair"), body, "")
	if int(response.get("status", 0)) != 200:
		return {}

	var payload := parse_object(str(response.get("body", "")))
	if str(payload.get("code", "")).is_empty():
		return {}

	return {
		"code": str(payload.get("code", "")),
		"verification_url": str(payload.get("verificationUrl", "")),
		# The QR the server rendered, decoded from its data URL. Rendered server-side
		# deliberately: a client-side encoder is dense, easy to get subtly wrong, would be written
		# three times, and the place it matters most is where it is most awkward.
		"qr_svg": decode_qr(str(payload.get("qrSvgDataUrl", ""))),
		"prototype_title": str(payload.get("prototypeTitle", "")),
		"expires_in": maxf(1.0, float(payload.get("expiresInSeconds", 0))),
		"poll_interval": interval(float(payload.get("intervalSeconds", 0))),
	}


## Polls until approved, refused, or the deadline passes.
func await_approval(code: String, timeout: float, poll_interval: float) -> Dictionary:
	var deadline := int(_now_ms.call()) + int(timeout * 1000.0)
	var wait := DEFAULT_POLL_INTERVAL if poll_interval <= 0.0 else poll_interval
	var body := JSON.stringify({"code": code})

	while true:
		if _cancelled:
			return {"outcome": Outcome.CANCELLED, "token": "", "message": ""}

		var response: Dictionary = await _http.post_json(_url("pair/poll"), body, "")
		var status := int(response.get("status", 0))
		var payload := parse_object(str(response.get("body", "")))

		match status:
			200:
				if not str(payload.get("token", "")).is_empty():
					return {
						"outcome": Outcome.APPROVED,
						"token": str(payload.get("token", "")),
						"message": "",
					}
				return _fail("The server approved the pairing but returned no token.")
			410:
				return {
					"outcome": Outcome.EXPIRED,
					"token": "",
					"message": "This code is no longer valid. Start again.",
				}
			400:
				return _fail("That pairing code was not accepted.")
			202:
				# The server owns the cadence; honour it rather than hammering.
				if float(payload.get("intervalSeconds", 0)) > 0.0:
					wait = interval(float(payload.get("intervalSeconds", 0)))
			_:
				# Anything else, including a transport failure, is treated as temporary: pairing is
				# a person walking to their phone, and one dropped request should not make them
				# start over.
				pass

		if int(_now_ms.call()) >= deadline:
			return {
				"outcome": Outcome.EXPIRED,
				"token": "",
				"message": "Nobody approved this code in time. Start again.",
			}

		await _delay.wait(wait)

	# Unreachable, and GDScript wants every path to return.
	return _fail("Pairing ended unexpectedly.")


func cancel() -> void:
	_cancelled = true


## Whether a response to an authenticated call means this token is finished. Revoked and
## wrong-prototype both answer 403, and neither is worth retrying: the caller must drop the token
## and pair again rather than looping on a refusal.
static func is_token_terminal(status: int) -> bool:
	return status == 401 or status == 403


static func interval(seconds: float) -> float:
	return seconds if seconds > 0.0 else DEFAULT_POLL_INTERVAL


## A malformed QR is not worth failing a pairing over, and not worth a red line in the log either:
## the code and the URL are both still shown, and those are what a tester actually needs.
static func decode_qr(data_url: String) -> String:
	if not data_url.begins_with(QR_DATA_URL_PREFIX):
		return ""
	var encoded := data_url.substr(QR_DATA_URL_PREFIX.length())
	if not _is_base64(encoded):
		return ""
	return Marshalls.base64_to_raw(encoded).get_string_from_utf8()


## Marshalls prints an engine error on malformed input, so the shape is checked before decoding.
static func _is_base64(text: String) -> bool:
	if text.is_empty() or text.length() % 4 != 0:
		return false
	for index in text.length():
		var c := text.unicode_at(index)
		var ok := (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57)
		ok = ok or c == 43 or c == 47 or c == 61
		if not ok:
			return false
	return true


## JSON.parse_string prints a parse failure straight to the log. A server that answers with an
## empty body, or with HTML from a proxy, is an ordinary thing on someone network, so it is handled
## rather than announced. Returns {} for anything that is not a JSON object.
static func parse_object(text: String) -> Dictionary:
	if text.strip_edges().is_empty():
		return {}
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	var data = json.data
	return data if data is Dictionary else {}


func _url(suffix: String) -> String:
	return "%s/prototypes/%s/%s" % [_api_base, _slug.uri_encode(), suffix]


func _fail(message: String) -> Dictionary:
	return {"outcome": Outcome.FAILED, "token": "", "message": message}
