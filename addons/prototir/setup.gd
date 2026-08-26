@tool
class_name PrototirSetup
extends RefCounted

const EXPORT_PRESETS_PATH := "res://export_presets.cfg"
const MINIMUM_GODOT_MINOR := 3


static func get_issues() -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	var version := Engine.get_version_info()
	var major := int(version.get("major", 0))
	var minor := int(version.get("minor", 0))
	if major < 4 or (major == 4 and minor < MINIMUM_GODOT_MINOR):
		issues.append(_issue(
			"godot-version",
			"Godot 4.3 or newer is required",
			"This project uses Godot %s. The first supported Prototir profile starts at Godot 4.3." % version.get("string", "unknown"),
			"error"
		))

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

	if str(ProjectSettings.get_setting("application/run/main_scene", "")).is_empty():
		issues.append(_issue(
			"main-scene",
			"No main scene is configured",
			"Choose the scene that Godot should start before exporting the prototype.",
			"error"
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
		return issues

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

	return issues


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


static func fix_all() -> void:
	for issue in get_issues():
		if bool(issue.get("fixable", false)):
			fix_issue(str(issue.get("id", "")))


static func has_blocking_issues() -> bool:
	return get_issues().any(func(issue: Dictionary) -> bool: return issue.get("severity") == "error")


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
