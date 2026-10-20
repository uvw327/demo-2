@tool
extends EditorPlugin

const SDK_AUTOLOAD := "MiniGameSDK"
const SDK_PATH := "res://addons/godot_mini_game/MiniGameSDK.gd"
const SDK_AUTOLOAD_SETTING := "autoload/" + SDK_AUTOLOAD

var dock: Control

func _enter_tree() -> void:
	dock = preload("res://addons/godot_mini_game/export_dock.tscn").instantiate()
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, dock)

	if not ProjectSettings.has_setting(SDK_AUTOLOAD_SETTING):
		add_autoload_singleton(SDK_AUTOLOAD, SDK_PATH)
	elif _current_autoload_path() != SDK_PATH:
		push_error(
			"Godot Mini Game cannot register %s because the name is already used by %s" % [
				SDK_AUTOLOAD,
				_current_autoload_path(),
			]
		)


func _exit_tree() -> void:
	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()
		dock = null
	# Ownership is derived from the path, not transient editor-session state. This
	# keeps disable/uninstall behavior correct after the editor has been restarted
	# while still preserving a user autoload that merely shares the same name.
	if _current_autoload_path() == SDK_PATH:
		remove_autoload_singleton(SDK_AUTOLOAD)


func _current_autoload_path() -> String:
	if not ProjectSettings.has_setting(SDK_AUTOLOAD_SETTING):
		return ""
	var raw := str(ProjectSettings.get_setting(SDK_AUTOLOAD_SETTING, "")).trim_prefix("*")
	# project.godot 里的脚本路径可能被写成 uid:// 形式（编辑器会做这种改写，指向的
	# 其实就是同一个 MiniGameSDK.gd）。这里先把它解析回真实路径再比较，
	# 否则“同一脚本、两种写法”会被下面的重名检查误判成冲突，每次启动编辑器都报错。
	if raw.begins_with("uid://"):
		var id := ResourceUID.text_to_id(raw)
		if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id):
			return ResourceUID.get_id_path(id)
		# uid 缓存尚未就绪时兜底：直接加载解析出 resource_path
		var res := load(raw)
		if res != null and not res.resource_path.is_empty():
			return res.resource_path
	return raw
