@tool
extends EditorExportPlugin

const Setup := preload("res://addons/prototir/setup.gd")
var _export_path := ""


func _get_name() -> String:
	return "Prototir Web preflight"


func _export_begin(features: PackedStringArray, is_debug: bool, path: String, _flags: int) -> void:
	_export_path = ""
	if not features.has("web"):
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
