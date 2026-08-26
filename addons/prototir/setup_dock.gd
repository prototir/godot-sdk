@tool
extends VBoxContainer

const Setup := preload("res://addons/prototir/setup.gd")


func _ready() -> void:
	name = "Prototir"
	add_theme_constant_override("separation", 8)
	refresh()


func refresh() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

	var heading := Label.new()
	heading.text = "Prototir Web Setup"
	heading.add_theme_font_size_override("font_size", 20)
	add_child(heading)

	var intro := Label.new()
	intro.text = "Checks this project against the supported Godot Web profile before export."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(intro)

	var issues := Setup.get_issues()
	if issues.is_empty():
		var ready := Label.new()
		ready.text = "Ready for a Prototir Web release."
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
