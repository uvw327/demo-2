class_name OrbitCamera
extends Node3D
# 通用轨道相机控制器：拖动 = 环绕旋转，滚轮/双指捏合 = 拉近推远（带限位）。
# 桌面：左键拖拽旋转（中键保留同款手感），滚轮缩放。
# 移动端/触屏：单指拖拽旋转，双指捏合缩放；短按不动 = 点按，经 view_tapped 上报
# （由 planet 端做贴片拾取，相机只负责区分“点”与“拖”）。
# 用法：OrbitCamera.new() 后 add_child 即可；相机始终看向 target。
# 说明：实际是“相机绕行星转”（yaw/pitch 变化、行星模型不动）——
# 从画面上看与“拖着星球转”完全等价，且表面图案（顶点色/shader）天然稳定不漂移。
# 触屏设备上上面板双投递去重：touchscreen 可用时忽略模拟出来的鼠标事件，
# 只处理真实触摸事件，避免一次手指动作被记成两次输入。

# 一次“点按而非拖拽”的有效点击（屏幕坐标），拾取方据此做贴片选择
signal view_tapped(screen_position: Vector2)

const MIN_DIST := 1.15  # 最近限制：贴近到离地约 1/7 半径，能看清贴片细节但不穿模
const MAX_DIST := 10.0 # 最远限制：再远就看不清了
const DRAG_SENS := 0.005        # 拖动灵敏度：弧度/像素（此前 0.01 偏灵敏，轻拖就晃过头）
const WHEEL_ZOOM := 0.1        # 单格滚轮的缩放幅度（factor = 1±WHEEL_ZOOM）
const CLICK_MAX_DRAG_PX := 10.0 # 按下→抬起累计位移小于它才算“点”
const CLICK_MAX_TIME := 0.45    # 点按最长按住时长（秒）
const ROTATE_START_PX := 26.0   # 旋转死区：累计位移超过它才开始旋转（跟手前有一段“空行程”）
const PINCH_MIN_DIST := 8.0     # 两指距离小于该像素数不参与捏合（防抖）

var target := Vector3.ZERO # 环绕中心
var dist := 2.05           # 相机到中心的距离（生成完星球刚好贴近看大陆）
var yaw := 0.0             # 水平环绕角（弧度）
var pitch := 0.0           # 俯仰角（弧度，0 = 平视）
var dragging := false      # 中键（桌面备用）是否按住

var cam: Camera3D

var _rotate_active := false    # 左键/单指拖拽旋转进行中（与中键的 dragging 互不影响）
var _tap_candidate := false    # 本次按下到目前为止仍可能是一次“点按”
var _press_pos := Vector2.ZERO # 按下时的屏幕坐标
var _press_ms := 0             # 按下时刻（毫秒）
var _move_accum := 0.0         # 本次按下的累计位移（像素）
var _touch_points := {}        # 触点序号 → 当前屏幕坐标（双指捏合用）
var _pinch_dist := 0.0         # 上一次捏合的两指间距


func _ready() -> void:
	cam = Camera3D.new()
	add_child(cam)
	_update_cam()


func _unhandled_input(event: InputEvent) -> void:
	# 鼠标与触摸双路并存，只用 device 判别"模拟事件"：
	#   · 触屏上 emulate_mouse_from_touch 会把触摸再模拟成鼠标事件（device == -1），
	#     与真实触摸重复 → 丢弃，避免"一次手势两份输入"；
	#   · 真实设备（device >= 0）的鼠标/触摸都正常处理——
	#     这样触屏设备（含微信开发者工具的 H5 环境）用鼠标也能拖拽与点选。
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		if event.device == InputEvent.DEVICE_ID_EMULATION:
			return
		_input_mouse(event)
	elif event is InputEventScreenTouch or event is InputEventScreenDrag:
		_input_touch(event)


func _input_mouse(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			# 左键：按下开始“可能的一次点/拖”，抬起时结算tap
			if event.pressed:
				_press_begin(event.position)
			else:
				_press_end(event.position)
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			dragging = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(1.0 - WHEEL_ZOOM)   # 滚轮上：拉近
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(1.0 + WHEEL_ZOOM)   # 滚轮下：推远
	elif event is InputEventMouseMotion:
		if _rotate_active:
			_rotate(event.relative)
		elif dragging:
			# 中键拖拽：想象“抓住行星表面拖动”，与左键同款旋转
			_orbit_rotate(event.relative)


func _input_touch(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_points[event.index] = event.position
			if _touch_points.size() == 1:
				_press_begin(event.position)  # 第一根手指
			elif _touch_points.size() == 2:
				# 第二根手指落下 → 切换到捏合缩放，旋转/点按语义作废
				_rotate_active = false
				_tap_candidate = false
				_pinch_dist = _current_pinch_distance()
		else:
			var was_single := _touch_points.size() == 1 and _touch_points.has(event.index)
			_touch_points.erase(event.index)
			_pinch_dist = 0.0
			if was_single:
				_press_end(event.position)    # 单指抬起 → 正常结算点/拖
			else:
				# 双指状态下的抬起/多指混按退出：不作点按（需要重新按下才开始新交互）
				_rotate_active = false
				_tap_candidate = false
	elif event is InputEventScreenDrag:
		if not _touch_points.has(event.index):
			return
		var prev: Vector2 = _touch_points[event.index]
		_touch_points[event.index] = event.position
		if _touch_points.size() == 1 and _rotate_active:
			var rel: Vector2 = event.position - prev
			_rotate(rel)
		elif _touch_points.size() >= 2:
			# 双指捏合：间距比值直接当缩放倍率（任意距离下手感一致）
			var nd := _current_pinch_distance()
			if _pinch_dist > PINCH_MIN_DIST and nd > PINCH_MIN_DIST:
				_zoom(_pinch_dist / nd)
				_tap_candidate = false
			_pinch_dist = nd


# —— 按下/抬起的公共结算：区分“点按”与“拖拽” ——

func _press_begin(pos: Vector2) -> void:
	_rotate_active = true
	_tap_candidate = true
	_press_pos = pos
	_press_ms = Time.get_ticks_msec()
	_move_accum = 0.0


func _press_end(pos: Vector2) -> void:
	_rotate_active = false
	if _tap_candidate and Time.get_ticks_msec() - _press_ms <= CLICK_MAX_TIME * 1000.0:
		view_tapped.emit(pos)   # 位移没超阈值、时间也短 → 一次有效点按
	_tap_candidate = false


func _track_move(delta: Vector2) -> float:
	# 累计拖拽位移：超过点按阈值后取消点按资格；返回当前累计位移给死区判定用
	_move_accum += delta.length()
	if _tap_candidate and _move_accum > CLICK_MAX_DRAG_PX:
		_tap_candidate = false
	return _move_accum


# —— 相机运动 ——

func _orbit_rotate(delta_px: Vector2) -> void:
	# 等效“抓住表面拖动”：左右拖 → 水平环绕；往下拖 = 低头看北极
	yaw -= delta_px.x * DRAG_SENS
	pitch += delta_px.y * DRAG_SENS
	# 俯仰限制在 ±86° 左右：接近 ±90° 时 look_at 的“上方”参考会失效
	pitch = clampf(pitch, -1.5, 1.5)
	_update_cam()


# 旋转入口（带死区）：位移超过 ROTATE_START_PX 才真正转动。
# 累计位移记账放在死区内也照常进行，保证“点/拖”判定与旋转节奏解耦。
func _rotate(delta_px: Vector2) -> void:
	var moved := _track_move(delta_px)
	if moved > ROTATE_START_PX:
		_orbit_rotate(delta_px)


func _zoom(factor: float) -> void:
	# factor < 1 = 拉近，> 1 = 推远，乘法缩放让任何距离下手感一致
	dist = clampf(dist * factor, MIN_DIST, MAX_DIST)
	_update_cam()


func _current_pinch_distance() -> float:
	var keys := _touch_points.keys()
	if keys.size() < 2:
		return 0.0
	return (_touch_points[keys[0]] - _touch_points[keys[1]]).length()


func _update_cam() -> void:
	# 球坐标 → 直角坐标：yaw 绕竖直轴，pitch 决定相机高度，dist 是半径
	var pos := target
	pos.x += dist * cos(pitch) * sin(yaw)
	pos.y += dist * sin(pitch)
	pos.z += dist * cos(pitch) * cos(yaw)
	cam.position = pos
	cam.look_at(target, Vector3.UP)


# 把镜头对准 dir 方向（星球生成完后对准大陆质心那面）。
# yaw/pitch 与 _update_cam() 的球坐标约定严格互逆：
#   pos.x = d·sin(yaw)、pos.z = d·cos(yaw)、pos.y = d·sin(pitch)。
# 俯仰夹在 ±77°（同拖拽上限），贴近两极也不让 look_at 的 UP 参考失效；
# look_at 的上方向恒为 +Y，北极在画面上始终朝上。
func focus_on(dir: Vector3) -> void:
	var d := dir.normalized()
	yaw = atan2(d.x, d.z)
	pitch = clampf(asin(clampf(d.y, -1.0, 1.0)), -1.35, 1.35)
	_update_cam()
