extends Node

const SAVE_FILE_PATH = "user://save_data.save"

var high_score: int = 0
var max_chain_all_time: int = 0

func _ready() -> void:
	load_data()

func load_data() -> void:
	if FileAccess.file_exists(SAVE_FILE_PATH):
		var file = FileAccess.open(SAVE_FILE_PATH, FileAccess.READ)
		var data = file.get_var()
		if data is Dictionary:
			high_score = data.get("high_score", 0)
			max_chain_all_time = data.get("max_chain", 0)

func save_data() -> void:
	var file = FileAccess.open(SAVE_FILE_PATH, FileAccess.WRITE)
	var data = {
		"high_score": high_score,
		"max_chain": max_chain_all_time
	}
	file.store_var(data)

func update_score(current_score: int, current_max_chain: int) -> void:
	var updated = false
	if current_score > high_score:
		high_score = current_score
		updated = true
	if current_max_chain > max_chain_all_time:
		max_chain_all_time = current_max_chain
		updated = true
		
	if updated:
		save_data()
