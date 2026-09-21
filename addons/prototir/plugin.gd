@tool
extends EditorPlugin

const AUTOLOAD_NAME := "Prototir"
const AUTOLOAD_PATH := "res://addons/prototir/prototir.gd"
const Setup := preload("res://addons/prototir/setup.gd")
const SetupDock := preload("res://addons/prototir/setup_dock.gd")
const ExportGuard := preload("res://addons/prototir/export_guard.gd")
const ExportMenu := preload("res://addons/prototir/export_menu.gd")

const SETTINGS := {
	"prototir/prototype_slug": "",
	# Kept in step with NativeRuntime.DEFAULT_API_BASE, which explains the choice of host.
	"prototir/api_base_url": "https://api.prototir.com/api",
	"prototir/device_label": "",
}

var _setup_dock
var _export_guard: EditorExportPlugin
var _export_menu


func _enter_tree() -> void:
	if not ProjectSettings.has_setting("autoload/%s" % AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	_setup_dock = SetupDock.new()
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _setup_dock)
	add_tool_menu_item("Prototir: Validate Web Setup", _show_setup)
	_export_menu = ExportMenu.new(self)
	add_tool_menu_item("Prototir: Export for Prototir (Web)", _export_menu.export_web)
	add_tool_menu_item("Prototir: Export for Prototir (Download)", _export_menu.export_download)
	_export_guard = ExportGuard.new()
	add_export_plugin(_export_guard)
	# Not in a headless editor. The export buttons run a second, headless copy of this editor to
	# do the actual exporting, and that copy loads this plugin too: registering there would mean
	# two processes writing project.godot at once, for settings whose only purpose is to appear
	# in a dialog nobody is looking at.
	if DisplayServer.get_name() != "headless":
		_register_settings()
	call_deferred("_report_setup")


## Where a downloadable build learns which prototype it is. A Web export needs none of this: the
## page it runs in already knows, and the browser path keeps taking its context from there. A
## download has no page, so the slug has to travel inside the build.
func _register_settings() -> void:
	for name in SETTINGS:
		if not ProjectSettings.has_setting(name):
			ProjectSettings.set_setting(name, SETTINGS[name])
		ProjectSettings.set_initial_value(name, SETTINGS[name])
		ProjectSettings.add_property_info({
			"name": name,
			"type": TYPE_STRING,
			"hint": PROPERTY_HINT_NONE,
		})
	ProjectSettings.save()


func _exit_tree() -> void:
	if _export_guard != null:
		remove_export_plugin(_export_guard)
		_export_guard = null
	remove_tool_menu_item("Prototir: Export for Prototir (Web)")
	remove_tool_menu_item("Prototir: Export for Prototir (Download)")
	remove_tool_menu_item("Prototir: Validate Web Setup")
	if _export_menu != null:
		_export_menu.dispose()
		_export_menu = null
	if _setup_dock != null:
		remove_control_from_docks(_setup_dock)
		_setup_dock.queue_free()
		_setup_dock = null
	var setting := "autoload/%s" % AUTOLOAD_NAME
	var configured_path := str(ProjectSettings.get_setting(setting, "")).trim_prefix("*")
	if configured_path == AUTOLOAD_PATH:
		remove_autoload_singleton(AUTOLOAD_NAME)


func _show_setup() -> void:
	if _setup_dock != null:
		_setup_dock.refresh()
		_setup_dock.show()


func _report_setup() -> void:
	var issues := Setup.get_issues()
	if issues.is_empty():
		return
	var blocking := issues.filter(func(issue: Dictionary) -> bool: return issue.get("severity") == "error").size()
	push_warning("Prototir setup found %d blocking issue(s) and %d recommendation(s). Open the Prototir dock to review them." % [blocking, issues.size() - blocking])
