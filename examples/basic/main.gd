extends Control

var current_score := 0
@onready var status: Label = $Panel/Status


func _ready() -> void:
	Prototir.ready()
	var request := Prototir.storage_get("sample.score")
	var saved = await request.completed
	if saved != null:
		current_score = int(saved)
	status.text = "Ready - saved score %d" % current_score


func _on_add_point_pressed() -> void:
	current_score += 1
	Prototir.score(current_score)
	Prototir.event("sample_point", {"score": current_score})
	Prototir.storage_set("sample.score", str(current_score))
	status.text = "Score %d" % current_score
