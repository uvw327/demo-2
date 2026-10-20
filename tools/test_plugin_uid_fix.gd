# 复现 godot_mini_game 插件的重名误判修复：读取 project.godot 里的真实
# MiniGameSDK autoload 值，按补丁后的 _current_autoload_path() 同样逻辑解析，
# 断言解析结果与插件期望的 SDK_PATH 一致（即启动时不再 push_error）。
# 用法：godot --headless --path . --script res://tools/test_plugin_uid_fix.gd
extends SceneTree

const SDK_PATH := "res://addons/godot_mini_game/MiniGameSDK.gd"
const SETTING := "autoload/MiniGameSDK"


func _initialize() -> void:
	var fail := false
	if not ProjectSettings.has_setting(SETTING):
		print("FAIL: project.godot 缺少 MiniGameSDK autoload")
		fail = true
	var raw := str(ProjectSettings.get_setting(SETTING, "")).trim_prefix("*")
	print("autoload 原始值: ", raw)
	var resolved := raw
	if raw.begins_with("uid://"):
		var id := ResourceUID.text_to_id(raw)
		if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id):
			resolved = ResourceUID.get_id_path(id)
			print("uid 缓存解析路径: ", resolved)
		else:
			print("uid 缓存未命中，走 load 兜底")
			var res := load(raw)
			if res != null and not res.resource_path.is_empty():
				resolved = res.resource_path
				print("load 兜底解析路径: ", resolved)
	if resolved == SDK_PATH:
		print("PASS: 同一脚本两种写法已被识别，插件不会再报重名错误")
	else:
		# 只有真的被别的脚本占用时才应该走到这里
		print("仍不相等：resolved=", resolved, " SDK_PATH=", SDK_PATH)
		fail = true
	quit(1 if fail else 0)
