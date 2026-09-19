@tool
extends EditorExportPlugin

const Setup := preload("res://addons/prototir/setup.gd")
var _export_path := ""
var _any_export_path := ""


## Prototir records this id from the uploaded archive, and a running build reports the same id
## when it pairs. A match shows the build running is the build that was uploaded, and nothing
## more: both sides come from a file the creator controls, so it is not verification, security,
## or anti-cheat. It catches an old build being run against a new upload.
func _write_build_id() -> void:
	if _any_export_path.is_empty():
		return
	var destination := _any_export_path.get_base_dir().path_join("prototir-build.json")
	# A fresh id per export, deliberately: reusing one would mean an older artifact still
	# matched, which is exactly what this is meant to notice.
	var sidecar := {
		"buildId": _new_build_id(),
		"sdk": "godot",
		"sdkVersion": _plugin_version(),
		"createdAt": Time.get_datetime_string_from_system(true, true) + "Z",
	}
	var file := FileAccess.open(destination, FileAccess.WRITE)
	if file == null:
		# A build that cannot carry an id is still a good build; it simply pairs without one.
		push_warning("Prototir could not write %s. The build will pair without a build id." % destination)
		return
	file.store_string(JSON.stringify(sidecar, "  ") + "
")
	file.close()


func _new_build_id() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	var id := ""
	for byte in bytes:
		id += "%02x" % byte
	return id


func _plugin_version() -> String:
	var config := ConfigFile.new()
	if config.load("res://addons/prototir/plugin.cfg") != OK:
		return "unknown"
	return str(config.get_value("plugin", "version", "unknown"))


func _get_name() -> String:
	return "Prototir Web preflight"


func _export_begin(features: PackedStringArray, is_debug: bool, path: String, _flags: int) -> void:
	_export_path = ""
	_any_export_path = path
	if not features.has("web"):
		# A desktop export gets no Web preflight, but it does get a build id: a download is the
		# case that id exists for (D43).
		return
	_export_path = path
	if is_debug:
		push_error("Prototir: debug Web exports are not release-ready. Export a release build.")
	for issue in Setup.get_issues():
		var message := "Prototir: %s - %s" % [issue.get("title", "setup issue"), issue.get("message", "")]
		if issue.get("severity") == "error":
			push_error(message)
		else:
			push_warning(message)


func _export_end() -> void:
	_write_build_id()
	if _export_path.is_empty():
		return
	var destination := _export_path.get_base_dir().path_join("prototir.json")
	var bytes: PackedByteArray
	if FileAccess.file_exists("res://prototir.json"):
		bytes = FileAccess.get_file_as_bytes("res://prototir.json")
	else:
		var version := Engine.get_version_info()
		var manifest := {
			"name": str(ProjectSettings.get_setting("application/config/name", "Godot Web prototype")),
			"type": "game",
			"entry": "index.html",
			"devices": ["desktop", "mobile"],
			"orientation": "any",
			"runtime": {
				"engine": "godot",
				"engineVersion": str(version.get("string", "unknown")),
				"profile": "standard"
			}
		}
		bytes = (JSON.stringify(manifest, "  ") + "\n").to_utf8_buffer()
	var file := FileAccess.open(destination, FileAccess.WRITE)
	if file == null:
		push_error("Prototir could not write %s after export." % destination)
		return
	file.store_buffer(bytes)
	file.close()
	print("Prototir wrote %s" % destination)
	# Local scripts work on Prototir and any static host, without a CDN or unsafe-eval.
	for asset in ["prototir.js", "review-bridge.js"]:
		var target := _export_path.get_base_dir().path_join("prototir-" + asset)
		var output := FileAccess.open(target, FileAccess.WRITE)
		if output == null:
			push_error("Prototir could not bundle review runtime: " + target)
			return
		output.store_buffer(FileAccess.get_file_as_bytes("res://addons/prototir/web/" + asset))
		output.close()
	var html := FileAccess.get_file_as_string(_export_path)
	if not html.contains('src="prototir-prototir.js"'):
		var tags := '<script src="prototir-prototir.js"></script><script src="prototir-review-bridge.js"></script>'
		html = html.replace("</head>", tags + "</head>") if html.contains("</head>") else tags + html
		var entry := FileAccess.open(_export_path, FileAccess.WRITE)
		if entry == null:
			push_error("Prototir could not add review scripts to the Web entry.")
			return
		entry.store_string(html)
		entry.close()
