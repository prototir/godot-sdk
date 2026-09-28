extends Node

## Load scripts with the project's autoloads available, as they are in a creator's game.
func _ready() -> void:
	var failures := 0
	var scripts := PackedStringArray()
	for folder in ["res://addons", "res://tests", "res://examples"]:
		scripts.append_array(_scripts_in(folder))
	scripts.sort()
	for path in scripts:
		print("Checking %s" % path)
		var script: GDScript = load(path)
		if script == null or not script.can_instantiate():
			printerr("Invalid script: %s" % path)
			failures += 1
	print("%d project scripts, %d failed" % [scripts.size(), failures])
	get_tree().quit(1 if failures > 0 or scripts.is_empty() else 0)


func _scripts_in(folder: String) -> PackedStringArray:
	var scripts := PackedStringArray()
	for file in DirAccess.get_files_at(folder):
		if file.ends_with(".gd"):
			scripts.append(folder.path_join(file))
	for child in DirAccess.get_directories_at(folder):
		scripts.append_array(_scripts_in(folder.path_join(child)))
	return scripts
