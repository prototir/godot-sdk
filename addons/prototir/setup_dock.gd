@tool
extends VBoxContainer

const Setup := preload("res://addons/prototir/setup.gd")

## Set by the plugin; null in a headless editor.
var update_check
var _update_error := ""


func _ready() -> void:
	name = "Prototir"
	add_theme_constant_override("separation", 8)
	refresh()


func refresh() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

	if update_check != null and (not update_check.available.is_empty() or not _update_error.is_empty()):
		add_child(_update_panel())

	var heading := Label.new()
	heading.text = "Prototir Setup"
	heading.add_theme_font_size_override("font_size", 20)
	add_child(heading)

	# What this project is building. The checks for a Web export and a native one have almost
	# nothing in common, so showing both at once would bury the ones that apply.
	var target := Setup.get_target()
	var picker := HBoxContainer.new()
	var building := Label.new()
	building.text = "Building for"
	picker.add_child(building)
	var group := ButtonGroup.new()
	for option in [[Setup.TARGET_WEB, "Web"], [Setup.TARGET_NATIVE, "Native"]]:
		var button := Button.new()
		button.text = option[1]
		button.toggle_mode = true
		button.button_group = group
		button.button_pressed = target == option[0]
		button.pressed.connect(_pick.bind(option[0]))
		picker.add_child(button)
	add_child(picker)

	var intro := Label.new()
	intro.text = ("Plays in the browser on Prototir. Checked against the supported Godot Web profile."
		if target == Setup.TARGET_WEB
		else "A Windows, macOS or Linux build people download and run. One prototype can have both.")
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(intro)

	var issues := Setup.get_issues(target)
	if issues.is_empty():
		var ready := Label.new()
		ready.text = ("Ready for a Prototir Web release." if target == Setup.TARGET_WEB
			else "Ready for a Prototir native build.")
		ready.modulate = Color("5fd995")
		add_child(ready)
	else:
		var errors := issues.filter(func(issue: Dictionary) -> bool: return issue.get("severity") == "error").size()
		var summary := Label.new()
		summary.text = "%d blocking issue(s), %d recommendation(s)" % [errors, issues.size() - errors]
		summary.modulate = Color("ff8e8e") if errors > 0 else Color("f2c66d")
		add_child(summary)
		for issue in issues:
			add_child(_issue_panel(issue))

	var actions := HBoxContainer.new()
	var refresh_button := Button.new()
	refresh_button.text = "Refresh"
	refresh_button.pressed.connect(refresh)
	actions.add_child(refresh_button)
	var fix_all_button := Button.new()
	fix_all_button.text = "Fix all available"
	fix_all_button.disabled = not issues.any(func(issue: Dictionary) -> bool: return bool(issue.get("fixable", false)))
	fix_all_button.pressed.connect(_fix_all)
	actions.add_child(fix_all_button)
	add_child(actions)


func _update_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.add_theme_constant_override("separation", 4)
	var title := Label.new()
	title.modulate = Color("8fc3ff")
	var message := Label.new()
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if update_check.available.is_empty():
		title.text = "Update did not finish"
		message.text = _update_error
	else:
		title.text = "Prototir addon %s is available" % update_check.available
		message.text = "This project has %s. Update replaces addons/prototir with the new release, then the editor restarts. Changes you made inside that folder are replaced." % update_check.installed_version()
	panel.add_child(title)
	panel.add_child(message)
	if not update_check.available.is_empty():
		var buttons := HBoxContainer.new()
		var notes := Button.new()
		notes.text = "What's new"
		notes.pressed.connect(func() -> void: OS.shell_open(update_check.changelog_url()))
		buttons.add_child(notes)
		var install := Button.new()
		install.text = "Updating..." if update_check.busy else "Update to %s" % update_check.available
		install.disabled = update_check.busy
		install.pressed.connect(_install_update)
		buttons.add_child(install)
		panel.add_child(buttons)
	panel.add_child(HSeparator.new())
	return panel


func _install_update() -> void:
	var version: String = update_check.available
	_update_error = await update_check.update()
	if not _update_error.is_empty():
		refresh()
		return
	# The new scripts are on disk, but this editor is still running the old ones: restarting is
	# what makes the update real, and the open scenes are saved first.
	var dialog := ConfirmationDialog.new()
	dialog.title = "Prototir updated"
	dialog.dialog_text = "Prototir addon %s is installed. Restart the editor to finish." % version
	dialog.ok_button_text = "Restart now"
	dialog.cancel_button_text = "Later"
	dialog.confirmed.connect(func() -> void: EditorInterface.restart_editor(true))
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


func _issue_panel(issue: Dictionary) -> Control:
	var panel := VBoxContainer.new()
	panel.add_theme_constant_override("separation", 3)
	var title := Label.new()
	title.text = "%s: %s" % ["BLOCKING" if issue.get("severity") == "error" else "RECOMMENDED", issue.get("title", "Setup issue")]
	title.modulate = Color("ff8e8e") if issue.get("severity") == "error" else Color("f2c66d")
	panel.add_child(title)
	var message := Label.new()
	message.text = str(issue.get("message", ""))
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(message)
	if bool(issue.get("fixable", false)):
		var fix_button := Button.new()
		fix_button.text = "Fix"
		fix_button.pressed.connect(_fix.bind(str(issue.get("id", ""))))
		panel.add_child(fix_button)
	return panel


func _fix(id: String) -> void:
	if not Setup.fix_issue(id):
		push_error("Prototir could not apply setup fix: %s" % id)
	refresh()


func _fix_all() -> void:
	Setup.fix_all()
	refresh()


func _pick(target: String) -> void:
	Setup.set_target(target)
	refresh()
