extends SceneTree
##
## 碗体几何自检：确认「缩放之后」的碗真的有场地那么大、倾角真的是 SLOPE_DEG。
## 用数值而不是截图 —— 截图看不出毫米级的缩放错误（曾经把碗缩成 1.45 世界单位）。
##
## 跑法：--headless --path D:/Tops3D --script res://tests/tops_arena_geom_check.gd
##

const BASE_BOUND := 270.0   # BASE_RADIUS(250) + WALL_INNER_OFFSET(20)


func _initialize() -> void:
	await process_frame
	var bowl: Node3D = TopsArena.build(BASE_BOUND)
	var mi: MeshInstance3D = bowl.get_child(0) as MeshInstance3D
	var aabb: AABB = mi.mesh.get_aabb()

	# main 的 _update_bowl：scale = (bound, bound/BASE_BOUND, bound)
	var sc := Vector3(BASE_BOUND, BASE_BOUND / TopsArena.BASE_BOUND, BASE_BOUND)
	bowl.scale = sc
	var world: AABB = mi.mesh.get_aabb()
	var half_x: float = world.size.x * 0.5 * sc.x
	var top_y: float = world.end.y * sc.y

	print("  碗坡倾角设定 SLOPE_DEG = %.1f°" % TopsArena.SLOPE_DEG)
	print("  单位碗 AABB  x:[%.4f, %.4f]  y:[%.2f, %.2f]"
			% [aabb.position.x, aabb.end.x, aabb.position.y, aabb.end.y])
	print("  缩放后世界  半宽 %.1f（硬边界应 = %.0f）｜碗沿高 %.1f（WALL_TOP=%.1f）"
			% [half_x, BASE_BOUND, top_y, TopsArena.WALL_TOP])

	# 从实际母线反算倾角：找平底边界点(1.0,0)与坡顶点
	var pts: Array[Vector2] = TopsArena._profile()
	var p0 := Vector2.ZERO
	var p1 := Vector2.ZERO
	for p in pts:
		if p.x <= 1.0001 and p.y <= 0.0001:
			p0 = p
		if p.y >= TopsArena.WALL_TOP - 0.001:
			p1 = p
			break
	var run_world: float = (p1.x - p0.x) * sc.x
	var rise_world: float = (p1.y - p0.y) * sc.y
	var deg: float = rad_to_deg(atan2(rise_world, run_world))
	print("  母线反算：水平 %.1f wu / 抬升 %.1f wu → 实际倾角 %.2f°"
			% [run_world, rise_world, deg])

	var ok := true
	if half_x < BASE_BOUND * 0.9:
		print("  [FAIL] 碗比场地小太多（缩放系数不对）")
		ok = false
	if absf(deg - TopsArena.SLOPE_DEG) > 0.5:
		print("  [FAIL] 实际倾角与 SLOPE_DEG 不符")
		ok = false
	if top_y < 1.0 or top_y > 200.0:
		print("  [FAIL] 碗沿高度离谱（y 缩放不对）")
		ok = false
	print("  %s" % ("[PASS] 碗体几何正确" if ok else "[FAIL] 碗体几何有问题"))
	bowl.free()
	quit(0 if ok else 1)
