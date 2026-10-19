extends Node3D
# 学习项目：加载 cube.obj，表面画“灰底 + 深蓝折线 + 玉米贴图”。
# 交互：鼠标中键拖动 = 环绕旋转视角；滚轮 = 拉近 / 推远（有距离限制）。

# ---- 折线的 3 个点 = 2 段折线（cube 坐标范围是 -1..1）----
var line_points: Array[Vector3] = [
	Vector3(0.0, 0.0, 1.0), # 第 1 点：front face（z=1 面上）
	Vector3(1.0, 0.0, 1.0), # 第 2 点：front 与 right 的共享棱（x=1, z=1）
	Vector3(1.0, 0.0, 0.0), # 第 3 点：right face（x=1 面上）
]

# ---- 交互状态 ----
var cam: Camera3D
var cube: MeshInstance3D
var yaw := 0.0        # 水平环绕角（弧度）
var pitch := 0.0      # 俯仰角（弧度，0 = 平视）
var cam_dist := 4.0   # 相机到原点的距离
var dragging := false # 中键是否正被按住

const MIN_DIST := 2.5  # 最近限制：立方体中心到角约 1.73，2.5 保证镜头不穿进立方体
const MAX_DIST := 10.0 # 最远限制：再远立方体就小到看不清了
const DRAG_SENS := 0.01 # 拖动灵敏度：弧度/像素


func _ready() -> void:
	# ---- 相机 ----
	# 位置不用写死：交给 _update_cam() 按 yaw/pitch/cam_dist 球坐标摆位。
	cam = Camera3D.new()
	add_child(cam)
	_update_cam()

	# ---- 网格 ----
	var mesh: Mesh = load("res://cube.obj")

	# 打印 AABB：确认模型实际坐标范围，折线点必须与之匹配
	# 预期：P=(-1,-1,-1) S=(2,2,2)，即 -1..1
	print("cube AABB: ", mesh.get_aabb())

	cube = MeshInstance3D.new()
	cube.mesh = mesh
	add_child(cube)

	# ---- Shader 材质 ----
	var mat := ShaderMaterial.new()
	mat.shader = load("res://surface.gdshader")
	# 用 3 个独立 uniform 传点（不用数组，新手友好）
	mat.set_shader_parameter("line_p0", line_points[0])
	mat.set_shader_parameter("line_p1", line_points[1])
	mat.set_shader_parameter("line_p2", line_points[2])
	# 验证参数真的传进去了
	print("line_p0 = ", mat.get_shader_parameter("line_p0"))
	# 玉米贴图：shader 里沿折线每隔 corn_spacing 印一棵
	mat.set_shader_parameter("corn_tex", load("res://corn.png"))

	cube.material_override = mat # 覆盖 obj 自带材质，有无 mtl 都不影响


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			# 按下中键开始拖动，松开结束
			dragging = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			# 滚轮上：拉近。用乘法缩放，任何距离下手感都一致；
			# maxf 兜住下限，防止镜头钻进立方体（穿模）
			cam_dist = maxf(cam_dist * 0.9, MIN_DIST)
			_update_cam()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			# 滚轮下：推远，minf 兜住上限，防止小到看不见
			cam_dist = minf(cam_dist * 1.1, MAX_DIST)
			_update_cam()
	elif event is InputEventMouseMotion and dragging:
		# 想象“抓住立方体表面拖动”：
		# 左右拖 → 视角水平环绕；上下拖 → 俯仰（往下拖 = 低头看顶面）
		yaw -= event.relative.x * DRAG_SENS
		pitch += event.relative.y * DRAG_SENS
		# 俯仰限制在 ±86° 左右：接近 ±90° 时 look_at 的“上方”参考会失效
		pitch = clampf(pitch, -1.5, 1.5)
		_update_cam()


func _update_cam() -> void:
	# 球坐标 → 直角坐标：yaw 绕竖直轴转，pitch 决定相机高度，cam_dist 是半径。
	# 相机位置变了但始终 look_at 原点——立方体和图案纹丝不动，
	# 折线/玉米钉在表面上自然也不会漂。
	var pos := Vector3.ZERO
	pos.x = cam_dist * cos(pitch) * sin(yaw)
	pos.y = cam_dist * sin(pitch)
	pos.z = cam_dist * cos(pitch) * cos(yaw)
	cam.position = pos
	cam.look_at(Vector3.ZERO, Vector3.UP)
