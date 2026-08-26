class_name PrototirRequest
extends RefCounted

## Emitted once for storage requests. `value` is null when a key is absent or after set/remove.
signal completed(value)
## Emitted instead of completed when a managed-AI request fails.
signal failed(code: String, message: String)

var id: int
var _settled := false


func _init(request_id: int) -> void:
	id = request_id


func resolve(value = null) -> void:
	if _settled:
		return
	_settled = true
	completed.emit(value)


func reject(code: String, message: String) -> void:
	if _settled:
		return
	_settled = true
	failed.emit(code, message)
