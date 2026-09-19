@tool
extends RefCounted

## One button per delivery mode (D43), so a creator does not have to know which export settings
## Prototir expects.
##
## Both produce a ZIP ready to drop on the upload page: web bundles are uploaded as one archive,
## and a desktop build has to be an archive because an executable alone leaves its data folder
## behind, which is the most common way a download arrives broken.
##
## The export itself runs as a second, headless copy of this editor, because the in-editor export
## API is not reachable from a plugin: EditorExportPlatform.get_current_presets() only answers for
## the platform instances the editor registered, and a plugin cannot get at those. The command line
## is the documented path, and the export plugin in this addon still runs inside it, so the Web
## preflight and prototir-build.json happen exactly as they do from the Export dialog.

const PRESETS_PATH := "res://export_presets.cfg"
const WEB_PLATFORMS := ["Web"]
const DESKTOP_PLATFORMS := {
	"Windows": ["Windows Desktop"],
	"macOS": ["macOS"],
	"Linux": ["Linux", "Linux/X11"],
}

## The other transport, kept out of the pack. A Web bundle has no use for a pairing client and a
## download has no use for a JavaScript bridge.
const WEB_EXCLUDES := "addons/prototir/native/*"
const DOWNLOAD_EXCLUDES := "addons/prototir/web/*"

var _plugin: EditorPlugin
var _dialog: AcceptDialog
var _picker: EditorFileDialog
var _pending_web := false


func _init(plugin: EditorPlugin) -> void:
	_plugin = plugin


func export_web() -> void:
	_start(true)


func export_download() -> void:
	_start(false)


func dispose() -> void:
	if _dialog != null:
		_dialog.queue_free()
		_dialog = null
	if _picker != null:
		_picker.queue_free()
		_picker = null


func _start(web: bool) -> void:
	var preset := _find_preset(WEB_PLATFORMS if web else _host_platforms())
	if preset.is_empty():
		if web:
			_say("Add a Web export preset first, in Project > Export > Add > Web.\n\n"
				+ "Install the Web export templates from Editor > Manage Export Templates if the "
				+ "preset reports them missing.")
		else:
			_say("Add an export preset for this machine first, in Project > Export > Add > %s.\n\n"
				% OS.get_name()
				+ "This button does not export for the other desktop platforms: cross-exporting "
				+ "macOS and Linux from here needs their own templates, and a build nobody can run "
				+ "is worse than no build at all.")
		return

	_pending_web = web
	if _picker == null:
		_picker = EditorFileDialog.new()
		_picker.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
		_picker.access = EditorFileDialog.ACCESS_FILESYSTEM
		_picker.dir_selected.connect(_on_directory_chosen)
		_plugin.get_editor_interface().get_base_control().add_child(_picker)
	_picker.title = "Export for Prototir (Web)" if web else "Export for Prototir (Download)"
	_picker.popup_centered_ratio(0.6)


func _on_directory_chosen(directory: String) -> void:
	var preset := _find_preset(WEB_PLATFORMS if _pending_web else _host_platforms())
	if preset.is_empty():
		return

	_exclude_other_transport(preset, WEB_EXCLUDES if _pending_web else DOWNLOAD_EXCLUDES)

	var name := "prototir-web" if _pending_web else "prototir-" + OS.get_name().to_lower()
	# A clean folder per export: leftovers from a previous build ship inside the archive and are
	# impossible to spot once it is uploaded.
	var output := directory.path_join(name)
	if DirAccess.dir_exists_absolute(output):
		_remove_tree(output)
	DirAccess.make_dir_recursive_absolute(output)

	var entry := output.path_join("index.html" if _pending_web else _executable_name(preset))
	var arguments := PackedStringArray([
		"--headless",
		"--path", ProjectSettings.globalize_path("res://"),
		"--export-release", str(preset.get("name", "")),
		entry,
	])
	print("Prototir: exporting %s ..." % name)
	var lines := []
	var code := OS.execute(OS.get_executable_path(), arguments, lines, true)
	for line in lines:
		print(line)

	if code != 0 or not FileAccess.file_exists(entry):
		_say("The export did not finish. The Output panel has the log.\n\n"
			+ "The usual cause is a missing export template: install it from Editor > Manage "
			+ "Export Templates, then try again.")
		return

	var archive := output + ".zip"
	if not _zip(output, archive):
		# The build itself is fine and can be zipped by hand, so this is a note, not a failure that
		# should make a creator think the export was wasted.
		_say("The build succeeded but could not be zipped. Zip this folder yourself before "
			+ "uploading:\n\n" + output)
		return

	var megabytes := FileAccess.open(archive, FileAccess.READ).get_length() / 1024.0 / 1024.0
	print("Prototir: exported %s (%.1f MB). Upload it at prototir.com." % [archive, megabytes])
	_say("%s\n%.1f MB\n\n%s" % [
		archive.get_file(),
		megabytes,
		"Add it under \"Play in the browser\" on the upload page." if _pending_web
			else "Add it under \"Download and run\" on the upload page, and remember a cover image "
				+ "is required when there is no web build.",
	])
	OS.shell_show_in_file_manager(ProjectSettings.globalize_path(archive), true)


## Adds the unused transport to this preset exclude filter, once, and leaves it there.
##
## This is the only mechanism that works. Godot exports GDScript through a path that never reaches
## an export plugin, so the addon cannot skip those files itself; the preset filter can, and it was
## measured doing so. The change is left in place rather than reverted afterwards, so it stays
## visible in Project > Export > Resources instead of being a thing that silently happens at
## export time, and so a creator exporting from the Export dialog gets it too.
func _exclude_other_transport(preset: Dictionary, pattern: String, presets_path := PRESETS_PATH) -> void:
	var config := ConfigFile.new()
	if config.load(presets_path) != OK:
		return
	var section := str(preset.get("section", ""))
	var existing := str(config.get_value(section, "exclude_filter", ""))
	var parts := [] if existing.strip_edges().is_empty() else Array(existing.split(","))
	for part in parts:
		if str(part).strip_edges() == pattern:
			return
	parts.append(pattern)
	config.set_value(section, "exclude_filter", ",".join(PackedStringArray(parts)))
	if config.save(presets_path) != OK:
		push_warning("Prototir could not update the export preset, so this build will carry the "
			+ "transport it does not use. Add %s to its Exclude Filter by hand." % pattern)
		return
	print("Prototir: added %s to the exclude filter of the %s preset."
		% [pattern, str(preset.get("name", ""))])


## Reads export_presets.cfg rather than asking the editor, for the reason at the top of this file.
func _find_preset(platforms: Array, presets_path := PRESETS_PATH) -> Dictionary:
	var config := ConfigFile.new()
	if config.load(presets_path) != OK:
		return {}
	for section in config.get_sections():
		# [preset.0] is a preset; [preset.0.options] is its settings. One dot, not merely any dot:
		# testing for "contains a dot" skipped every preset there has ever been.
		if section.count(".") != 1:
			continue
		var platform := str(config.get_value(section, "platform", ""))
		if platforms.has(platform):
			return {
				"section": section,
				"name": str(config.get_value(section, "name", "")),
				"platform": platform,
				"export_path": str(config.get_value(section, "export_path", "")),
			}
	return {}


func _host_platforms() -> Array:
	return DESKTOP_PLATFORMS.get(OS.get_name(), [])


func _executable_name(preset: Dictionary) -> String:
	# The preset knows the extension the platform needs, and getting it wrong is how an export
	# silently produces something the operating system will not open.
	var configured := str(preset.get("export_path", "")).get_file()
	if not configured.is_empty():
		return configured
	var project := str(ProjectSettings.get_setting("application/config/name", "game"))
	var safe := project.validate_filename()
	return safe + (".exe" if OS.get_name() == "Windows" else "")


func _zip(folder: String, archive: String) -> bool:
	if FileAccess.file_exists(archive):
		DirAccess.remove_absolute(archive)
	var packer := ZIPPacker.new()
	if packer.open(archive) != OK:
		return false
	var ok := _zip_folder(packer, folder, "")
	packer.close()
	if not ok:
		# A half-written archive next to a perfectly good build is how someone uploads half a game.
		if FileAccess.file_exists(archive):
			DirAccess.remove_absolute(archive)
		return false
	return true


func _zip_folder(packer: ZIPPacker, folder: String, prefix: String) -> bool:
	var directory := DirAccess.open(folder)
	if directory == null:
		return false
	for name in directory.get_files():
		var bytes := FileAccess.get_file_as_bytes(folder.path_join(name))
		if packer.start_file(prefix + name) != OK:
			return false
		packer.write_file(bytes)
		packer.close_file()
	for name in directory.get_directories():
		if not _zip_folder(packer, folder.path_join(name), prefix + name + "/"):
			return false
	return true


func _remove_tree(folder: String) -> void:
	var directory := DirAccess.open(folder)
	if directory == null:
		return
	for name in directory.get_files():
		DirAccess.remove_absolute(folder.path_join(name))
	for name in directory.get_directories():
		_remove_tree(folder.path_join(name))
	DirAccess.remove_absolute(folder)


func _say(message: String) -> void:
	if _dialog == null:
		_dialog = AcceptDialog.new()
		_dialog.title = "Prototir export"
		_plugin.get_editor_interface().get_base_control().add_child(_dialog)
	_dialog.dialog_text = message
	_dialog.popup_centered()
