extends RefCounted

## Sessions that have not reached Prototir yet, kept on disk between runs.
##
## Closing a window does not leave time for an HTTP request. Godot tears the tree down immediately,
## and nothing there can be awaited, so a session sent at that moment is a session lost. Writing one
## small file takes microseconds and always finishes, and the next launch has a whole process to
## send it from. The same file covers the other case worth covering: a tester playing on a train.
##
## Sessions carry their server id, so a session sent twice updates one row rather than counting a
## play twice.

## Older sessions are dropped first when the queue is full. A build that never reaches the network
## must not grow without limit, and the most recent plays are the ones still worth reading.
const MAX_PENDING := 20

var _directory: String


func _init(directory := "user://prototir/pending") -> void:
	_directory = directory


func store(payload: Dictionary) -> bool:
	if DirAccess.make_dir_recursive_absolute(_directory) != OK:
		return false
	_trim(MAX_PENDING - 1)
	# Microseconds, so two sessions stored in the same second do not overwrite each other, and the
	# name sorts in the order they happened.
	var path := _directory.path_join("%019d.json" % Time.get_ticks_usec())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(payload))
	file.close()
	return true


## Oldest first: a tester who played three times should see those three plays land in order.
func pending() -> PackedStringArray:
	var directory := DirAccess.open(_directory)
	if directory == null:
		return PackedStringArray()
	var names := Array(directory.get_files())
	names.sort()
	var paths := PackedStringArray()
	for name in names:
		paths.append(_directory.path_join(name))
	return paths


func read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func discard(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _trim(limit: int) -> void:
	var paths := pending()
	var excess := paths.size() - limit
	for index in maxi(0, excess):
		discard(paths[index])
