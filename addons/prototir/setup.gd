@tool
class_name PrototirSetup
extends RefCounted

const EXPORT_PRESETS_PATH := "res://export_presets.cfg"
const MINIMUM_GODOT_MINOR := 3

## What the creator is building for Prototir. A prototype can ship both, but each export is one or
## the other, and the checks that matter are different: the Web profile is about the sandbox, a
## native build is a desktop export with none of those rules.
const TARGET_WEB := "web"
const TARGET_NATIVE := "native"
const DESKTOP_PLATFORMS := {
	"Windows": ["Windows Desktop"],
	"macOS": ["macOS"],
	"Linux": ["Linux", "Linux/X11"],
}


## The target this project is set up for. Kept in the editor's per-project metadata (under
## .godot/, never committed), so it follows the project on this machine. Until someone picks, it
## is read off the export presets: a project with only a desktop preset is building native.
static func get_target() -> String:
	if Engine.is_editor_hint():
		var stored := str(EditorInterface.get_editor_settings().get_project_metadata("prototir", "target", ""))
		if stored == TARGET_WEB or stored == TARGET_NATIVE:
			return stored
	var config := _load_export_config()
	if _find_web_preset(config).is_empty() and not _find_desktop_preset(config).is_empty():
		return TARGET_NATIVE
	return TARGET_WEB


static func set_target(target: String) -> void:
	if Engine.is_editor_hint():
		EditorInterface.get_editor_settings().set_project_metadata("prototir", "target", target)


static func get_issues(target := "") -> Array[Dictionary]:
	if target.is_empty():
		target = get_target()
	var issues: Array[Dictionary] = []
	var version := Engine.get_version_info()
	var major := int(version.get("major", 0))
	var minor := int(version.get("minor", 0))
	if major < 4 or (major == 4 and minor < MINIMUM_GODOT_MINOR):
		issues.append(_issue(
			"godot-version",
			"Godot 4.3 or newer is required",
			"This project uses Godot %s. Prototir supports Godot 4.3 and later." % version.get("string", "unknown"),
			"error"
		))

	if str(ProjectSettings.get_setting("application/run/main_scene", "")).is_empty():
		issues.append(_issue(
			"main-scene",
			"No main scene is configured",
			"Choose the scene that Godot should start before exporting the prototype.",
			"error"
		))

	if target == TARGET_NATIVE:
		_add_native_issues(issues)
	else:
		_add_web_issues(issues)
	return issues


## The standard Web profile: everything here is about running inside the Prototir sandbox, and
## none of it applies to a native export.
static func _add_web_issues(issues: Array[Dictionary]) -> void:
	var rendering_method := str(ProjectSettings.get_setting("rendering/renderer/rendering_method", ""))
	var mobile_rendering_method := str(ProjectSettings.get_setting("rendering/renderer/rendering_method.mobile", ""))
	if rendering_method != "gl_compatibility" or mobile_rendering_method != "gl_compatibility":
		issues.append(_issue(
			"renderer",
			"Compatibility renderer is not selected",
			"Use the Compatibility renderer for the supported Godot Web profile and the broadest mobile browser coverage.",
			"error",
			true
		))

	var config := _load_export_config()
	var preset := _find_web_preset(config)
	if preset.is_empty():
		issues.append(_issue(
			"web-preset",
			"Web export preset is missing",
			"Create the standard single-threaded Prototir Web export preset.",
			"error",
			true
		))
		return

	var options := "%s.options" % preset
	if bool(config.get_value(options, "variant/thread_support", false)):
		issues.append(_preset_issue("threads", "Web threads are enabled", "The standard Prototir sandbox does not provide cross-origin isolation. Disable thread support.", "error"))
	if bool(config.get_value(options, "variant/extensions_support", false)):
		issues.append(_preset_issue("extensions", "GDExtension support is enabled", "The standard browser profile does not support native GDExtension output.", "error"))
	if bool(config.get_value(options, "progressive_web_app/enabled", false)):
		issues.append(_preset_issue("pwa", "Progressive Web App output is enabled", "Prototir owns the host page and service-worker lifecycle, so export a regular Web build.", "error"))
	if int(config.get_value(options, "html/canvas_resize_policy", -1)) != 2:
		issues.append(_preset_issue("resize", "Canvas resizing is not adaptive", "Use the adaptive canvas policy so the prototype fills desktop, mobile, and embedded players.", "error"))
	if not bool(config.get_value(options, "html/focus_canvas_on_start", true)):
		issues.append(_preset_issue("focus", "Canvas focus on start is disabled", "Enable canvas focus so keyboard controls work after the player opens the prototype.", "warning"))

	var export_path := str(config.get_value(preset, "export_path", ""))
	if export_path.get_file().to_lower() != "index.html":
		issues.append(_preset_issue("entry", "Web entry file is not index.html", "Export to a path ending in index.html so the bundle can be hosted without rewriting it.", "error"))
	if not bool(config.get_value(options, "vram_texture_compression/for_mobile", false)):
		issues.append(_issue(
			"mobile-textures",
			"Mobile texture compression is disabled",
			"Enable mobile texture compression when the project targets phones or XR browsers; test image quality before publishing.",
			"warning",
			false
		))


## A native build is an ordinary desktop export. All Prototir needs is an export preset for this
## machine, which is what Export for Prototir (Native) builds from.
static func _add_native_issues(issues: Array[Dictionary]) -> void:
	if _find_desktop_preset(_load_export_config()).is_empty():
		issues.append(_issue(
			"native-preset",
			"No export preset for %s" % OS.get_name(),
			"Add one in Project > Export > Add > %s. Install its export templates from Editor > Manage Export Templates if it reports them missing." % OS.get_name(),
			"error"
		))


static func fix_issue(id: String) -> bool:
	match id:
		"renderer":
			ProjectSettings.set_setting("rendering/renderer/rendering_method", "gl_compatibility")
			ProjectSettings.set_setting("rendering/renderer/rendering_method.mobile", "gl_compatibility")
			return ProjectSettings.save() == OK
		"web-preset":
			return _create_web_preset()
		"threads":
			return _set_web_option("variant/thread_support", false)
		"extensions":
			return _set_web_option("variant/extensions_support", false)
		"pwa":
			return _set_web_option("progressive_web_app/enabled", false)
		"resize":
			return _set_web_option("html/canvas_resize_policy", 2)
		"focus":
			return _set_web_option("html/focus_canvas_on_start", true)
		"entry":
			return _set_web_export_path("build/index.html")
	return false


static func fix_all(target := "") -> void:
	for issue in get_issues(target):
		if bool(issue.get("fixable", false)):
			fix_issue(str(issue.get("id", "")))


static func has_blocking_issues(target := "") -> bool:
	return get_issues(target).any(func(issue: Dictionary) -> bool: return issue.get("severity") == "error")


static func _issue(id: String, title: String, message: String, severity: String, fixable := false) -> Dictionary:
	return {"id": id, "title": title, "message": message, "severity": severity, "fixable": fixable}


static func _preset_issue(id: String, title: String, message: String, severity: String) -> Dictionary:
	return _issue(id, title, message, severity, true)


static func _load_export_config() -> ConfigFile:
	var config := ConfigFile.new()
	config.load(EXPORT_PRESETS_PATH)
	return config


static func _find_web_preset(config: ConfigFile) -> String:
	for section in config.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options") and str(config.get_value(section, "platform", "")) == "Web":
			return section
	return ""


static func _find_desktop_preset(config: ConfigFile) -> String:
	var platforms: Array = DESKTOP_PLATFORMS.get(OS.get_name(), [])
	for section in config.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options") and platforms.has(str(config.get_value(section, "platform", ""))):
			return section
	return ""


static func _create_web_preset() -> bool:
	var config := _load_export_config()
	if not _find_web_preset(config).is_empty():
		return true
	var index := 0
	while config.has_section("preset.%d" % index):
		index += 1
	var preset := "preset.%d" % index
	var options := "%s.options" % preset
	config.set_value(preset, "name", "Web")
	config.set_value(preset, "platform", "Web")
	config.set_value(preset, "runnable", true)
	config.set_value(preset, "advanced_options", false)
	config.set_value(preset, "dedicated_server", false)
	config.set_value(preset, "custom_features", "")
	config.set_value(preset, "export_filter", "all_resources")
	config.set_value(preset, "include_filter", "")
	config.set_value(preset, "exclude_filter", "")
	config.set_value(preset, "export_path", "build/index.html")
	config.set_value(preset, "script_export_mode", 2)
	config.set_value(options, "variant/extensions_support", false)
	config.set_value(options, "variant/thread_support", false)
	config.set_value(options, "vram_texture_compression/for_desktop", true)
	config.set_value(options, "vram_texture_compression/for_mobile", false)
	config.set_value(options, "html/export_icon", true)
	config.set_value(options, "html/custom_html_shell", "")
	config.set_value(options, "html/head_include", "")
	config.set_value(options, "html/canvas_resize_policy", 2)
	config.set_value(options, "html/focus_canvas_on_start", true)
	config.set_value(options, "html/experimental_virtual_keyboard", false)
	config.set_value(options, "progressive_web_app/enabled", false)
	return config.save(EXPORT_PRESETS_PATH) == OK


static func _set_web_option(key: String, value: Variant) -> bool:
	var config := _load_export_config()
	var preset := _find_web_preset(config)
	if preset.is_empty():
		if not _create_web_preset():
			return false
		config = _load_export_config()
		preset = _find_web_preset(config)
	config.set_value("%s.options" % preset, key, value)
	return config.save(EXPORT_PRESETS_PATH) == OK


static func _set_web_export_path(path: String) -> bool:
	var config := _load_export_config()
	var preset := _find_web_preset(config)
	if preset.is_empty():
		if not _create_web_preset():
			return false
		config = _load_export_config()
		preset = _find_web_preset(config)
	config.set_value(preset, "export_path", path)
	return config.save(EXPORT_PRESETS_PATH) == OK
