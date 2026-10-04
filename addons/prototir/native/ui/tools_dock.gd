extends CanvasLayer

## "Feedback & tools" in a native build: the same control as the web and Unity SDKs', in the
## bottom-left corner, unfolding Screenshot, Comment, Console and Performance inside its border.
##
## Shown by default in a build Prototir knows (its prototype slug is set), so testers get it
## without the developer writing anything. Prototir.set_feedback_tools(false) or the
## prototir/feedback_tools project setting turn it off.
##
## Kept light: folded, it does no work per frame; the Console panel rebuilds only when something was
## logged; the Performance sampler is fed only while its panel is open.

const Theme_ := preload("res://addons/prototir/native/ui/prototir_theme.gd")
const Sampler := preload("res://addons/prototir/native/performance_sampler.gd")
const ConsoleBuffer := preload("res://addons/prototir/native/console_buffer.gd")
const WARN := Color("#e0a54a")
const CHEVRON_UP := '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#a1a1aa" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m18 15-6-6-6 6"/></svg>'
const CHEVRON_DOWN := '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#a1a1aa" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m6 9 6 6 6-6"/></svg>'
const CLOSE := '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#f4f4f5" stroke-width="2" stroke-linecap="round"><path d="M18 6 6 18M6 6l12 12"/></svg>'

var sampler := Sampler.new()
var _tools: VBoxContainer
var _head: Button
var _console_state: Label
var _performance_state: Label
var _console_panel: PanelContainer
var _console_log: RichTextLabel
var _performance_panel: PanelContainer
var _chart: Control
var _stats: Label
var _seen_console := -1
var _last_frame_usec := 0
var _chevron_up: Texture2D
var _chevron_down: Texture2D


## Draws the samples as a line, with 30 and 60 fps marks in a left gutter.
class Chart:
	extends Control
	var sampler

	func _draw() -> void:
		var gutter := 28.0
		var area := Rect2(gutter, 4, size.x - gutter, size.y - 8)
		var top := 80.0
		for sample in sampler.samples:
			top = maxf(top, sample.fps)
		top *= 1.1
		var font := get_theme_default_font()
		for mark in [30.0, 60.0]:
			var y: float = area.end.y - mark / top * area.size.y
			draw_line(Vector2(area.position.x, y), Vector2(area.end.x, y), Theme_.LINE)
			draw_string(font, Vector2(0, y + 5), str(int(mark)), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Theme_.TEXT_MUTED)
		var count: int = sampler.samples.size()
		if count < 2:
			return
		var points := PackedVector2Array()
		for i in count:
			points.append(Vector2(area.position.x + area.size.x * i / (count - 1),
				area.end.y - sampler.samples[i].fps / top * area.size.y))
		draw_polyline(points, Theme_.ACCENT, 2.0, true)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 126
	_chevron_up = _icon(CHEVRON_UP)
	_chevron_down = _icon(CHEVRON_DOWN)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = Theme_.build()
	add_child(root)
	root.add_child(_build_dock())
	_console_panel = _build_console()
	root.add_child(_console_panel)
	_performance_panel = _build_performance()
	root.add_child(_performance_panel)
	set_process(false)


func _build_dock() -> Control:
	var dock := PanelContainer.new()
	dock.add_theme_stylebox_override("panel", _box(Theme_.SURFACE_RAISED, Theme_.LINE_INTERACTIVE, 6))
	dock.custom_minimum_size = Vector2(220, 0)
	dock.anchor_top = 1.0
	dock.anchor_bottom = 1.0
	dock.offset_left = 16
	dock.offset_bottom = -16
	dock.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	dock.add_child(column)
	_tools = VBoxContainer.new()
	_tools.add_theme_constant_override("separation", 0)
	_tools.visible = false
	column.add_child(_tools)
	_tools.add_child(_row("Screenshot", screenshot))
	_tools.add_child(_row("Comment", comment))
	var console_row := _row("Console", func() -> void: set_console(not _console_panel.visible))
	_console_state = _state_label(console_row)
	_tools.add_child(console_row)
	var performance_row := _row("Performance", func() -> void: set_performance(not _performance_panel.visible))
	_performance_state = _state_label(performance_row)
	_tools.add_child(performance_row)
	var rule := HSeparator.new()
	rule.add_theme_stylebox_override("separator", _line())
	_tools.add_child(rule)
	_head = _row("Feedback & tools", toggle)
	_head.add_theme_color_override("font_color", Theme_.TEXT_MUTED)
	_head.icon = _chevron_up
	_head.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_head.tooltip_text = "Feedback and tools"
	column.add_child(_head)
	return dock


func _build_console() -> PanelContainer:
	var panel := _panel("Console", func() -> void: set_console(false))
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_right = -16
	panel.offset_bottom = -16
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.custom_minimum_size = Vector2(560, 420)
	var body: VBoxContainer = panel.get_child(0)
	_console_log = RichTextLabel.new()
	_console_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_console_log.scroll_following = true
	_console_log.selection_enabled = true
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Consolas", "Menlo", "DejaVu Sans Mono", "monospace"])
	_console_log.add_theme_font_override("normal_font", mono)
	_console_log.add_theme_font_size_override("normal_font_size", 13)
	_console_log.add_theme_color_override("default_color", Theme_.TEXT)
	body.add_child(_console_log)
	if not Prototir._native.console_captures_engine:
		var note := Label.new()
		note.text = "Godot %s shows only what the game sends through Prototir.log(). Godot 4.5 or newer records everything." % Engine.get_version_info().string
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.add_theme_color_override("font_color", Theme_.TEXT_MUTED)
		body.add_child(note)
	body.add_child(_footer([
		["Copy", func() -> void: DisplayServer.clipboard_set(_native().console.text())],
		["Clear", func() -> void: _native().console.clear()],
		["Attach to comment", func() -> void: _attach(_native().console.text(), "console log")],
	]))
	panel.visible = false
	return panel


func _build_performance() -> PanelContainer:
	var panel := _panel("Performance", func() -> void: set_performance(false))
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_right = -16
	panel.offset_top = 16
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.custom_minimum_size = Vector2(340, 0)
	var body: VBoxContainer = panel.get_child(0)
	_chart = Chart.new()
	_chart.sampler = sampler
	_chart.custom_minimum_size = Vector2(0, 76)
	body.add_child(_chart)
	_stats = Label.new()
	_stats.add_theme_color_override("font_color", Theme_.TEXT_MUTED)
	_stats.add_theme_font_size_override("font_size", 13)
	body.add_child(_stats)
	body.add_child(_footer([
		["Copy", func() -> void: DisplayServer.clipboard_set(_summary())],
		["Attach to comment", func() -> void: _attach(_summary(), "performance summary")],
	]))
	panel.visible = false
	return panel


func toggle() -> void:
	_tools.visible = not _tools.visible
	_head.icon = _chevron_down if _tools.visible else _chevron_up


func set_console(on: bool) -> void:
	_console_panel.visible = on
	_console_state.text = "On" if on else "Off"
	_console_state.add_theme_color_override("font_color", Theme_.ACCENT if on else Theme_.TEXT_MUTED)
	_seen_console = -1
	_update_processing()


func set_performance(on: bool) -> void:
	_performance_panel.visible = on
	_performance_state.text = "On" if on else "Off"
	_performance_state.add_theme_color_override("font_color", Theme_.ACCENT if on else Theme_.TEXT_MUTED)
	if on:
		sampler.reset()
		_last_frame_usec = Time.get_ticks_usec()
		_stats.text = "Recording…"
		_chart.queue_redraw()
	_update_processing()


func comment() -> void:
	_fold()
	Prototir.show_feedback_screen()


## Captures the frame without this control on it, then opens the comment with the screenshot
## attached, where the tester places the pin and writes the message.
func screenshot() -> void:
	_fold()
	visible = false
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	visible = true
	var screen = Prototir.show_feedback_screen()
	if screen != null:
		screen.attach_screenshot(image)


## Only the open panels need a frame callback; folded, the control costs nothing per frame.
func _update_processing() -> void:
	set_process(_console_panel.visible or _performance_panel.visible)


func _process(_delta: float) -> void:
	if _performance_panel.visible:
		# Real time, not the scaled delta: a game in slow motion is not running at a low frame rate.
		var now := Time.get_ticks_usec()
		var frame := (now - _last_frame_usec) / 1000000.0
		_last_frame_usec = now
		if sampler.add_frame(frame, Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0):
			var latest: Dictionary = sampler.samples[-1]
			_stats.text = "%d fps · slowest frame %d ms · %d MB" % [roundi(latest.fps), roundi(latest.worst_ms), roundi(latest.memory_mb)]
			_chart.queue_redraw()
	if _console_panel.visible and _native().console.version != _seen_console:
		_seen_console = _native().console.version
		_render_console()


func _render_console() -> void:
	_console_log.clear()
	var entries: Array = _native().console.entries()
	if entries.is_empty():
		_console_log.push_color(Theme_.TEXT_MUTED)
		_console_log.add_text("Nothing logged yet.")
		_console_log.pop()
		return
	for entry in entries:
		var colour := Theme_.DANGER if entry.level == ConsoleBuffer.Level.ERROR else WARN if entry.level == ConsoleBuffer.Level.WARNING else Theme_.TEXT
		var text: String = entry.text
		var end := text.find("\n")
		_console_log.push_color(colour)
		# add_text, never BBCode: a log line is the game's text, and brackets in it are not markup.
		_console_log.add_text(ConsoleBuffer.clock(entry.time) + " " + (text if end < 0 else text.left(end)) + "\n")
		_console_log.pop()


func _summary() -> String:
	return sampler.summary("%s, %s" % [OS.get_name(), RenderingServer.get_video_adapter_name()])


func _attach(text: String, kind: String) -> void:
	var screen = Prototir.show_feedback_screen()
	if screen != null:
		screen.attach_log(text, kind)


func _fold() -> void:
	if _tools.visible:
		toggle()


func _native():
	return Prototir._native


func _row(label: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.custom_minimum_size = Vector2(0, 40)
	button.add_theme_font_size_override("font_size", 14)
	button.add_theme_stylebox_override("normal", _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 10))
	button.add_theme_stylebox_override("hover", _box(Theme_.SURFACE, Theme_.SURFACE, 10))
	button.add_theme_stylebox_override("pressed", _box(Theme_.SURFACE, Theme_.SURFACE, 10))
	button.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), Theme_.ACCENT, 10))
	button.pressed.connect(action)
	return button


func _state_label(row: Button) -> Label:
	var state := Label.new()
	state.text = "Off"
	state.add_theme_font_size_override("font_size", 12)
	state.add_theme_color_override("font_color", Theme_.TEXT_MUTED)
	state.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	state.offset_left = -50
	state.offset_right = -10
	state.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	state.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	state.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(state)
	return state


func _panel(title: String, close: Callable) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(Theme_.SURFACE, Theme_.LINE_INTERACTIVE, 12))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	panel.add_child(body)
	var header := HBoxContainer.new()
	body.add_child(header)
	var heading := Label.new()
	heading.text = title
	heading.add_theme_font_size_override("font_size", 16)
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading)
	var button := Button.new()
	button.icon = _icon(CLOSE)
	button.tooltip_text = "Close " + title
	button.custom_minimum_size = Vector2(32, 32)
	button.pressed.connect(close)
	header.add_child(button)
	return panel


func _footer(actions: Array) -> HBoxContainer:
	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_END
	for action in actions:
		var button := Button.new()
		button.text = action[0]
		button.add_theme_font_size_override("font_size", 13)
		button.pressed.connect(action[1])
		footer.add_child(button)
	return footer


static func _box(fill: Color, border: Color, margin: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(1 if border.a > 0 else 0)
	box.set_corner_radius_all(Theme_.RADIUS_CONTROL)
	box.set_content_margin_all(margin)
	return box


static func _line() -> StyleBoxLine:
	var line := StyleBoxLine.new()
	line.color = Theme_.LINE
	return line


static func _icon(svg: String) -> Texture2D:
	var image := Image.new()
	image.load_svg_from_string(svg)
	return ImageTexture.create_from_image(image)
