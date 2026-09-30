@tool
extends RefCounted

## Publish to Prototir: export, upload, and open the website with the build already waiting,
## where the creator finishes the details and publishes.
##
## The editor never publishes on its own. Rights confirmation, visibility, cover and release notes
## belong in the form the creator already knows; this only removes the part where they find the
## ZIP and drag it into a browser. When the project has a prototype slug (Project Settings >
## prototir/prototype_slug), the browser opens that prototype's Studio page instead, to replace
## its web build or add this native one.
##
## Export for Prototir stays for offline, manual and CI use.

const EditorLink := preload("res://addons/prototir/editor/editor_link.gd")
const DirectUpload := preload("res://addons/prototir/editor/direct_upload.gd")
const EditorHttp := preload("res://addons/prototir/editor/editor_http.gd")
const DEFAULT_API_BASE := "https://api.prototir.com/api"
const TITLE := "Publish to Prototir"

signal _answered(ok: bool)

var _plugin: EditorPlugin
var _export_menu
var _http
var _progress: AcceptDialog
var _progress_label: Label
var _progress_bar: ProgressBar
var _dialog: AcceptDialog
var _question: ConfirmationDialog
var _busy := false
var _cancelled := false


func _init(plugin: EditorPlugin, export_menu) -> void:
	_plugin = plugin
	_export_menu = export_menu
	_http = EditorHttp.new(plugin)


func publish_web() -> void:
	_publish(true)


func publish_native() -> void:
	_publish(false)


func unlink() -> void:
	var api_base := _api_base()
	if EditorLink.stored(_settings(), api_base).is_empty():
		_say("This editor is not linked to a Prototir account.")
		return
	EditorLink.forget(_settings(), api_base)
	_say("This editor is unlinked. It still appears under Linked editors on your Prototir account "
		+ "page until you remove it there.")


func dispose() -> void:
	for node in [_progress, _dialog, _question]:
		if node != null:
			node.queue_free()
	_progress = null
	_dialog = null
	_question = null


func _publish(web: bool) -> void:
	if DisplayServer.get_name() == "headless":
		# Linking needs a person at a browser, which a headless run does not have.
		print("Prototir: Publish needs the editor UI. Use Export for Prototir in automated builds.")
		return
	if _busy:
		return
	if not _export_menu.has_preset(web):
		_say(_export_menu.missing_preset_message(web))
		return

	_busy = true
	_cancelled = false
	var step := "checking this editor's link"
	var api_base := _api_base()
	var failure := ""
	var unlinked := false

	# Linked first: finding out the editor is not linked after a long export is the one order
	# worse than asking up front.
	var link := await _ensure_linked(api_base)
	if link.has("error"):
		failure = str(link.error)
	else:
		step = "exporting"
		_show_progress("Exporting the %s build..." % ("Web" if web else OS.get_name()), -1.0)
		# Two frames, so the window is drawn before the export blocks the editor.
		await _plugin.get_tree().process_frame
		await _plugin.get_tree().process_frame
		var built: Dictionary = _export_menu.build(web, ProjectSettings.globalize_path("res://.godot/prototir-publish"))
		if built.has("error"):
			failure = str(built.error)
		else:
			var archive := str(built.archive)
			step = "uploading the build"
			var total := FileAccess.open(archive, FileAccess.READ).get_length()
			var sent := [0]
			var shown := func(bytes: int) -> void:
				sent[0] += bytes
				_show_progress("Uploading %s (%.1f of %.1f MB)" % [archive.get_file(),
					sent[0] / 1048576.0, total / 1048576.0], float(sent[0]) / maxf(1.0, total))
			shown.call(0)
			var uploaded: Dictionary = await DirectUpload.upload(_http, _http, api_base, str(link.token),
				archive, shown, func() -> bool: return _cancelled)
			if uploaded.has("error"):
				failure = str(uploaded.error)
				unlinked = bool(uploaded.get("unlinked", false))
			else:
				step = "registering the upload"
				_show_progress("Finishing the upload...", -1.0)
				var slug := str(ProjectSettings.get_setting("prototir/prototype_slug", "")).strip_edges()
				var version := str(ProjectSettings.get_setting("application/config/version", "")).strip_edges()
				var fields := {
					"claim": str(uploaded.claim),
					"fileName": archive.get_file(),
					"kind": "web" if web else "native",
					"slug": slug if not slug.is_empty() else null,
					# Project Settings > Application > Config > Version, offered as the build's version on
					# the website, where a native build must have one.
					"versionLabel": version if not version.is_empty() else null,
				}
				if not web:
					fields["platform"] = _platform()
					fields["architecture"] = _export_menu.native_architecture(built.preset)
				var registered: Dictionary = await DirectUpload.register(_http, api_base, str(link.token), fields)
				if registered.has("error"):
					failure = str(registered.error)
					unlinked = bool(registered.get("unlinked", false))
				else:
					OS.shell_open(_destination(str(link.app_origin), slug))
					print("Prototir: uploaded %s. Finish publishing in your browser." % archive.get_file())

	_hide_progress()
	_busy = false
	if unlinked:
		EditorLink.forget(_settings(), api_base)
	if not failure.is_empty():
		_say(failure if failure == "Cancelled." or unlinked
			else "Publishing stopped while %s: %s" % [step, failure])


## A working link, asking the creator to approve one if there is none. Returns the link or
## {"error": ...}.
func _ensure_linked(api_base: String) -> Dictionary:
	var stored := EditorLink.stored(_settings(), api_base)
	if not stored.is_empty():
		_show_progress("Checking this editor's link...", -1.0)
		var state: String = await EditorLink.verify(_http, api_base, stored)
		if state == "ok":
			return stored
		if state == "error":
			return {"error": "Prototir could not be reached. Check the connection and try again."}
		EditorLink.forget(_settings(), api_base)
	_hide_progress()

	var go: bool = await _ask("Link this editor to your Prototir account first. Your browser will open "
		+ "to approve it, once per computer.\n\nThe link can only upload builds: every upload still "
		+ "waits for you on the website before anything is published.", "Open browser")
	if not go:
		return {"error": "Cancelled."}

	_show_progress("Asking Prototir for a code...", -1.0)
	var pending: Dictionary = await EditorLink.start(_http, api_base, _label())
	if pending.has("error"):
		return pending
	OS.shell_open(str(pending.verification_url))
	_show_progress("Approve this editor in your browser. Code: %s" % pending.code, -1.0)
	var link: Dictionary = await EditorLink.wait_for_approval(_http, _http, _http, api_base, pending,
		func() -> bool: return _cancelled)
	if link.has("error"):
		return link
	EditorLink.remember(_settings(), api_base, link)
	return link


func _api_base() -> String:
	var configured := str(ProjectSettings.get_setting("prototir/api_base_url", DEFAULT_API_BASE)).strip_edges()
	return (DEFAULT_API_BASE if configured.is_empty() else configured).trim_suffix("/")


func _settings() -> EditorSettings:
	return _plugin.get_editor_interface().get_editor_settings()


## Shown on the approval page so the creator recognizes their own editor.
func _label() -> String:
	var machine := OS.get_environment("COMPUTERNAME")
	if machine.is_empty():
		machine = OS.get_environment("HOSTNAME")
	return "Godot %s on %s" % [Engine.get_version_info().get("string", "4"),
		machine if not machine.is_empty() else OS.get_name()]


func _platform() -> String:
	match OS.get_name():
		"macOS":
			return "macos"
		"Linux":
			return "linux"
	return "windows"


## Where the creator finishes. The upload is registered with Prototir, so the page lists it on its
## own; the address only says which page to open.
func _destination(origin: String, slug: String) -> String:
	if slug.is_empty():
		var title := str(ProjectSettings.get_setting("application/config/name", ""))
		return "%s/dashboard/upload?title=%s" % [origin, title.uri_encode()]
	return "%s/dashboard/%s/edit#builds" % [origin, slug.uri_encode()]


func _show_progress(text: String, fraction: float) -> void:
	if _progress == null:
		_progress = AcceptDialog.new()
		_progress.title = TITLE
		_progress.exclusive = false
		var box := VBoxContainer.new()
		box.custom_minimum_size = Vector2(420, 0)
		_progress_label = Label.new()
		_progress_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_progress_bar = ProgressBar.new()
		_progress_bar.max_value = 1.0
		box.add_child(_progress_label)
		box.add_child(_progress_bar)
		_progress.add_child(box)
		_progress.get_ok_button().text = "Cancel"
		_progress.confirmed.connect(func() -> void: _cancelled = true)
		_progress.canceled.connect(func() -> void: _cancelled = true)
		_plugin.get_editor_interface().get_base_control().add_child(_progress)
	_progress_label.text = text
	# Waits with no measurable progress (linking, exporting) show an indeterminate bar.
	_progress_bar.indeterminate = fraction < 0.0
	if fraction >= 0.0:
		_progress_bar.value = fraction
	# After Cancel the flow still finishes its current step; it must not pop the window back up.
	if not _progress.visible and not _cancelled:
		_progress.popup_centered()


func _hide_progress() -> void:
	if _progress != null and _progress.visible:
		_progress.hide()


func _ask(text: String, ok_label: String) -> bool:
	if _question == null:
		_question = ConfirmationDialog.new()
		_question.title = TITLE
		_question.confirmed.connect(func() -> void: _answered.emit(true))
		_question.canceled.connect(func() -> void: _answered.emit(false))
		_plugin.get_editor_interface().get_base_control().add_child(_question)
	_question.dialog_text = text
	_question.get_ok_button().text = ok_label
	_question.popup_centered()
	return await _answered


func _say(message: String) -> void:
	if _dialog == null:
		_dialog = AcceptDialog.new()
		_dialog.title = TITLE
		_plugin.get_editor_interface().get_base_control().add_child(_dialog)
	_dialog.dialog_text = message
	_dialog.popup_centered()
