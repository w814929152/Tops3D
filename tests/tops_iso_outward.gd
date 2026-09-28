extends SceneTree
##
## 隔离测试 E：单个陀螺放在场地中心，给一个朝外的速度，看墙环能否挡住。
## 跑法：--headless --path D:/Tops3D --script res://tests/tops_iso_outward.gd
##

func _initialize() -> void:
	Engine.physics_ticks_per_second = 60
	var scene := load("res://tops/tops_main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame

	(main as TopsMain).SHRINK_START = 99999.0
	# 手动把墙环平移到 0.55×半径，模拟缩圈后的窄场地（平移而非缩放，碰撞面才跟手）
	(main as TopsMain)._arena_radius = (main as TopsMain).BASE_RADIUS * 0.55
	(main as TopsMain)._place_wall((main as TopsMain)._arena_radius)
	for c in main.get_children():
		if c is TopTop:
			(c as TopTop).set_collides(true)
			(c as TopTop).freeze = false

	var pl: TopTop = (main as TopsMain)._player
	# 放到场地中心，朝正上方（屏幕远端）发射中速
	pl.set_plane_pos(Vector2(0.0, 0.0))
	pl.linear_velocity = Vector3(0.0, 0.0, -200.0)

	var guard := 0
	var max_d := 0.0
	while guard < 600:
		await physics_frame
		guard += 1
		var d := pl.plane_pos().distance_to(TopsMain.CENTER)
		max_d = maxf(max_d, d)
		if guard % 30 == 0:
			print("[ISO-E] t=%.1f @%s v=%s wh=%d" % [guard / 60.0, _f1(d), _f1(pl.plane_vel().length()), pl.wall_hits])

	print("[ISO-E] 场半径=%s 最远=%s wh=%d → %s" % [
		_f1((main as TopsMain)._arena_radius), _f1(max_d), pl.wall_hits,
		"PASS 被墙挡住" if max_d < (main as TopsMain)._arena_radius + 20.0 else "FAIL 穿出"])
	quit(0)


func _f1(x: float) -> String:
	return "%.1f" % x
