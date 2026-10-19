class_name OrbitCamera
extends Node3D
# 通用轨道相机控制器：中键拖动 = 环绕旋转，滚轮 = 拉近/推远（带限位）。
# 用法：OrbitCamera.new() 后 add_child 即可；相机始终看向 target。
# 原理：转的是“相机绕目标”，被观察物体自己不动——
# 表面上的图案（shader 按模型空间计算）自然不会漂移。

const MIN_DIST := 1.5  # 最近限制：必须大于被观察物体的最大突出半径（球体 = 半径 1）
const MAX_DIST := 10.0 # 最远限制：再远就看不清了
const DRAG_SENS := 0.01 # 拖动灵敏度：弧度/像素

var target := Vector3.ZERO # 环绕中心
var dist := 3.5            # 相机到中心的距离
var yaw := 0.0             # 水平环绕角（弧度）
var pitch := 0.0           # 俯仰角（弧度，0 = 平视）
var dragging := false      # 中键是否正被按住

var cam: Camera3D


func _ready() -> void:
	cam = Camera3D.new()
	add_child(cam)
	_update_cam()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			# 按下中键开始拖动，松开结束
			dragging = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			# 滚轮上：拉近。乘法缩放让任何距离下手感一致；
			# maxf 兜住下限，防止镜头穿进行星
			dist = maxf(dist * 0.9, MIN_DIST)
			_update_cam()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			# 滚轮下：推远，minf 兜住上限，防止小到看不见
			dist = minf(dist * 1.1, MAX_DIST)
			_update_cam()
	elif event is InputEventMouseMotion and dragging:
		# 想象“抓住行星表面拖动”：
		# 左右拖 → 水平环绕；往下拖 = 低头看北极
		yaw -= event.relative.x * DRAG_SENS
		pitch += event.relative.y * DRAG_SENS
		# 俯仰限制在 ±86° 左右：接近 ±90° 时 look_at 的“上方”参考会失效
		pitch = clampf(pitch, -1.5, 1.5)
		_update_cam()


func _update_cam() -> void:
	# 球坐标 → 直角坐标：yaw 绕竖直轴，pitch 决定相机高度，dist 是半径
	var pos := target
	pos.x += dist * cos(pitch) * sin(yaw)
	pos.y += dist * sin(pitch)
	pos.z += dist * cos(pitch) * cos(yaw)
	cam.position = pos
	cam.look_at(target, Vector3.UP)
