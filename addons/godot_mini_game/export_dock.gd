@tool
extends VBoxContainer

const Exporter = preload("res://addons/godot_mini_game/exporter.gd")
const Persistence = preload("res://addons/godot_mini_game/core/persistence.gd")

const PLATFORM_OPTIONS := [
	["微信小游戏", "wechat"],
	["抖音小游戏", "douyin"],
	["TikTok Mini Game", "tiktok"],
]
const PLATFORM_DISPLAY_NAMES := {
	"wechat": "微信小游戏",
	"douyin": "抖音小游戏",
	"tiktok": "TikTok Mini Game",
}
const ORIENTATION_OPTIONS := [
	["竖屏 (portrait)", "portrait"],
	["横屏 (landscape)", "landscape"],
]
## 日志区域右键菜单的条目 id。
const LOG_MENU_COPY_ALL := 0
const LOG_MENU_CLEAR := 1

@onready var platform_option: OptionButton = $PlatformOption
@onready var appid_input: LineEdit = $AppIdInput
@onready var orientation_option: OptionButton = $OrientationOption
@onready var preset_option: OptionButton = $PresetOption
@onready var output_path: LineEdit = $OutputRow/OutputPath
@onready var browse_btn: Button = $OutputRow/BrowseBtn
@onready var export_btn: Button = $ExportBtn
@onready var cancel_export_btn: Button = $CancelExportBtn
@onready var timeout_input: SpinBox = $TimeoutRow/TimeoutInput
@onready var status_label: RichTextLabel = $StatusLabel
@onready var folder_dialog: FileDialog = $FolderDialog
@onready var template_status: RichTextLabel = $TemplateStatus
@onready var import_btn: Button = $TemplateRow/ImportBtn
@onready var refresh_btn: Button = $TemplateRow/RefreshBtn
@onready var template_file_dialog: FileDialog = $TemplateFileDialog

var _active_exporter: RefCounted
## 日志区域的右键菜单（全部复制 / 清空），在 _ready 中创建。
var _log_menu: PopupMenu


func _ready() -> void:
	Persistence.ensure_project_files()
	platform_option.clear()
	for option in PLATFORM_OPTIONS:
		platform_option.add_item(str(option[0]))
		platform_option.set_item_metadata(platform_option.item_count - 1, option[1])

	orientation_option.clear()
	for option in ORIENTATION_OPTIONS:
		orientation_option.add_item(str(option[0]))
		orientation_option.set_item_metadata(orientation_option.item_count - 1, option[1])

	_refresh_presets()
	_refresh_template_status()
	_restore_persisted_state()

	browse_btn.pressed.connect(_on_browse)
	export_btn.pressed.connect(_on_export)
	cancel_export_btn.pressed.connect(_on_cancel_export)
	folder_dialog.dir_selected.connect(_on_dir_selected)
	import_btn.pressed.connect(_on_import_template)
	# The "Refresh" button refreshes BOTH the template status and the export
	# preset list, because users frequently create their Web preset *after*
	# enabling the plugin and would otherwise be stuck staring at "(未找到导出预设)"
	# until they restarted the editor.
	refresh_btn.pressed.connect(_refresh_all)
	template_file_dialog.file_selected.connect(_on_template_file_selected)
	_setup_log_context_menu()

	_log("[b]小游戏导出插件已就绪[/b]")
	if not Persistence.load_error.is_empty():
		_log("[color=yellow]⚠ 无法读取持久化配置，使用默认值: %s[/color]" % Persistence.load_error)


## Reads `.minigame/export.cfg` and restores the dock controls from it.
## Missing or invalid fields fall back to the tscn defaults. The preset
## name is validated against the live preset list; the output directory is
## re-validated with `OutputGuard` so a stale or unsafe path never leaks
## into an export.
func _restore_persisted_state() -> void:
	var project_root := ProjectSettings.globalize_path("res://")
	var state: Dictionary = Persistence.load_project_state()
	if state.get(Persistence.KEY_PLATFORM) != "":
		_select_option(platform_option, str(state.get(Persistence.KEY_PLATFORM, "")))
	appid_input.text = str(state.get(Persistence.KEY_APPID, ""))
	if state.get(Persistence.KEY_ORIENTATION) != "":
		_select_option(orientation_option, str(state.get(Persistence.KEY_ORIENTATION, "")))
	timeout_input.value = float(state.get(Persistence.KEY_TIMEOUT, 600.0))
	var persisted_output_dir: String = str(state.get(Persistence.KEY_OUTPUT_DIR, ""))
	if not persisted_output_dir.is_empty():
		var absolute_output_dir: String = Exporter.validate_persisted_output_dir(
			persisted_output_dir, project_root)
		if not absolute_output_dir.is_empty():
			output_path.text = absolute_output_dir
		else:
			_log("[color=yellow]⚠ 持久化的输出目录已失效，请重新选择[/color]")
	# The preset restore happens after _refresh_presets has populated the
	# option list, so it can select by name. An empty selection means the
	# persisted preset no longer exists.
	var persisted_preset: String = str(state.get(Persistence.KEY_PRESET, ""))
	if not persisted_preset.is_empty():
		_select_option(preset_option, persisted_preset)


func _select_option(option: OptionButton, value: String) -> void:
	for index in range(option.item_count):
		if str(option.get_item_metadata(index)) == value:
			option.select(index)
			return


func _refresh_all() -> void:
	_refresh_presets()
	_refresh_template_status()
	_log("已刷新预设和模板状态")


func _refresh_presets() -> void:
	var previous := ""
	if preset_option.item_count > 0 and preset_option.selected >= 0:
		previous = str(preset_option.get_item_metadata(preset_option.selected))
	preset_option.clear()
	var cfg := ConfigFile.new()
	var err := cfg.load("res://export_presets.cfg")
	if err != OK:
		_set_no_preset("(未找到 export_presets.cfg)")
		return
	var selected_index := -1
	for section in cfg.get_sections():
		if section.begins_with("preset."):
			var preset_name: String = cfg.get_value(section, "name", "")
			var preset_platform: String = cfg.get_value(section, "platform", "")
			if preset_name.is_empty() or preset_platform != "Web":
				continue
			preset_option.add_item(preset_name)
			var index := preset_option.item_count - 1
			preset_option.set_item_metadata(index, preset_name)
			if preset_name == previous:
				selected_index = index
	if preset_option.item_count == 0:
		_set_no_preset("(未找到 Web 导出预设)")
		return
	preset_option.disabled = false
	preset_option.select(selected_index if selected_index >= 0 else 0)


func _set_no_preset(label: String) -> void:
	preset_option.add_item(label)
	preset_option.set_item_metadata(0, "")
	preset_option.disabled = true


func _refresh_template_status() -> void:
	if not template_status:
		return
	var ver_key := Exporter.get_godot_version_key()
	var status := Exporter.get_template_status()
	var template_version: String = status.get("template_version", "")
	var template_commit: String = status.get("template_commit", "")
	var emscripten_version: String = status.get("emscripten_version", "")
	var bridge_abi: int = status.get("bridge_abi", 0)
	var template_revision: int = status.get("template_revision", 0)
	var version_note := ""
	if not template_version.is_empty():
		version_note = "模板 %s / 编辑器 %s" % [template_version, ver_key]
		if not template_commit.is_empty():
			version_note += " / commit %s" % template_commit.substr(0, 10)
		if not emscripten_version.is_empty():
			version_note += " / emsdk %s" % emscripten_version
		if bridge_abi > 0:
			version_note += " / ABI %d" % bridge_abi
		if template_revision > 0:
			version_note += " / r%d" % template_revision
	else:
		version_note = "编辑器 %s" % ver_key
	template_status.clear()
	match status.source:
		"addon":
			template_status.append_text("[color=green]✓ 兼容模板就绪[/color] (自定义, %s)" % version_note)
		"bundled":
			template_status.append_text("[color=green]✓ 兼容模板就绪[/color] (内置, %s)" % version_note)
		"store":
			template_status.append_text("[color=green]✓ 兼容模板就绪[/color] (模板库, %s)" % version_note)
		"store_legacy":
			template_status.append_text("[color=green]✓ 兼容模板就绪[/color] (旧模板库, %s)" % version_note)
		_:
			template_status.append_text("[color=red]✗ 未找到精确匹配的引擎模板[/color] (Godot %s)" % ver_key)


func _on_import_template() -> void:
	template_file_dialog.popup_centered()


func _on_template_file_selected(path: String) -> void:
	_log("[color=cyan]正在导入引擎模板: %s[/color]" % path.get_file())
	var exporter := Exporter.new()
	exporter.log_callback = _log
	var err := exporter.import_template_zip(path)
	if err == OK:
		_log("[color=green][b]模板导入成功！[/b][/color]")
		_show_toast("导入成功", "已按 template.json 中的精确 Godot 版本归档。")
	else:
		_log("[color=red]模板导入失败[/color]")
	_refresh_template_status()


func _on_browse() -> void:
	folder_dialog.popup_centered()


func _on_dir_selected(dir: String) -> void:
	output_path.text = dir


func _on_export() -> void:
	# Re-read export_presets.cfg every time the user clicks Export so we never
	# act on a stale snapshot taken when the dock was first instantiated.
	# This is the cheapest way to avoid the "(未找到导出预设)" sticky-state bug
	# where the user creates the preset *after* enabling the plugin.
	_refresh_presets()

	var platform: String = str(platform_option.get_item_metadata(platform_option.selected))
	var appid: String = appid_input.text.strip_edges()
	var orientation: String = str(orientation_option.get_item_metadata(orientation_option.selected))
	var output_dir: String = output_path.text.strip_edges()
	var preset_name: String = ""
	if preset_option.selected >= 0:
		preset_name = str(preset_option.get_item_metadata(preset_option.selected))

	if output_dir.is_empty():
		_log("[color=red]请选择输出目录[/color]")
		return
	if preset_name.is_empty():
		_log("[color=red]请先在 Project → Export 中创建一个 Web 导出预设；如已创建请点击「刷新」按钮[/color]")
		return
	if platform == "tiktok" and appid.is_empty():
		_log("[color=red]请填写 TikTok Client Key[/color]")
		appid_input.grab_focus()
		return

	_set_export_busy(true)
	_log("[color=cyan]开始导出 %s ...[/color]" % str(
		PLATFORM_DISPLAY_NAMES.get(platform, platform)))

	var exporter := Exporter.new()
	_active_exporter = exporter
	exporter.log_callback = _log
	exporter.pack_timeout_seconds = timeout_input.value

	var err := await exporter.export_mini_game(
		platform,
		appid,
		orientation,
		preset_name,
		output_dir,
	)

	if err == OK:
		_log("[color=green][b]导出成功！[/b] → %s[/color]" % output_dir)
		_show_toast("导出成功！", "小游戏已导出到:\n%s" % output_dir)
		_persist_current_state()
	elif err == ERR_SKIP:
		_log("[color=yellow]导出已取消[/color]")
	elif err == ERR_TIMEOUT:
		_log("[color=red]资源导出超时；可调整超时秒数后重试[/color]")
	else:
		_log("[color=red][b]导出失败[/b][/color]")

	_active_exporter = null
	_set_export_busy(false)


func _on_cancel_export() -> void:
	if _active_exporter:
		_active_exporter.cancel_export()
		cancel_export_btn.disabled = true
		_log("正在取消导出，请等待子进程退出 ...")


func _set_export_busy(busy: bool) -> void:
	export_btn.disabled = busy
	import_btn.disabled = busy
	refresh_btn.disabled = busy
	cancel_export_btn.visible = busy
	cancel_export_btn.disabled = not busy
	timeout_input.editable = not busy


func _exit_tree() -> void:
	if _active_exporter:
		_active_exporter.cancel_export()
	# Save the current UI values so the next editor session restores them.
	# This is best-effort: if the write fails, the user loses nothing because
	# a successful export already saved the state.
	_persist_current_state()


## Snapshots the current dock values and writes them to
## `.minigame/export.cfg`. The output directory is stored as a
## project-relative path so the file stays portable across machines; the
## other fields are plain strings.
func _persist_current_state() -> void:
	var project_root := ProjectSettings.globalize_path("res://")
	var state: Dictionary = {
		Persistence.KEY_PLATFORM: str(platform_option.get_item_metadata(platform_option.selected)),
		Persistence.KEY_APPID: appid_input.text.strip_edges(),
		Persistence.KEY_ORIENTATION: str(orientation_option.get_item_metadata(orientation_option.selected)),
		Persistence.KEY_PRESET: str(preset_option.get_item_metadata(preset_option.selected)),
		Persistence.KEY_OUTPUT_DIR: Persistence.relativize_output_dir(
			output_path.text.strip_edges(), project_root),
		Persistence.KEY_TIMEOUT: timeout_input.value,
	}
	var err: Error = Persistence.save_project_state(state)
	if err != OK:
		_log("[color=yellow]⚠ 无法保存导出配置: %s[/color]" % error_string(err))


## Pops a one-shot modal dialog. The dialog is parented to the editor's base
## control instead of the dock itself, so it centers over the whole editor
## window and survives even if the dock is hidden / moved mid-export.
func _show_toast(title: String, message: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = title
	dialog.dialog_text = message
	dialog.min_size = Vector2i(320, 0)
	var parent: Node = EditorInterface.get_base_control() if Engine.is_editor_hint() else self
	parent.add_child(dialog)
	dialog.popup_centered()
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)


func _log(msg: String) -> void:
	if status_label:
		status_label.append_text(msg + "\n")


## 为日志区域挂一个右键上下文菜单。RichTextLabel 没有内置的右键菜单，
## 这里手动创建一个 PopupMenu：「全部复制」把日志当前显示的纯文本写入系统
## 剪贴板，「清空」删除已累积的旧日志。
func _setup_log_context_menu() -> void:
	_log_menu = PopupMenu.new()
	_log_menu.add_item("全部复制", LOG_MENU_COPY_ALL)
	_log_menu.add_item("清空", LOG_MENU_CLEAR)
	_log_menu.id_pressed.connect(_on_log_menu_id_pressed)
	add_child(_log_menu)
	status_label.gui_input.connect(_on_status_label_gui_input)


func _on_status_label_gui_input(event: InputEvent) -> void:
	if (
		event is InputEventMouseButton
		and event.pressed
		and event.button_index == MOUSE_BUTTON_RIGHT
	):
		_log_menu.position = Vector2i(event.global_position)
		_log_menu.popup()
		# 右键已由菜单消费，避免日志区继续处理这次点击。
		status_label.accept_event()


func _on_log_menu_id_pressed(id: int) -> void:
	match id:
		LOG_MENU_COPY_ALL:
			# 复制用户实际看到的文本：get_parsed_text 会剥离 BBCode 颜色等标签。
			DisplayServer.clipboard_set(status_label.get_parsed_text())
		LOG_MENU_CLEAR:
			status_label.clear()
