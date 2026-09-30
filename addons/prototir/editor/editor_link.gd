@tool
extends RefCounted

## This editor, linked to a creator's Prototir account so Publish to Prototir can upload for them.
##
## The same device-code rendezvous as a paired native build: the editor asks for a code, opens the
## approval page in the creator's browser, and polls until they approve. The token it gets back
## can only stage uploads; it cannot publish, comment or change anything, and the creator can
## unlink it from their account page.
##
## Network, delay, clock and storage are passed in, so the tests can drive every branch without a
## server or a real wait. The editor passes the real ones (publish_menu.gd).

## How the link is kept: in the editor's own settings, which belong to this user on this machine
## rather than to a project, so one approval covers every project. Keyed by API address, so a
## local Prototir and the real one never share a token.
const SETTING_PREFIX := "prototir/editor_link/"


## Where the token lives. `settings` is the editor's EditorSettings, or any object with the same
## get/set/has calls (tests pass a small fake).
static func stored(settings: Object, api_base: String) -> Dictionary:
	var key := _key(api_base)
	if not settings.has_setting(key + "/token"):
		return {}
	var token := str(settings.get_setting(key + "/token"))
	if token.is_empty():
		return {}
	return {
		"token": token,
		"display_name": str(settings.get_setting(key + "/name")) if settings.has_setting(key + "/name") else "",
		"app_origin": str(settings.get_setting(key + "/origin")) if settings.has_setting(key + "/origin") else "https://prototir.com",
	}


static func remember(settings: Object, api_base: String, link: Dictionary) -> void:
	var key := _key(api_base)
	settings.set_setting(key + "/token", str(link.get("token", "")))
	settings.set_setting(key + "/name", str(link.get("display_name", "")))
	settings.set_setting(key + "/origin", str(link.get("app_origin", "https://prototir.com")))


## Clears the token. Empty strings rather than erasing: EditorSettings has no erase call, and an
## empty token reads as "not linked" everywhere.
static func forget(settings: Object, api_base: String) -> void:
	var key := _key(api_base)
	for name in ["token", "name", "origin"]:
		if settings.has_setting(key + "/" + name):
			settings.set_setting(key + "/" + name, "")


static func _key(api_base: String) -> String:
	return SETTING_PREFIX + api_base.trim_suffix("/").sha256_text().substr(0, 12)


## Whether a stored token still works: "ok", "unlinked" (a definite 401: forget it), or "error"
## (the network or the server, so keep the token for the next try). Checked before exporting, so
## an editor unlinked from the account page finds out in a second rather than after a long build.
static func verify(http, api_base: String, link: Dictionary) -> String:
	var response: Dictionary = await http.send("GET", api_base + "/editor/me", "", str(link.get("token", "")))
	var status := int(response.get("status", 0))
	if status == 401:
		return "unlinked"
	if status < 200 or status >= 300:
		return "error"
	var me = JSON.parse_string(str(response.get("body", "")))
	if me is Dictionary and not str(me.get("displayName", "")).is_empty():
		link["display_name"] = str(me.get("displayName"))
	return "ok"


## Asks Prototir for a code. Returns {code, verification_url, interval, expires_in} or {error}.
static func start(http, api_base: String, label: String) -> Dictionary:
	var body := JSON.stringify({"engine": "godot", "editorLabel": label})
	var response: Dictionary = await http.send("POST", api_base + "/editor/pair", body, "")
	var reply = JSON.parse_string(str(response.get("body", "")))
	var status := int(response.get("status", 0))
	if status < 200 or status >= 300 or not (reply is Dictionary) or str(reply.get("code", "")).is_empty():
		var reason := str(reply.get("error", "")) if reply is Dictionary else ""
		return {"error": reason if not reason.is_empty()
			else "Prototir could not start linking this editor (%s)." % _describe(status)}
	return {
		"code": str(reply.code),
		"verification_url": str(reply.get("verificationUrl", "")),
		"interval": maxi(2, int(reply.get("intervalSeconds", 5))),
		"expires_in": maxi(60, int(reply.get("expiresInSeconds", 900))),
	}


## Polls until the creator approves in their browser. 202 means not yet; any other refusal means
## the code is dead. A dropped poll (status 0) is not a refusal: the approval may be waiting.
## `cancelled` is a Callable returning true when the creator gave up. Returns {token,
## display_name, app_origin} or {error}.
static func wait_for_approval(http, delay, clock, api_base: String, pending: Dictionary, cancelled: Callable) -> Dictionary:
	var deadline: int = clock.now() + int(pending.get("expires_in", 900)) * 1000
	var body := JSON.stringify({"code": str(pending.get("code", ""))})
	while clock.now() < deadline:
		await delay.wait(float(pending.get("interval", 5)))
		if cancelled.call():
			return {"error": "Cancelled."}
		var response: Dictionary = await http.send("POST", api_base + "/editor/pair/poll", body, "")
		var status := int(response.get("status", 0))
		if status == 0 or status == 202:
			continue
		var reply = JSON.parse_string(str(response.get("body", "")))
		if status < 200 or status >= 300 or not (reply is Dictionary) or str(reply.get("token", "")).is_empty():
			var reason := str(reply.get("error", "")) if reply is Dictionary else ""
			return {"error": reason if not reason.is_empty()
				else "This code is no longer valid. Publish again to get a new one."}
		return {
			"token": str(reply.token),
			"display_name": str(reply.get("displayName", "")),
			"app_origin": origin_of(str(pending.get("verification_url", ""))),
		}
	return {"error": "Nobody approved the link in time. Publish again to get a new code."}


## The website to send the creator to, taken from the approval address the API returned, so a
## local or staging Prototir sends them to its own site.
static func origin_of(url: String) -> String:
	var scheme_end := url.find("://")
	if scheme_end < 0:
		return "https://prototir.com"
	var path_start := url.find("/", scheme_end + 3)
	return url if path_start < 0 else url.substr(0, path_start)


static func _describe(status: int) -> String:
	return "no answer" if status == 0 else "HTTP %d" % status
