@tool
extends RefCounted

## The editor's side of the network, for Publish to Prototir: JSON calls to the API and raw part
## uploads to storage. Each call is its own HTTPRequest, so a connection the server closed during a
## long export is never reused (the failure Unity's editor hit on its first real publish).

var _host: Node


## HTTPRequest runs from the scene tree, so it needs a node to live under: the editor plugin.
func _init(host: Node) -> void:
	_host = host


## Status 0 means the request never reached the server.
func send(method: String, url: String, body: String, token: String) -> Dictionary:
	var headers := PackedStringArray(["Accept: application/json"])
	if not body.is_empty():
		headers.append("Content-Type: application/json")
	if not token.is_empty():
		headers.append("Authorization: Bearer " + token)
	var methods := {
		"GET": HTTPClient.METHOD_GET,
		"POST": HTTPClient.METHOD_POST,
		"DELETE": HTTPClient.METHOD_DELETE,
	}
	return await _request(url, headers, methods.get(method, HTTPClient.METHOD_GET), body.to_utf8_buffer())


## Uploads one part to a presigned storage address. No token: the address carries its own
## signature, and storage would refuse an Authorization header it did not sign.
func put_bytes(url: String, bytes: PackedByteArray) -> Dictionary:
	return await _request(url, PackedStringArray(), HTTPClient.METHOD_PUT, bytes)


func wait(seconds: float) -> void:
	await _host.get_tree().create_timer(seconds).timeout


func now() -> int:
	return Time.get_ticks_msec()


func _request(url: String, headers: PackedStringArray, method: int, body: PackedByteArray) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = 600.0
	_host.add_child(request)
	if request.request_raw(url, headers, method, body) != OK:
		request.queue_free()
		return {"status": 0, "body": "", "headers": {}}
	var outcome: Array = await request.request_completed
	request.queue_free()
	if int(outcome[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"status": 0, "body": "", "headers": {}}
	var names := {}
	for line in outcome[2]:
		var colon := str(line).find(":")
		if colon > 0:
			names[str(line).substr(0, colon).strip_edges().to_lower()] = str(line).substr(colon + 1).strip_edges()
	var payload: PackedByteArray = outcome[3]
	return {"status": int(outcome[1]), "body": payload.get_string_from_utf8(), "headers": names}
