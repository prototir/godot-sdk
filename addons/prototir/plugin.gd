@tool
extends EditorPlugin

const AUTOLOAD_NAME := "Prototir"
const AUTOLOAD_PATH := "res://addons/prototir/prototir.gd"
const Setup := preload("res://addons/prototir/setup.gd")
const SetupDock := preload("res://addons/prototir/setup_dock.gd")
const ExportGuard := preload("res://addons/prototir/export_guard.gd")

var _setup_dock
var _export_guard: EditorExportPlugin


func _enter_tree() -> void:
	if not ProjectSettings.has_setting("autoload/%s" % AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	_setup_dock = SetupDock.new()
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _setup_dock)
	add_tool_menu_item("Prototir: Validate Web Setup", _show_setup)
	_export_guard = ExportGuard.new()
	add_export_plugin(_export_guard)
	call_deferred("_report_setup")


func _exit_tree() -> void:
	if _export_guard != null:
		remove_export_plugin(_export_guard)
		_export_guard = null
	remove_tool_menu_item("Prototir: Validate Web Setup")
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
