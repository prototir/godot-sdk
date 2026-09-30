@tool
extends RefCounted

## Uploads a ZIP straight to Prototir's storage and registers it as waiting for the creator on the
## website. The same handshake the website uses for large bundles: the API mints presigned part
## URLs after checking plan limits and slots, the parts go directly to storage, and completion
## re-checks the real size before a claim is issued.
##
## Network, delay and file access are plain arguments, so the tests can run every branch.

const ATTEMPTS := 3


## Uploads `path` and returns {"claim": ...} or {"error": text, "unlinked": bool}. `progress` is
## called with the bytes whose part has landed, so it never reports bytes a retry may undo.
## `cancelled` returns true when the creator gave up.
static func upload(http, delay, api_base: String, token: String, path: String, progress: Callable, cancelled: Callable) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "The build could not be read: " + path}
	var size := file.get_length()

	var start := await _control(http, api_base, token, "me/uploads/direct", {"sizeBytes": size})
	if start.has("error"):
		return start
	var reply: Dictionary = start.reply
	var parts: Array = reply.get("parts", [])
	var part_size := int(reply.get("partSizeBytes", 0))
	if parts.is_empty() or part_size <= 0:
		return {"error": "Prototir sent an unreadable answer when starting the upload."}

	var done := []
	var failure := {}
	for part in parts:
		if cancelled.call():
			failure = {"error": "Cancelled."}
			break
		var number := int(part.get("partNumber", 0))
		var offset := (number - 1) * part_size
		file.seek(offset)
		# One part in memory at a time: an editor uploading a build is not worth holding the whole
		# ZIP in RAM for.
		var bytes := file.get_buffer(mini(part_size, size - offset))
		var etag := await _put_part(http, delay, str(part.get("url", "")), bytes)
		if etag.is_empty():
			failure = {"error": "Storage did not accept a part of the upload. Check the connection and publish again."}
			break
		done.append({"partNumber": number, "etag": etag})
		progress.call(bytes.size())
	file.close()

	if failure.is_empty():
		var complete := await _control(http, api_base, token, "me/uploads/direct/complete",
			{"uploadRef": reply.get("uploadRef", ""), "uploadId": reply.get("uploadId", ""), "parts": done})
		if not complete.has("error"):
			var claim := str(complete.reply.get("claim", ""))
			if not claim.is_empty():
				return {"claim": claim}
			failure = {"error": "Prototir finished the upload but returned no claim."}
		else:
			failure = complete

	# Abandoned parts are billed until aborted, so every failure clears them. Best effort: a failed
	# cleanup must not hide the error the creator needs to see.
	await http.send("DELETE", "%s/me/uploads/direct/%s?uploadId=%s" % [
		api_base, str(reply.get("uploadRef", "")), str(reply.get("uploadId", "")).uri_encode()], "", token)
	return failure


## Tells Prototir the upload is waiting, so Studio or the upload page lists it until it is used
## and a reload cannot lose it. A newer upload for the same prototype and platform replaces the
## older one. Returns {} or {"error": ..., "unlinked": bool}.
static func register(http, api_base: String, token: String, fields: Dictionary) -> Dictionary:
	var body := fields.duplicate()
	body["engine"] = "godot"
	var result := await _control(http, api_base, token, "editor/uploads", body)
	return result if result.has("error") else {}


static func _control(http, api_base: String, token: String, route: String, body: Dictionary) -> Dictionary:
	var response: Dictionary = await http.send("POST", api_base + "/" + route, JSON.stringify(body), token)
	var status := int(response.get("status", 0))
	if status == 401:
		return {"error": "This editor is no longer linked to your Prototir account. Publish again to link it.", "unlinked": true}
	var reply = JSON.parse_string(str(response.get("body", "")))
	if status < 200 or status >= 300:
		var reason := str(reply.get("error", "")) if reply is Dictionary else ""
		return {"error": reason if not reason.is_empty()
			else ("Prototir could not be reached." if status == 0 else "Prototir refused the upload (HTTP %d)." % status)}
	if not (reply is Dictionary):
		return {"error": "Prototir sent an unreadable answer."}
	return {"reply": reply}


## Uploads one part and returns its ETag, retrying network failures a few times.
static func _put_part(http, delay, url: String, bytes: PackedByteArray) -> String:
	for attempt in range(1, ATTEMPTS + 1):
		var response: Dictionary = await http.put_bytes(url, bytes)
		var status := int(response.get("status", 0))
		if status >= 200 and status < 300:
			var headers: Dictionary = response.get("headers", {})
			return str(headers.get("etag", ""))
		# A storage refusal (4xx) will not change on retry; a dropped connection or 5xx might.
		if status >= 400 and status < 500:
			return ""
		if attempt < ATTEMPTS:
			await delay.wait(0.5 * pow(2, attempt))
	return ""
