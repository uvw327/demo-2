extends CanvasLayer
# “创建世界”菜单（参考 RimWorld 世界生成菜单的样式）。
# 职责：只负责界面与参数收集，不碰 3D；
# 点击“生成世界”后通过信号把参数交给 planet.gd，并切换到进度条模式。

signal generate_requested(params: Dictionary)

# ---- 配色（取自参考图）----
const BG := Color("3b3b3b")        # 整屏底色
const FIELD_BG := Color("2d2d2d")  # 输入框/下拉框背景
const BTN_BG := Color("404040")    # 按钮常驻
const BTN_HOVER := Color("4a4a4a")
const BTN_PRESSED := Color("2a2a2a")
const TEXT := Color(0.94, 0.94, 0.94)

var _seed_box: SpinBox
var _coverage: OptionButton
var _rainfall: OptionButton
var _temperature: OptionButton
var _form_box: VBoxContainer   # 表单容器：生成时整体隐藏
var _progress: ProgressBar     # 进度条：只在生成时显示


func _ready() -> void:
	layer = 10
	_build_ui()


func show_progress() -> void:
	# 进入“生成中”状态：隐藏表单，显示进度条
	_form_box.visible = false
	_progress.visible = true
	_progress.value = 0.0


func set_progress(percent: float) -> void:
	_progress.value = percent


func hide_menu() -> void:
	visible = false


func _build_ui() -> void:
	# 整屏根控件：吃掉所有鼠标事件（生成前不该能拖视角）
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	# 整屏深灰底（对应参考图的背景色）
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	# 居中容器
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(560, 0)
	panel.add_theme_constant_override("separation", 10)
	center.add_child(panel)

	# 标题
	var title := Label.new()
	title.text = "创建世界"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", TEXT)
	panel.add_child(title)

	# 表单（生成时整体隐藏）
	_form_box = VBoxContainer.new()
	_form_box.add_theme_constant_override("separation", 8)
	panel.add_child(_form_box)

	# 两列表单：左标签右控件
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 10)
	_form_box.add_child(grid)

	# 种子：SpinBox（自带上下小箭头）+ “随机”按钮
	var seed_label := _make_label("种子")
	grid.add_child(seed_label)
	var seed_row := HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 8)
	grid.add_child(seed_row)
	_seed_box = SpinBox.new()
	_seed_box.min_value = 0
	_seed_box.max_value = 99999
	_seed_box.step = 1
	_seed_box.value = 4242
	_seed_box.custom_minimum_size = Vector2(340, 36)
	_seed_box.add_theme_font_size_override("font_size", 16)
	_seed_box.get_line_edit().add_theme_stylebox_override("normal", _flat_style(FIELD_BG))
	_seed_box.get_line_edit().add_theme_color_override("font_color", TEXT)
	seed_row.add_child(_seed_box)
	var random_btn := _make_button("随机", Vector2(90, 36), 16)
	random_btn.pressed.connect(func(): _seed_box.value = randi() % 100000)
	seed_row.add_child(random_btn)

	# 三个下拉框：选项的 metadata 存真实数值
	var coverage_opt := _make_option([["30%", 0.3], ["50%", 0.5], ["100%", 1.0]], 0)
	var rainfall_opt := _make_option([["高", 1], ["普通", 0], ["低", -1]], 1)
	var temperature_opt := _make_option([["高", 1], ["普通", 0], ["低", -1]], 1)
	_add_field_row(grid, "全球覆盖率", coverage_opt)
	_add_field_row(grid, "总体降雨", rainfall_opt)
	_add_field_row(grid, "总体温度", temperature_opt)
	_coverage = coverage_opt
	_rainfall = rainfall_opt
	_temperature = temperature_opt

	# 生成世界按钮
	var gen_btn := _make_button("生成世界", Vector2(560, 44), 20)
	gen_btn.pressed.connect(_on_generate_pressed)
	_form_box.add_child(gen_btn)

	# 进度条（初始隐藏）
	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(560, 34)
	_progress.min_value = 0.0
	_progress.max_value = 100.0
	_progress.show_percentage = true
	_progress.visible = false
	_progress.add_theme_stylebox_override("background", _flat_style(FIELD_BG))
	_progress.add_theme_stylebox_override("fill", _flat_style(Color("5b7aa6")))
	_progress.add_theme_font_size_override("font_size", 14)
	panel.add_child(_progress)


func _on_generate_pressed() -> void:
	# 收集参数：种子 + 覆盖率(0..1) + 降雨/温度偏移档位(-1,0,1)
	generate_requested.emit({
		"seed": int(_seed_box.value),
		"coverage": _coverage.get_item_metadata(_coverage.selected),
		"rainfall": _rainfall.get_item_metadata(_rainfall.selected),
		"temperature": _temperature.get_item_metadata(_temperature.selected),
	})
	show_progress()


# ---- 下面是小的构建辅助 ----

func _make_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", TEXT)
	return l


func _make_button(text: String, min_size: Vector2, font_size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_stylebox_override("normal", _flat_style(BTN_BG))
	b.add_theme_stylebox_override("hover", _flat_style(BTN_HOVER))
	b.add_theme_stylebox_override("pressed", _flat_style(BTN_PRESSED))
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return b


func _make_option(items: Array, default_index: int) -> OptionButton:
	# items: [ ["显示文本", metadata 值], ... ]
	var opt := OptionButton.new()
	for item in items:
		opt.add_item(item[0])
		opt.set_item_metadata(opt.item_count - 1, item[1])
	opt.select(default_index)
	opt.custom_minimum_size = Vector2(440, 36)
	opt.add_theme_font_size_override("font_size", 16)
	opt.add_theme_color_override("font_color", TEXT)
	for state in ["normal", "hover", "pressed"]:
		var style := _flat_style(FIELD_BG if state == "normal" else (BTN_HOVER if state == "hover" else BTN_PRESSED))
		opt.add_theme_stylebox_override(state, style)
	opt.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return opt


func _add_field_row(grid: GridContainer, label_text: String, control: Control) -> void:
	grid.add_child(_make_label(label_text))
	grid.add_child(control)


# 圆角矩形风格（4px 圆角，统一所有深灰控件观感）
func _flat_style(color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(4)
	return sb
