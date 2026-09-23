extends CanvasLayer

## A pairing screen a creator can use as it is.
##
## The addon still draws nothing on its own, and the signals it emits are still the supported way
## to build your own. This exists because the honest consequence of "draw it yourself" was that
## every creator had to build a screen before collecting a single session, and the only thing to
## copy from was an unstyled example. So there is now a default that looks like Prototir, and
## ignoring it costs nothing.
##
## One line to show it:
## [codeblock]
## Prototir.show_pairing_screen()
## [/codeblock]
##
## A [CanvasLayer] rather than a [Control] so it draws over whatever the game is already
## rendering, without being parented into the game's own UI.

const Theme_ := preload("res://addons/prototir/native/ui/prototir_theme.gd")

## Emitted when the tester dismisses the screen, paired or not, so a game can resume.
signal closed()

var _code := ""
var _verification_url := ""

var _card: VBoxContainer
var _heading: Label
var _body: Label
var _code_panel: PanelContainer
var _code_label: Label
var _qr: TextureRect
var _actions: HBoxContainer
var _note: Label


func _ready() -> void:
	layer = 128
	_build()
	Prototir.pairing_started.connect(_on_started)
	Prototir.pairing_succeeded.connect(_on_succeeded)
	Prototir.pairing_failed.connect(_on_failed)
	_show_idle()


func _build() -> void:
	var theme := Theme_.build()

	# Dimmed, not opaque: the tester should still see the game they are pairing.
	var scrim := ColorRect.new()
	scrim.color = Color(Theme_.BACKGROUND, 0.82)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(scrim)

	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)

	var panel := PanelContainer.new()
	panel.theme = theme
	panel.custom_minimum_size = Vector2(440, 0)
	centre.add_child(panel)

	_card = VBoxContainer.new()
	_card.add_theme_constant_override("separation", 14)
	panel.add_child(_card)

	var brand := Label.new()
	brand.text = "PROTOTIR"
	brand.add_theme_color_override("font_color", Theme_.ACCENT)
	brand.add_theme_font_size_override("font_size", 12)
	_card.add_child(brand)

	_heading = Label.new()
	_heading.add_theme_font_size_override("font_size", 22)
	_heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card.add_child(_heading)

	_body = Label.new()
	_body.add_theme_color_override("font_color", Theme_.TEXT_MUTED)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.custom_minimum_size = Vector2(400, 0)
	_card.add_child(_body)

	_code_panel = PanelContainer.new()
	_code_panel.theme = theme
	_code_panel.add_theme_stylebox_override("panel", theme.get_stylebox("panel", "PrototirCode"))
	_code_panel.visible = false
	_card.add_child(_code_panel)

	var code_rows := VBoxContainer.new()
	code_rows.add_theme_constant_override("separation", 12)
	code_rows.alignment = BoxContainer.ALIGNMENT_CENTER
	_code_panel.add_child(code_rows)

	_code_label = Label.new()
	_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_label.add_theme_font_size_override("font_size", 34)
	code_rows.add_child(_code_label)

	_qr = TextureRect.new()
	_qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_qr.custom_minimum_size = Vector2(0, 168)
	_qr.visible = false
	code_rows.add_child(_qr)

	_actions = HBoxContainer.new()
	_actions.add_theme_constant_override("separation", 8)
	_card.add_child(_actions)

	_note = Label.new()
	_note.add_theme_color_override("font_color", Theme_.TEXT_MUTED)
	_note.add_theme_font_size_override("font_size", 12)
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.custom_minimum_size = Vector2(400, 0)
	_card.add_child(_note)


func _clear_actions() -> void:
	for child in _actions.get_children():
		child.queue_free()
		_actions.remove_child(child)


func _action(label: String, handler: Callable, primary := false) -> Button:
	var button := Button.new()
	button.text = label
	button.pressed.connect(handler)
	if primary:
		Theme_.primary(button)
	_actions.add_child(button)
	return button


func _show_idle() -> void:
	_clear_actions()
	_code_panel.visible = false
	if Prototir.is_paired():
		_heading.text = "This build is connected"
		_body.text = "Plays and feedback from this machine are recorded against your Prototir account."
		_note.text = "You can disconnect it here, or from your account settings on prototir.com."
		_action("Done", _close, true)
		_action("Disconnect", _on_unpair)
		return

	_heading.text = "Connect this build"
	_body.text = "Pairing links this copy to your Prototir account, so the plays and feedback it reports are attributed to you. It takes one approval on prototir.com and lasts for this machine."
	_note.text = "Until then this build reports nothing, by design: there is nobody to attribute a play to."
	_action("Get a code", _on_pair, true)
	_action("Not now", _close)


func _on_pair() -> void:
	_clear_actions()
	_heading.text = "Getting a code"
	_body.text = "Asking Prototir for a one-time code for this build."
	_note.text = ""
	_action("Cancel", _on_cancel)
	Prototir.begin_pairing()


func _on_started(request: Dictionary) -> void:
	_code = str(request.get("code", ""))
	_verification_url = str(request.get("verification_url", ""))
	var title := str(request.get("prototype_title", ""))

	_heading.text = "Approve this build"
	_body.text = (
		"Open the link on any device, sign in, and enter this code%s."
		% ("" if title.is_empty() else " for %s" % title)
	)
	_code_label.text = _code
	_code_panel.visible = true
	_show_qr(str(request.get("qr_svg", "")))

	_clear_actions()
	if not _verification_url.is_empty():
		_action("Open in browser", _on_open, true)
	_action("Copy code", _on_copy)
	_action("Cancel", _on_cancel)
	_note.text = "Waiting for approval. This screen updates on its own."


## The server sends the same code as an SVG. Godot can rasterise one from a string, so the QR is
## drawn rather than described, which is what makes this usable on a headset or a TV where typing
## a code is the worst part of the flow.
func _show_qr(svg: String) -> void:
	_qr.visible = false
	if svg.is_empty():
		return
	var image := Image.new()
	if image.load_svg_from_string(svg, 2.0) != OK:
		return
	_qr.texture = ImageTexture.create_from_image(image)
	_qr.visible = true


func _on_open() -> void:
	if not _verification_url.is_empty():
		OS.shell_open(_verification_url)


func _on_copy() -> void:
	DisplayServer.clipboard_set(_code)
	_note.text = "Code copied. Waiting for approval."


func _on_cancel() -> void:
	Prototir.cancel_pairing()
	_code_panel.visible = false
	_show_idle()


func _on_unpair() -> void:
	Prototir.unpair()
	_show_idle()


func _on_succeeded() -> void:
	_clear_actions()
	_code_panel.visible = false
	_heading.text = "Connected"
	_body.text = "This build can now report plays and send feedback as you."
	_note.text = ""
	_action("Play", _close, true)


func _on_failed(message: String) -> void:
	_clear_actions()
	_code_panel.visible = false
	_heading.text = "Not connected"
	_body.text = message
	_note.text = "Nothing was recorded. You can try again, or keep playing without pairing."
	_action("Try again", _on_pair, true)
	_action("Not now", _close)


func _close() -> void:
	closed.emit()
	queue_free()
