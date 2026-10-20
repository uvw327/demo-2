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
	return _resolve_autoload_path(
		str(ProjectSettings.get_setting(SDK_AUTOLOAD_SETTING, ""))
	)


## 把 autoload 设置值解析成真实资源路径。
##
## autoload 值以 `*` 开头表示已启用，后面可能是 `res://...`，也可能是 Godot 4.7
## 写出的 `uid://...`。两者指向同一个脚本时必须归一到同一路径再比较，否则插件会
## 把自己的 autoload 误判成“名字被占用”。
static func _resolve_autoload_path(setting_value: String) -> String:
	var value := setting_value.strip_edges().trim_prefix("*").strip_edges()
	if value.is_empty():
		return ""

	if value.begins_with("uid://"):
		var uid := ResourceUID.text_to_id(value)
		if uid != ResourceUID.INVALID_ID and ResourceUID.has_id(uid):
			var cached_path := ResourceUID.get_id_path(uid)
			if not cached_path.is_empty():
				return cached_path
		# 编辑器 uid 缓存可能尚未就绪（首次导入、命令行启动等），此时用 load()
		# 兜底取 resource_path；仍然失败就退回原始字符串，避免误杀合法配置。
		if ResourceLoader.exists(value):
			var resource := ResourceLoader.load(value)
			if resource != null and not resource.resource_path.is_empty():
				return resource.resource_path

	return value
