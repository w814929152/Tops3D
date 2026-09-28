extends SceneTree
##
## 诊断：陀螺撞到场地边缘到底弹不弹得开。
##
## 弹开这件事目前**完全交给引擎**（PhysicsMaterial.bounce），规则层的 apply_wall
## 只负责扣转速、_clamp_to_arena 只做防逃逸兜底。所以要看清的是：
##   ① 法向速度撞墙后还剩多少（恢复系数）
##   ② 切向速度有没有被墙的摩擦吃掉（决定「弹开」还是「贴着滑」）
##
## 跑法：--headless --path D:/Tops3D --script res://tests/tops_wall_probe.gd
##       SLOPE_SCALE=0 可以关掉碗坡向心力，单独看墙的弹性。
##

const SPEED := 300.0


func _initialize() -> void:
	var env := OS.get_environment("SLOPE_SCALE")
	if env != "":
		TopsRules.SLOPE_ACCEL_SCALE = float(env)
	Engine.physics_ticks_per_second = 60
	await process_frame
	var scene := load("res://tops/tops_main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame
	var mm := main as TopsMain
	mm.start_game()
	for i in 5:
		await physics_frame
	mm._launch(0.8)
	await physics_frame

	# 只留 1 号陀螺，其余冻结并挪开，免得撞在一起干扰
	var hero: TopTop = null
	for c in mm.get_children():
		if c is TopTop:
			var t := c as TopTop
			if hero == null:
				hero = t
			else:
				t.freeze = true
				t.set_collides(false)
	if hero == null:
		print("  找不到陀螺")
		quit(1)
		return

	TopsRules.ARENA_CENTER = TopsMain.CENTER
	TopsRules.ARENA_RADIUS = mm._arena_radius
	var bound: float = mm._arena_radius + TopsRules.WALL_INNER_OFFSET
	print("  场地半径 %.0f｜硬边界(墙内表面) %.0f｜slope_scale=%.2f"
			% [mm._arena_radius, bound, TopsRules.SLOPE_ACCEL_SCALE])
	print("  从圆心正对 +X 以 %.0f wu/s 直撞" % SPEED)

	hero.set_plane_pos(Vector2.ZERO)
	hero.linear_velocity = Vector3(SPEED, 0.0, 0.0)
	hero.freeze = true
	await physics_frame
	hero.freeze = false
	hero.linear_velocity = Vector3(SPEED, 0.0, 0.0)

	var hit := -1
	var max_x := 0.0
	var v_in := 0.0
	var v_hit := 0.0
	var x_late := 0.0
	for i in 400:
		await physics_frame
		var p: Vector2 = hero.plane_pos()
		var v: Vector2 = hero.plane_vel()
		max_x = maxf(max_x, p.x)
		if hit < 0:
			if v.x < 0.0:
				hit = i
				v_in = p.x
				v_hit = v.x
				print("  ── 第 %d 帧反弹：x=%.1f  vx=%.1f  vy=%.1f"
						% [i, p.x, v.x, v.y])
			elif i % 20 == 0:
				print("     飞行中 x=%.1f  vx=%.1f" % [p.x, v.x])
		elif i <= hit + 8:
			print("     +%d 帧: x=%.1f  vx=%.1f  vy=%.1f" % [i - hit, p.x, v.x, v.y])
			x_late = p.x

	print("  最远到达 x=%.1f（硬边界 %.0f，深入 %.1f）"
			% [max_x, bound, max_x - bound])

	# ⚠ 撞墙弹开的守卫**放在这里**，不放冒烟测试：
	#   碗坡把陀螺聚到中心 + 全场不可操控之后，默认对局里没人会飞到边缘
	#   （实测 3 局里 1 局撞墙 0 次），「一局里必然撞墙」已经不是不变量了。
	#   机制本身靠这道**定向直撞**来验。
	var h := TestHarness.new()
	h.suite("撞到边缘会弹开")
	h.ck(hit >= 0, "陀螺够到边缘后速度反向（第 %d 帧）" % hit)
	h.ck(v_hit < -80.0, "反弹速度 %.0f wu/s（是弹开，不是贴着滑）" % v_hit)
	h.ck(max_x > bound - 30.0, "确实够到了边缘（最远 %.0f / 硬边界 %.0f）" % [max_x, bound])
	h.ck(x_late < v_in, "反弹后确实在往回走（%.0f → %.0f）" % [v_in, x_late])
	print("")
	print("── 汇总：PASS %d / FAIL %d" % [h.pass_count(), h.fail_count()])
	for f in h.failures():
		print("   FAIL: ", f)
	main.free()
	quit(1 if h.fail_count() > 0 else 0)
