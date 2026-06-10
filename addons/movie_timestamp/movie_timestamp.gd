@tool
extends EditorPlugin

# 保存先フォルダ（無ければ自動作成）
const OUTPUT_DIR := "D:/Godot/Movie"
# 拡張子（.avi=AVIWriter, .png=PNGWriter）
const EXTENSION := ".avi"


# プロジェクト実行（▶ / ムービーメーカー）の直前に必ず呼ばれる。
# ここで movie_file を「現在日時」のファイル名へ書き換える。
func _build() -> bool:
	var t := Time.get_datetime_dict_from_system()
	# 例: 2026-06-10　15：25 （全角コロン・全角スペース。半角 : はWindowsで使用不可）
	var file_name := "%04d-%02d-%02d　%02d：%02d" % [t.year, t.month, t.day, t.hour, t.minute]
	var path := "%s/%s%s" % [OUTPUT_DIR, file_name, EXTENSION]

	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	ProjectSettings.set_setting("editor/movie_writer/movie_file", path)

	# true を返すと実行が継続される
	return true
