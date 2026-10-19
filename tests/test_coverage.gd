extends GutTest
# 覆盖率验收测试（GUT 版）：
# 世界菜单里的“全球覆盖率”承诺“多大比例的球面有真实地形”，
# 本套件真刀真枪跑一遍生成管线（分帧、几秒级），然后数 _generated
# 里 1 的个数，验收其占全球贴片的比例是否贴合所选档位。
# 容忍 ±2%：四舍五入 + 内陆湖/碎斑清洗带来的少量偏差属于设计内。

const PLANET := preload("res://planet.gd")
const SEED := 4242

# 组一颗星球并完整跑一遍生成管线，返回已生成（可交互）贴片个数
func _generate_and_count(coverage: float) -> Dictionary:
	# 分帧管线内部 await process_frame，星球必须在场景树里
	var planet: Node3D = add_child_autofree(PLANET.new())
	planet._init_noise(SEED)
	await planet._build_goldberg_mesh_async(coverage)
	var generated := 0
	for flag in planet._generated:
		if flag == 1:
			generated += 1
	var total: int = planet._generated.size()
	return {"count": generated, "total": total}


func test_coverage_30_percent() -> void:
	var r: Dictionary = await _generate_and_count(0.3)
	var target: int = roundi(r["total"] * 0.3)
	print("30%% 档：实际 %d / %d，目标 %d" % [r["count"], r["total"], target])
	assert_between(r["count"], int(target * 0.98), int(target * 1.02),
			"30%% 档覆盖率应贴合目标（目标 %d，±2%%）" % target)


func test_coverage_50_percent() -> void:
	var r: Dictionary = await _generate_and_count(0.5)
	var target: int = roundi(r["total"] * 0.5)
	print("50%% 档：实际 %d / %d，目标 %d" % [r["count"], r["total"], target])
	assert_between(r["count"], int(target * 0.98), int(target * 1.02),
			"50%% 档覆盖率应贴合目标（目标 %d，±2%%）" % target)
