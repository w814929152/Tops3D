extends SceneTree
##
## 隔离测试：单个陀螺发射后能否被墙环挡住？（无缩圈、无其它陀螺干扰）
## 跑法：--headless --path D:/Tops3D --script res://tests/tops_iso_wall.gd
##

const WALL_SEGMENTS := 24


func _initialize() -> void:
	Engine.physics_ticks_per_second = 60
	var scene := load("res://tops/tops_main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame

	# 关掉所有 AI 推进与缩圈，只留玩家陀螺做一次发射
	for c in main.get_children():
		if c is TopTop:
			(c as TopTop).set_collides(true)
	(main as TopsMain).SHRINK_START = 99999.0   # 禁用缩圈

	var pl: TopTop = (main as TopsMain)._player
	pl.freeze = false
	# 朝场地中心方向发射，力度拉满（模拟玩家满蓄力）
	var dir := Vector2(0.0, -1.0)
	pl.facing = dir.angle()
	pl.linear_velocity = Vector3(dir.x, 0.0, dir.y) * (pl.move_speed * 1.2)
	print("[ISO] 满速发射 初速=%s move_speed=%s" % [_f1(pl.plane_vel().length()), _f1(pl.move_speed)])

	# 跑 20 秒物理，看它能不能稳定在墙内
	var guard := 0
	var max_d := 0.0
	while guard < 1200:
		await physics_frame
		guard += 1
		var d := pl.plane_pos().distance_to(TopsMain.CENTER)
		max_d = maxf(max_d, d)
		if guard % 60 == 0:
			print("[ISO] t=%.1f 距圆心=%s wall_hits=%d" % [guard / 60.0, _f1(d), pl.wall_hits])

	print("[ISO] 场半径=%s｜陀螺最远距圆心=%s｜wall_hits=%d｜contacts=%d" % [
		_f1((main as TopsMain)._arena_radius), _f1(max_d), pl.wall_hits, pl.contacts])
	print("[ISO] %s" % ("PASS 陀螺留在场内" if max_d < (main as TopsMain)._arena_radius + 20.0 else "FAIL 陀螺穿出墙外"))

	quit(0)


func _f1(x: float) -> String:
	return "%.1f" % x
