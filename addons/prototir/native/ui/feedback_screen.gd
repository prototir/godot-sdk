extends CanvasLayer

## Opt-in desktop text feedback. The draft stays in memory until posted or the run ends.
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
var initial_text := ""


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
	var heading := Label.new()
	heading.text = "Give feedback"
	heading.add_theme_font_size_override("font_size", 22)
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading)
	_close = Button.new()
	_close.tooltip_text = "Close feedback"
	_close.custom_minimum_size = Vector2(36, 36)
	# Lucide X paths, drawn inside a centred square instead of relying on a font glyph.
	var icon := Image.new()
	icon.load_svg_from_string('<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#f4f4f5" stroke-width="2" stroke-linecap="round"><path d="M18 6 6 18M6 6l12 12"/></svg>')
	_close.icon = ImageTexture.create_from_image(icon)
	_close.pressed.connect(_dismiss)
	header.add_child(_close)
	var prompt := Label.new()
	prompt.text = "What worked? What would you change?"
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
	var ok := await Prototir.send_feedback(_text.text, str(saved.get("clientId", "")))
	_busy = false
	_close.disabled = false
	_text.editable = true
	if ok:
		_drafts.erase(_scope)
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
