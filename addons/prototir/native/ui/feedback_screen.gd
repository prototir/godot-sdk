extends CanvasLayer

## The native comment composer. The draft stays in memory until posted or the run ends.
##
## A screenshot or a console log can be attached (Feedback & tools), but a message is always
## required: they are what the comment is about, never sent alone.
const Theme_ := preload("res://addons/prototir/native/ui/prototir_theme.gd")
static var _drafts := {}
signal closed()
var _scope := ""
var _text: TextEdit
var _post: Button
var _close: Button
var _status: Label
var _busy := false
var _pairing: Node
var _heading: Label
var _shot_box: VBoxContainer
var _shot_view: TextureRect
var _pin: Control
var _attachment_box: PanelContainer
var _attachment_label: Label
var initial_text := ""

## What is attached, kept per run like the text: {"log", "kind", "image" (data URL), "texture",
## "pin" (Vector2 from 0 to 1)}.
static var _attachments := {}


## Draws the pin where the tester clicked, over the screenshot.
class Pin:
	extends Control
	var at := Vector2(0.5, 0.5)
	func _draw() -> void:
		var centre := at * size
		draw_circle(centre, 9.0, Theme_.ACCENT_CONTRAST)
		draw_circle(centre, 7.0, Theme_.ACCENT)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 127
	_scope = Prototir._native._slug
	var scrim := ColorRect.new()
	scrim.color = Color(Theme_.BACKGROUND, 0.82)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(centre)
	var panel := PanelContainer.new()
	panel.theme = Theme_.build()
	panel.custom_minimum_size = Vector2(440, 0)
	centre.add_child(panel)
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 14)
	panel.add_child(card)
	var header := HBoxContainer.new()
	card.add_child(header)
	_heading = Label.new()
	_heading.add_theme_font_size_override("font_size", 22)
	_heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_heading)
	_close = Button.new()
	_close.tooltip_text = "Close feedback"
	_close.custom_minimum_size = Vector2(36, 36)
	# Lucide X paths, drawn inside a centred square instead of relying on a font glyph.
	var icon := Image.new()
	icon.load_svg_from_string('<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#f4f4f5" stroke-width="2" stroke-linecap="round"><path d="M18 6 6 18M6 6l12 12"/></svg>')
	_close.icon = ImageTexture.create_from_image(icon)
	_close.pressed.connect(_dismiss)
	header.add_child(_close)
	_shot_box = VBoxContainer.new()
	card.add_child(_shot_box)
	var centre_shot := CenterContainer.new()
	_shot_box.add_child(centre_shot)
	_shot_view = TextureRect.new()
	_shot_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_shot_view.stretch_mode = TextureRect.STRETCH_SCALE
	_shot_view.mouse_filter = Control.MOUSE_FILTER_STOP
	_shot_view.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_shot_view.gui_input.connect(_place_pin)
	centre_shot.add_child(_shot_view)
	_pin = Pin.new()
	_pin.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shot_view.add_child(_pin)
	var shot_row := HBoxContainer.new()
	_shot_box.add_child(shot_row)
	var hint := Label.new()
	hint.text = "Click the screenshot to place the pin."
	hint.add_theme_color_override("font_color", Theme_.TEXT_MUTED)
	hint.add_theme_font_size_override("font_size", 13)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shot_row.add_child(hint)
	shot_row.add_child(_link("Remove screenshot", _remove_screenshot))
	_attachment_box = PanelContainer.new()
	_attachment_box.add_theme_stylebox_override("panel", Theme_._button(Theme_.SURFACE_RAISED, Theme_.LINE))
	card.add_child(_attachment_box)
	var attachment_row := HBoxContainer.new()
	_attachment_box.add_child(attachment_row)
	_attachment_label = Label.new()
	_attachment_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	attachment_row.add_child(_attachment_label)
	attachment_row.add_child(_link("Remove", _remove_log))
	var prompt := Label.new()
	prompt.text = "Your message (required)"
	card.add_child(prompt)
	_text = TextEdit.new()
	_text.custom_minimum_size = Vector2(0, 136)
	_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_text.add_theme_color_override("font_color", Theme_.TEXT)
	_text.add_theme_stylebox_override("normal", Theme_._panel(Theme_.SURFACE_RAISED, Theme_.LINE_INTERACTIVE, 10))
	_text.add_theme_stylebox_override("focus", Theme_._panel(Theme_.SURFACE_RAISED, Theme_.ACCENT, 10))
	_text.text = str(_drafts.get(_scope, {}).get("text", initial_text.left(2000)))
	_text.text_changed.connect(_changed)
	card.add_child(_text)
	var notice := Label.new()
	notice.text = "Comments are visible to everyone who can access this prototype. Sign-in happens in your browser."
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice.add_theme_color_override("font_color", Theme_.TEXT_MUTED)
	card.add_child(notice)
	_post = Button.new()
	_post.pressed.connect(_submit)
	Theme_.primary(_post)
	card.add_child(_post)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", Theme_.TEXT_MUTED)
	card.add_child(_status)
	_refresh_attachments()
	_changed()
	_text.grab_focus.call_deferred()


func _changed() -> void:
	if _text.text.length() > 2000:
		_text.text = _text.text.left(2000)
	var saved: Dictionary = _drafts.get(_scope, {})
	if saved.get("text", "") != _text.text:
		saved = {"text": _text.text, "clientId": _new_id()}
	_drafts[_scope] = saved
	_post.text = "Post comment" if Prototir.is_paired() else "Sign in to post"
	_post.disabled = _busy or _text.text.strip_edges().is_empty()


func _new_id() -> String:
	var hex := Crypto.new().generate_random_bytes(16).hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)]


func _submit() -> void:
	if _busy or _text.text.strip_edges().is_empty():
		return
	if _scope != Prototir._native._slug:
		_status.text = "This build changed prototype. Close and reopen feedback before posting."
		return
	if not Prototir.is_paired():
		hide()
		_pairing = Prototir.show_pairing_screen()
		_pairing.closed.connect(_paired)
		return
	_busy = true
	_close.disabled = true
	_text.editable = false
	_post.disabled = true
	_post.text = "Posting..."
	var saved: Dictionary = _drafts[_scope]
	var attached: Dictionary = _attachments.get(_scope, {})
	var screenshot := {}
	if attached.has("image"):
		var pin: Vector2 = attached.get("pin", Vector2(0.5, 0.5))
		screenshot = {"image": attached.image, "x": pin.x, "y": pin.y}
	var ok: bool = await Prototir._native.send_feedback(_text.text, str(saved.get("clientId", "")), str(attached.get("log", "")), screenshot)
	_busy = false
	_close.disabled = false
	_text.editable = true
	if ok:
		_drafts.erase(_scope)
		_attachments.erase(_scope)
		_refresh_attachments()
		_text.text = ""
		_status.text = "Comment posted."
	else:
		_status.text = "Not posted. Check your connection or edit the comment, then try again. Your draft is kept." if Prototir.is_paired() else "Sign in again to post. Your draft is kept."
	_changed()


func _paired() -> void:
	_pairing = null
	show()
	_status.text = "Connected. Review your comment, then post." if Prototir.is_paired() else "Your draft is kept. Sign in when you are ready."
	_changed()


func _dismiss() -> void:
	if _busy:
		return
	closed.emit()
	queue_free()


## Attaches a console log or performance summary; `kind` names it for the tester.
func attach_log(text: String, kind := "log") -> void:
	if _busy or text.strip_edges().is_empty():
		return
	var attached: Dictionary = _attachments.get(_current_scope(), {})
	attached["log"] = text
	attached["kind"] = kind
	_attach(attached)


## Attaches a captured frame, scaled to at most 1280 pixels and encoded as JPEG under the 1 MiB
## Prototir accepts. The pin starts in the middle until the tester places it.
func attach_screenshot(image: Image) -> void:
	if _busy or image == null or image.is_empty():
		return
	var shot: Image = image.duplicate()
	var factor := minf(1.0, 1280.0 / maxf(shot.get_width(), shot.get_height()))
	if factor < 1.0:
		shot.resize(roundi(shot.get_width() * factor), roundi(shot.get_height() * factor), Image.INTERPOLATE_BILINEAR)
	var bytes := shot.save_jpg_to_buffer(0.82)
	var quality := 0.7
	while bytes.size() > 900 * 1024 and quality >= 0.4:
		bytes = shot.save_jpg_to_buffer(quality)
		quality -= 0.15
	var attached: Dictionary = _attachments.get(_current_scope(), {})
	attached["image"] = "data:image/jpeg;base64," + Marshalls.raw_to_base64(bytes)
	attached["texture"] = ImageTexture.create_from_image(shot)
	attached["pin"] = Vector2(0.5, 0.5)
	_attach(attached)


func _current_scope() -> String:
	return _scope if is_node_ready() else Prototir._native._slug


func _attach(attached: Dictionary) -> void:
	var scope := _current_scope()
	_attachments[scope] = attached
	# A different attachment is a different comment, so a retry must not reuse the old id.
	if _drafts.has(scope):
		_drafts[scope]["clientId"] = _new_id()
	if is_node_ready():
		_status.text = ""
		_refresh_attachments()


func _refresh_attachments() -> void:
	var attached: Dictionary = _attachments.get(_scope, {})
	_heading.text = "Screenshot feedback" if attached.has("texture") else "Comment"
	_shot_box.visible = attached.has("texture")
	if attached.has("texture"):
		var texture: Texture2D = attached.texture
		var fit := minf(404.0 / texture.get_width(), 150.0 / texture.get_height())
		_shot_view.texture = texture
		_shot_view.custom_minimum_size = texture.get_size() * fit
		_pin.at = attached.get("pin", Vector2(0.5, 0.5))
		_pin.queue_redraw()
	_attachment_box.visible = attached.has("log")
	# Room for what is attached on a 720p screen: the message box gives up a little height.
	_text.custom_minimum_size.y = 96 if not attached.is_empty() else 136
	if attached.has("log"):
		var lines := str(attached.log).count("\n") + 1
		var kind := str(attached.get("kind", "log"))
		_attachment_label.text = "%s attached · %d %s" % [kind.left(1).to_upper() + kind.substr(1), lines, "line" if lines == 1 else "lines"]


func _place_pin(event: InputEvent) -> void:
	if _busy or not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var at: Vector2 = (event.position / _shot_view.size).clamp(Vector2.ZERO, Vector2.ONE)
	_attachments[_scope]["pin"] = at
	_pin.at = at
	_pin.queue_redraw()


func _remove_screenshot() -> void:
	var attached: Dictionary = _attachments.get(_scope, {})
	for key in ["image", "texture", "pin"]:
		attached.erase(key)
	_attach(attached)


func _remove_log() -> void:
	var attached: Dictionary = _attachments.get(_scope, {})
	attached.erase("log")
	attached.erase("kind")
	_attach(attached)


func _link(label: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.flat = true
	button.add_theme_color_override("font_color", Theme_.ACCENT)
	button.add_theme_color_override("font_hover_color", Theme_.ACCENT_HOVER)
	button.add_theme_font_size_override("font_size", 13)
	button.pressed.connect(action)
	return button
