extends RefCounted

## The Prototir look, as a Godot [Theme].
##
## Built in code rather than shipped as a .tres so it cannot drift from the values it copies, and
## so a creator can read where every colour came from. These are the webapp's dark tokens from
## layout.css: a pairing screen sits over a running game, where dark reads better than light and
## matches what the tester just came from on prototir.com.
##
## Lives under native/ with the rest of the download-only code, so Web exports strip it.

const BACKGROUND := Color("#0f0f11")
const SURFACE := Color("#18181b")
const SURFACE_RAISED := Color("#202024")
const TEXT := Color("#f4f4f5")
const TEXT_MUTED := Color("#a1a1aa")
const LINE := Color("#303036")
const LINE_INTERACTIVE := Color("#52525b")
const ACCENT := Color("#60a5fa")
const ACCENT_HOVER := Color("#93c5fd")
const ACCENT_CONTRAST := Color("#0f172a")
const DANGER := Color("#f87171")
const SUCCESS := Color("#4ade80")

const RADIUS_PANEL := 14
const RADIUS_CONTROL := 10


static func _panel(fill: Color, border: Color, radius: int, width := 1) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(width)
	box.set_corner_radius_all(radius)
	box.content_margin_left = 18
	box.content_margin_right = 18
	box.content_margin_top = 14
	box.content_margin_bottom = 14
	return box


static func _button(fill: Color, border: Color) -> StyleBoxFlat:
	var box := _panel(fill, border, RADIUS_CONTROL)
	box.content_margin_left = 16
	box.content_margin_right = 16
	box.content_margin_top = 9
	box.content_margin_bottom = 9
	return box


## A theme covering only what the pairing screen uses. Deliberately not a whole design system:
## anything broader would start overriding controls in the creator's own game.
static func build() -> Theme:
	var theme := Theme.new()

	theme.set_stylebox("panel", "PanelContainer", _panel(SURFACE, LINE, RADIUS_PANEL))

	theme.set_stylebox("normal", "Button", _button(SURFACE_RAISED, LINE_INTERACTIVE))
	theme.set_stylebox("hover", "Button", _button(SURFACE_RAISED, ACCENT))
	theme.set_stylebox("pressed", "Button", _button(SURFACE, ACCENT))
	theme.set_stylebox("disabled", "Button", _button(SURFACE, LINE))
	theme.set_color("font_color", "Button", TEXT)
	theme.set_color("font_hover_color", "Button", TEXT)
	theme.set_color("font_disabled_color", "Button", TEXT_MUTED)

	theme.set_color("font_color", "Label", TEXT)

	# The code itself, and the panel it sits in. Large and spaced, because it is read off a screen
	# and typed into a phone.
	var code_box := _panel(BACKGROUND, LINE_INTERACTIVE, RADIUS_CONTROL)
	code_box.content_margin_top = 18
	code_box.content_margin_bottom = 18
	theme.set_stylebox("panel", "PrototirCode", code_box)

	return theme


## The accent-filled variant, for the one action a screen is actually asking for.
static func primary(button: Button) -> void:
	button.add_theme_stylebox_override("normal", _button(ACCENT, ACCENT))
	button.add_theme_stylebox_override("hover", _button(ACCENT_HOVER, ACCENT_HOVER))
	button.add_theme_stylebox_override("pressed", _button(ACCENT, ACCENT))
	button.add_theme_color_override("font_color", ACCENT_CONTRAST)
	button.add_theme_color_override("font_hover_color", ACCENT_CONTRAST)
	button.add_theme_color_override("font_pressed_color", ACCENT_CONTRAST)
