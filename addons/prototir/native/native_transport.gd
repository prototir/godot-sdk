extends RefCounted

## The engine half of the native path: one HTTP call, one timer, one token on disk. Kept apart from
## pairing_flow.gd and session_recorder.gd so those stay testable without a network or a clock.

const TOKEN_DIRECTORY := "user://prototir"


class Http:
	extends RefCounted

	var _host: Node

	## Godot drives HTTPRequest from the scene tree, so it needs a node to live under. The runtime
	## node passes itself.
	func _init(host: Node) -> void:
		_host = host

	## Status 0 means the request never reached the server, which callers treat as temporary.
	func post_json(url: String, body: String, token: String) -> Dictionary:
		var request := HTTPRequest.new()
		_host.add_child(request)
		var headers := PackedStringArray([
			"Content-Type: application/json",
			"Accept: application/json",
		])
		if not token.is_empty():
			headers.append("Authorization: Bearer " + token)

		if request.request(url, headers, HTTPClient.METHOD_POST, body) != OK:
			request.queue_free()
			return {"status": 0, "body": ""}

		var outcome: Array = await request.request_completed
		request.queue_free()
		if int(outcome[0]) != HTTPRequest.RESULT_SUCCESS:
			return {"status": 0, "body": ""}
		var payload: PackedByteArray = outcome[3]
		return {"status": int(outcome[1]), "body": payload.get_string_from_utf8()}


class Delay:
	extends RefCounted

	var _host: Node

	func _init(host: Node) -> void:
		_host = host

	func wait(seconds: float) -> void:
		await _host.get_tree().create_timer(seconds).timeout


class TokenStore:
	extends RefCounted

	## Per slug, so a machine that tests two prototypes does not lose one pairing by starting the
	## other. user:// is the only writable place a downloaded build can count on.
	func read(slug: String) -> String:
		var path := _path(slug)
		if not FileAccess.file_exists(path):
			return ""
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			return ""
		return file.get_as_text().strip_edges()

	func write(slug: String, token: String) -> void:
		DirAccess.make_dir_recursive_absolute(TOKEN_DIRECTORY)
		var file := FileAccess.open(_path(slug), FileAccess.WRITE)
		if file == null:
			# Losing the token only means pairing again next launch, so this is a note.
			push_warning("Prototir could not store this pairing. The build will ask again next time.")
			return
		file.store_string(token)
		file.close()

	func clear(slug: String) -> void:
		var path := _path(slug)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)

	func _path(slug: String) -> String:
		return TOKEN_DIRECTORY.path_join(slug.uri_encode() + ".token")
