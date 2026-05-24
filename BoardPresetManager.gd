extends CanvasLayer
class_name BoardPresetManager

@export var main_path: NodePath = NodePath("..")
@export var button_container_path: NodePath = NodePath("PanelContainer/MarginContainer/VBoxContainer")
@export var presets: Dictionary = {
	"Bottom Filled": [
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"##########",
	],
	"Single Hole": [
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"#####.####",
		"##########",
	],
	"Tスピン形状": [
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"...####...",
		"...####...",
		"...##.....",
		"....#.....",
		"..######..",
		".########.",
	],
	"4ライン直前": [
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"#########.",
		"#########.",
		"#########.",
		"#########.",
	],
	"穴掘り用": [
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		".#########",
		".#########",
		".#########",
		".#########",
		".#########",
		".#########",
		".#########",
		".#########",
		".#########",
		".#########",
	],
	"バラバラ穴あき": [
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"..........",
		"#.#.#####.",
		".##.#.###.",
		"##.#.##.#.",
		".#.##.#.##",
		"#.#.##.#.#",
		".##.#.##.#",
		"##.#.##.#.",
		".#.####.#.",
		"#.#.#####.",
	],
}

var _button_container: VBoxContainer


func _ready() -> void:
	_button_container = get_node_or_null(button_container_path) as VBoxContainer

	if _button_container == null:
		push_warning("BoardPresetManager: button container not found.")
		return

	_rebuild_buttons()


func _rebuild_buttons() -> void:
	for child in _button_container.get_children():
		child.queue_free()

	var preset_names: Array[String] = []
	for key in presets.keys():
		preset_names.append(str(key))
	preset_names.sort()

	if preset_names.is_empty():
		var label := Label.new()
		label.text = "No presets"
		_button_container.add_child(label)
		return

	for preset_name in preset_names:
		var button := Button.new()
		button.text = preset_name
		button.pressed.connect(_on_preset_button_pressed.bind(preset_name))
		_button_container.add_child(button)


func _on_preset_button_pressed(preset_name: String) -> void:
	var main_node = get_node_or_null(main_path)
	if main_node == null or not main_node.has_method("load_preset_board"):
		push_warning("BoardPresetManager: Main node or load_preset_board method not found.")
		return

	if not presets.has(preset_name):
		push_warning("BoardPresetManager: preset '%s' is missing." % preset_name)
		return

	var raw_rows: Variant = presets[preset_name]
	var matrix: Array = _parse_rows_to_matrix(raw_rows)
	main_node.load_preset_board(matrix)



func _parse_rows_to_matrix(raw_rows: Variant) -> Array:
	var matrix: Array = []
	if not (raw_rows is Array):
		return matrix

	var rows: Array = raw_rows as Array
	for row_data in rows:
		var row_string := str(row_data)
		var parsed_row: Array = []
		for i in range(row_string.length()):
			parsed_row.append(row_string.substr(i, 1) == "#")
		matrix.append(parsed_row)
	return matrix
