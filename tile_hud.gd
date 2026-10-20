class_name TileHud
extends CanvasLayer
# 贴片信息 HUD：左下角的黑色半透明圆角信息面板。
# 平常隐藏；planet.gd 在选中贴片时调 show_tile() 展示、取消选中时调 hide_panel()。
# 纯代码构建（与 world_menu 同风格），字体走 font_baker 烘焙的字形子集。
# 本文件不写任何中文文案——显示内容由 planet.gd 组装传入，字形清单
# 由 extract_chinese.py 扫描源码字符串统一收集，别在这里内联中文。

const UI_FONT := preload("res://assets/font/glyphs.tres") # 与菜单同一套烘焙字形

const BG_ALPHA := 0.55    # 面板底色透明度（黑）
const RADIUS := 12        # 圆角半径（px）
const TITLE_SIZE := 30    # 标题行字号
const ROW_SIZE := 26      # 信息行字号
const MARGIN_PX := 16     # 面板距屏幕左下角的边距

var _panel: PanelContainer
var _title: Label
var _rows: VBoxContainer


func _ready() -> void:
	layer = 10  # 高于菜单层，低于系统弹窗
	visible = false

	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, BG_ALPHA)
	style.set_corner_radius_all(RADIUS)
	style.set_content_margin_all(14)
	style.content_margin_left = 18
	style.content_margin_right = 18
	_panel.add_theme_stylebox_override("panel", style)

	# 与菜单同一套主题：烘焙字形做 default_font（中文离线渲染的前提）
	var theme := Theme.new()
	theme.default_font = UI_FONT
	theme.default_font_size = ROW_SIZE
	_panel.theme = theme

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	_panel.add_child(vbox)

	_title = _make_label(TITLE_SIZE, Color(1.0, 1.0, 1.0))
	vbox.add_child(_title)

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 2)
	vbox.add_child(_rows)

	add_child(_panel)
	# 锚定屏幕左下角：按内容最小尺寸停靠，留 MARGIN_PX 边距，
	# 面板高度变化时向上/向右生长（grow_* 决定溢出方向）。
	_panel.set_anchors_and_offsets_preset(
			Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, MARGIN_PX)
	_panel.grow_horizontal = Control.GROW_DIRECTION_END
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN


func _make_label(font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l


# 展示一块贴片的信息：title 为标题行（贴片编号），rows 为逐行信息文本。
func show_tile(title: String, rows: PackedStringArray) -> void:
	if not is_inside_tree():
		return
	_title.text = title
	for c in _rows.get_children():
		c.queue_free()
	for line in rows:
		var l := _make_label(ROW_SIZE, Color(0.95, 0.95, 0.95))
		l.text = line
		_rows.add_child(l)
	visible = true


# 隐藏 HUD（取消选中 / 无选中时）。
func hide_panel() -> void:
	visible = false
