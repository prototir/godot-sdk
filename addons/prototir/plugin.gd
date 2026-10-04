@tool
extends EditorPlugin

const AUTOLOAD_NAME := "Prototir"
const AUTOLOAD_PATH := "res://addons/prototir/prototir.gd"
const Setup := preload("res://addons/prototir/setup.gd")
const SetupDock := preload("res://addons/prototir/setup_dock.gd")
const ExportGuard := preload("res://addons/prototir/export_guard.gd")
const ExportMenu := preload("res://addons/prototir/export_menu.gd")
const PublishMenu := preload("res://addons/prototir/editor/publish_menu.gd")
const UpdateCheck := preload("res://addons/prototir/editor/update_check.gd")

const SETTINGS := {
	"prototir/prototype_slug": "",
	# Kept in step with NativeRuntime.DEFAULT_API_BASE, which explains the choice of host.
	"prototir/api_base_url": "https://api.prototir.com/api",
	"prototir/device_label": "",
	# Feedback & tools for testers in native builds; see native/ui/tools_dock.gd.
	"prototir/feedback_tools": true,
}

var _setup_dock
var _export_guard: EditorExportPlugin
var _export_menu
var _publish_menu
var _update_check


func _enter_tree() -> void:
	if not ProjectSettings.has_setting("autoload/%s" % AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	_setup_dock = SetupDock.new()
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _setup_dock)
	add_tool_menu_item("Prototir: Validate Web Setup", _show_setup)
	_export_menu = ExportMenu.new(self)
	add_tool_menu_item("Prototir: Export for Prototir (Web)", _export_menu.export_web)
	add_tool_menu_item("Prototir: Export for Prototir (Native)", _export_menu.export_native)
	# Export, upload and open the website with the build waiting there (§16.5.35).
	_publish_menu = PublishMenu.new(self, _export_menu)
	add_tool_menu_item("Prototir: Publish to Prototir (Web)", _publish_menu.publish_web)
	add_tool_menu_item("Prototir: Publish to Prototir (Native)", _publish_menu.publish_native)
	add_tool_menu_item("Prototir: Unlink This Editor", _publish_menu.unlink)
	_export_guard = ExportGuard.new()
	add_export_plugin(_export_guard)
	# Not in a headless editor. The export buttons run a second, headless copy of this editor to
	# do the actual exporting, and that copy loads this plugin too: registering there would mean
	# two processes writing project.godot at once, for settings whose only purpose is to appear
	# in a dialog nobody is looking at.
	if DisplayServer.get_name() != "headless":
		_register_settings()
		# Same reason, and a headless copy has nobody to tell about an update.
		_update_check = UpdateCheck.new()
		add_child(_update_check)
		_setup_dock.update_check = _update_check
		_update_check.changed.connect(_setup_dock.refresh)
		_update_check.check.call_deferred()
	add_tool_menu_item("Prototir: Check for Addon Updates", _check_updates)
	call_deferred("_report_setup")


## Where a native build learns which prototype it is. A Web export needs none of this: the
## page it runs in already knows, and the browser path keeps taking its context from there. A
## native build has no page, so the slug has to travel inside the build.
func _register_settings() -> void:
	for name in SETTINGS:
		if not ProjectSettings.has_setting(name):
			ProjectSettings.set_setting(name, SETTINGS[name])
		ProjectSettings.set_initial_value(name, SETTINGS[name])
		ProjectSettings.add_property_info({
			"name": name,
			"type": typeof(SETTINGS[name]),
			"hint": PROPERTY_HINT_NONE,
		})
	ProjectSettings.save()


func _exit_tree() -> void:
	if _export_guard != null:
		remove_export_plugin(_export_guard)
		_export_guard = null
	remove_tool_menu_item("Prototir: Export for Prototir (Web)")
	remove_tool_menu_item("Prototir: Export for Prototir (Native)")
	remove_tool_menu_item("Prototir: Validate Web Setup")
	remove_tool_menu_item("Prototir: Publish to Prototir (Web)")
	remove_tool_menu_item("Prototir: Publish to Prototir (Native)")
	remove_tool_menu_item("Prototir: Unlink This Editor")
	remove_tool_menu_item("Prototir: Check for Addon Updates")
	if _update_check != null:
		_update_check.queue_free()
		_update_check = null
	if _publish_menu != null:
		_publish_menu.dispose()
		_publish_menu = null
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


func _check_updates() -> void:
	if _update_check != null:
		_update_check.check(true)
	_show_setup()


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
