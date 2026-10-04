@tool
extends Node

## Tells the creator when a newer addon is out, and installs it with one click.
##
## The addon is a copied folder, so without this a project stays on the version it was set up with
## and its testers never get new tools. Checked once a day against the latest GitHub release.
## Nothing in the project changes until the creator presses Update: an update is code changing in
## their project, possibly the night before a deadline.

const RELEASES_URL := "https://api.github.com/repos/prototir/godot-sdk/releases/latest"
const REPOSITORY := "https://github.com/prototir/godot-sdk"
const ADDON_PREFIX := "addons/prototir/"
const INTERVAL_SECONDS := 86400
const METADATA_SECTION := "prototir"

## Emitted when a check or an update finishes, so the setup dock can redraw.
signal changed()

## The newer release's version ("0.5.0"), or empty when this project is current.
var available := ""
var busy := false
var _asset_url := ""


static func parse_version(text: String) -> PackedInt32Array:
	var trimmed := text.strip_edges().trim_prefix("v")
	var parts := trimmed.split(".")
	if parts.size() != 3:
		return PackedInt32Array()
	var numbers := PackedInt32Array()
	for part in parts:
		# Digits only: "1-rc", "+1" and "-1" are not release numbers.
		if part.is_empty() or not part.is_valid_int() or part.begins_with("+") or part.begins_with("-"):
			return PackedInt32Array()
		numbers.append(int(part))
	return numbers


## True when `candidate` is a newer release than `current`; false when either cannot be read, so a
## check never nags about a version it does not understand.
static func is_newer(candidate: String, current: String) -> bool:
	var a := parse_version(candidate)
	var b := parse_version(current)
	if a.is_empty() or b.is_empty():
		return false
	for i in 3:
		if a[i] != b[i]:
			return a[i] > b[i]
	return false


static func installed_version() -> String:
	var config := ConfigFile.new()
	if config.load("res://addons/prototir/plugin.cfg") != OK:
		return ""
	return str(config.get_value("plugin", "version", ""))


## The release ZIP's files that belong to the addon. Anything outside addons/prototir is ignored,
## so a release can never write over the creator's own files.
static func addon_entries(names: PackedStringArray) -> PackedStringArray:
	var entries := PackedStringArray()
	for name in names:
		if name.begins_with(ADDON_PREFIX) and not name.ends_with("/") and not name.contains(".."):
			entries.append(name)
	return entries


func changelog_url() -> String:
	return "%s/blob/v%s/CHANGELOG.md" % [REPOSITORY, available]


func check(force := false) -> void:
	if busy:
		return
	var settings := EditorInterface.get_editor_settings()
	var last := int(settings.get_project_metadata(METADATA_SECTION, "update_checked", 0))
	var now := int(Time.get_unix_time_from_system())
	if not force and now - last < INTERVAL_SECONDS:
		_restore(settings)
		return
	busy = true
	var response := await _download(RELEASES_URL)
	busy = false
	# A failed check stays quiet and is tried again tomorrow: being offline is not something to
	# report every time the editor opens.
	if int(response.status) != 200:
		changed.emit()
		return
	settings.set_project_metadata(METADATA_SECTION, "update_checked", now)
	var release = JSON.parse_string(response.body.get_string_from_utf8())
	if not release is Dictionary:
		changed.emit()
		return
	var version := str(release.get("tag_name", "")).trim_prefix("v")
	var asset := ""
	for item in release.get("assets", []):
		var name := str(item.get("name", ""))
		if name.begins_with("prototir-godot-sdk") and name.ends_with(".zip"):
			asset = str(item.get("browser_download_url", ""))
	settings.set_project_metadata(METADATA_SECTION, "update_version", version)
	settings.set_project_metadata(METADATA_SECTION, "update_asset", asset)
	_restore(settings)
	# Once per version, in the Output panel where the creator already looks.
	if not available.is_empty() and (force or str(settings.get_project_metadata(METADATA_SECTION, "update_announced", "")) != available):
		settings.set_project_metadata(METADATA_SECTION, "update_announced", available)
		print("Prototir addon %s is available (this project has %s). See the Prototir dock to update." % [available, installed_version()])
	changed.emit()


## Downloads the release, checks it is the addon at the version it claims, and writes its files
## over addons/prototir. Returns an error message, or an empty string once installed.
func update() -> String:
	if busy or available.is_empty() or _asset_url.is_empty():
		return "No update is ready to install."
	busy = true
	changed.emit()
	var response := await _download(_asset_url)
	busy = false
	if int(response.status) != 200:
		changed.emit()
		return "The download did not finish. Check your connection and try again."
	var path := "user://prototir-update.zip"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(response.body)
	file.close()
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		changed.emit()
		return "The download is not a ZIP file."
	var entries := addon_entries(zip.get_files())
	var config := ConfigFile.new()
	# Nothing is written unless the archive is the addon, at the version the release named.
	if not entries.has(ADDON_PREFIX + "plugin.cfg") or config.parse(zip.read_file(ADDON_PREFIX + "plugin.cfg").get_string_from_utf8()) != OK \
			or str(config.get_value("plugin", "version", "")) != available:
		zip.close()
		changed.emit()
		return "The download is not the Prototir addon %s." % available
	for entry in entries:
		var target := "res://" + entry
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var out := FileAccess.open(target, FileAccess.WRITE)
		if out == null:
			zip.close()
			changed.emit()
			return "Could not write %s. Is the folder read-only?" % target
		out.store_buffer(zip.read_file(entry))
		out.close()
	zip.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# The folder is replaced, not merged: a script the new release dropped would otherwise stay
	# behind and still be loaded.
	for stale in _files_below("res://" + ADDON_PREFIX):
		if not entries.has(stale.trim_prefix("res://")):
			DirAccess.remove_absolute(stale)
	available = ""
	changed.emit()
	return ""


static func _files_below(dir: String) -> PackedStringArray:
	var files := PackedStringArray()
	for name in DirAccess.get_files_at(dir):
		files.append(dir.path_join(name))
	for name in DirAccess.get_directories_at(dir):
		files.append_array(_files_below(dir.path_join(name)))
	return files


func _restore(settings: EditorSettings) -> void:
	var version := str(settings.get_project_metadata(METADATA_SECTION, "update_version", ""))
	available = version if is_newer(version, installed_version()) else ""
	_asset_url = str(settings.get_project_metadata(METADATA_SECTION, "update_asset", ""))


func _download(url: String) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = 120.0
	add_child(request)
	var headers := PackedStringArray(["User-Agent: prototir-godot-sdk", "Accept: application/vnd.github+json"])
	if request.request(url, headers) != OK:
		request.queue_free()
		return {"status": 0, "body": PackedByteArray()}
	var outcome: Array = await request.request_completed
	request.queue_free()
	if int(outcome[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"status": 0, "body": PackedByteArray()}
	return {"status": int(outcome[1]), "body": outcome[3]}
