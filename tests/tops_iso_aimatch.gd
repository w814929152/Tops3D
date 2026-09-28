extends SceneTree
##
## 隔离测试 B：玩家陀螺 + AI 陀螺在场，复现「混战中玩家逃逸」是否由 AI 撞击造成。
## 跑法：--headless --path D:/Tops3D --script res://tests/tops_iso_aimatch.gd
##

func _initialize() -> void:
	Engine.physics_ticks_per_second = 60
	var scene := load("res://tops/tops_main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame

	(main as TopsMain).SHRINK_START = 99999.0   # 禁用缩圈，隔离纯碰撞效应

	# 让所有陀螺都参与碰撞并解冻（模拟进场后状态）
	var tops: Array[TopTop] = []
	for c in main.get_children():
		if c is TopTop:
			var t := c as TopTop
			t.set_collides(true)
			t.freeze = false
			tops.append(t)

	var pl: TopTop = (main as TopsMain)._player
	# 玩家满蓄力朝中心发射
	var dir := Vector2(0.0, -1.0)
	pl.facing = dir.angle()
	pl.linear_velocity = Vector3(dir.x, 0.0, dir.y) * (pl.move_speed * 1.2)
	# AI 也给它初速朝中心，制造混战
	for t in tops:
		if t == pl:
			continue
		var to_c := (TopsMain.CENTER - t.plane_pos()).normalized()
		t.linear_velocity = Vector3(to_c.x, 0.0, to_c.y) * (t.move_speed * 0.9)

	var guard := 0
	var max_d := 0.0
	while guard < 1800:
		await physics_frame
		guard += 1
		# AI 驱动（复现主场景战斗阶段）
		for t in tops:
			if t != pl and t.alive:
				TopsRules.ai_drive(t, tops, "chase", TopsMain.CENTER)
		var d := pl.plane_pos().distance_to(TopsMain.CENTER)
		max_d = maxf(max_d, d)
		if guard % 60 == 0:
			print("[ISO-B] t=%.1f 玩家@%s v=%s contacts=%d wh=%d" % [
				guard / 60.0, _f1(d), _f1(pl.plane_vel().length()), pl.contacts, pl.wall_hits])

	print("[ISO-B] 场半径=%s｜玩家最远=%s｜contacts=%d｜wh=%d" % [
		_f1((main as TopsMain)._arena_radius), _f1(max_d), pl.contacts, pl.wall_hits])
	print("[ISO-B] %s" % ("PASS 玩家留在场内" if max_d < (main as TopsMain)._arena_radius + 20.0 else "FAIL 玩家穿出墙外"))

	quit(0)


func _f1(x: float) -> String:
	return "%.1f" % x
