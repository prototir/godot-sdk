extends Control

## A working pairing screen for a downloadable build, building its own UI in code so it drops
## into any scene without wiring.
##
## The addon draws nothing itself, because it cannot know your art direction, your input model, or
## whether you are in VR. This exists so you can see the whole flow work before you build your own,
## and so there is something to point at when the answer is "draw it yourself".
##
## Read it, then rebuild it in whatever UI your game already uses.

var _code := ""
var _verification_url := ""

var _status: Label
var _title: Label
var _code_label: Label
var _message: Label
var _pair_button: Button
var _open_button: Button
var _copy_button: Button
var _cancel_button: Button
var _feedback_button: Button
var _unpair_button: Button


func _ready() -> void:
	_build_ui()
	Prototir.pairing_started.connect(_on_pairing_started)
	Prototir.pairing_succeeded.connect(_on_pairing_succeeded)
	Prototir.pairing_failed.connect(_on_pairing_failed)
	_refresh()


func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(24, 24)
	panel.custom_minimum_size = Vector2(420, 0)
	add_child(panel)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 8)
	panel.add_child(rows)

	_status = Label.new()
	rows.add_child(_status)

	_title = Label.new()
	rows.add_child(_title)

	_code_label = Label.new()
	_code_label.add_theme_font_size_override("font_size", 32)
	rows.add_child(_code_label)

	# A game window has no selectable text, so a printed URL on its own leaves the tester
	# retyping it off a screen. Opening a browser covers the desktop case; the clipboard and the
	# bare code cover a headset, where a browser on this machine helps nobody.
	var buttons := HBoxContainer.new()
	rows.add_child(buttons)

	_pair_button = _button(buttons, "Pair this build", _on_pair_pressed)
	_open_button = _button(buttons, "Open in browser", _on_open_pressed)
	_copy_button = _button(buttons, "Copy code", _on_copy_pressed)
	_cancel_button = _button(buttons, "Cancel", _on_cancel_pressed)
	_feedback_button = _button(buttons, "Send test feedback", _on_feedback_pressed)
	_unpair_button = _button(buttons, "Unpair", _on_unpair_pressed)

	_message = Label.new()
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(_message)


func _button(parent: Node, text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(handler)
	parent.add_child(button)
	return button


func _refresh() -> void:
	var waiting := not _code.is_empty()
	var paired := Prototir.is_paired()

	_status.text = "Status: " + ("paired" if paired else ("waiting for approval" if waiting else "not paired"))
	_title.visible = waiting and not _title.text.is_empty()
	_code_label.visible = waiting
	_code_label.text = _code

	_pair_button.visible = not waiting and not paired
	_open_button.visible = waiting and not _verification_url.is_empty()
	_copy_button.visible = waiting
	_cancel_button.visible = waiting
	_feedback_button.visible = paired and not waiting
	_unpair_button.visible = paired and not waiting


func _on_pair_pressed() -> void:
	_message.text = ""
	# Deliberately not awaited here: the panel reacts to the signals instead, which is what a
	# game's own screen would do.
	Prototir.begin_pairing()


func _on_open_pressed() -> void:
	OS.shell_open(_verification_url)


func _on_copy_pressed() -> void:
	DisplayServer.clipboard_set(_code)
	_message.text = "Code copied."


func _on_cancel_pressed() -> void:
	Prototir.cancel_pairing()
	_code = ""
	_message.text = "Pairing cancelled."
	_refresh()


func _on_feedback_pressed() -> void:
	_message.text = "Sending..."
	var sent: bool = await Prototir.send_feedback("Hello from a downloaded build.")
	_message.text = "Feedback posted on the prototype page." if sent else "That feedback was not accepted."


func _on_unpair_pressed() -> void:
	Prototir.unpair()
	_message.text = "This build will pair again next time."
	_refresh()


func _on_pairing_started(request: Dictionary) -> void:
	_code = str(request.get("code", ""))
	_verification_url = str(request.get("verification_url", ""))
	_title.text = str(request.get("prototype_title", ""))
	# request.qr_svg is the same code as an SVG the server rendered. Draw it if you can; the code
	# and the link work on their own if you cannot.
	_message.text = "Approve it at " + _verification_url
	_refresh()


func _on_pairing_succeeded() -> void:
	_code = ""
	_message.text = "Paired. This build can now report sessions and send feedback."
	_refresh()


func _on_pairing_failed(reason: String) -> void:
	_code = ""
	_message.text = reason
	_refresh()
