extends SceneTree
##
## 探针：定位玩家逃逸时，它相对墙环的哪个缺口穿出。用 FileAccess 写文件，避免 headless print 卡顿。
## 跑法：--headless --path D:/Tops3D --script res://tests/tops_probe_escape.gd
##

func _initialize() -> void:
	Engine.physics_ticks_per_second = 60
	var scene := load("res://tops/tops_main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame

	(main as TopsMain).SHRINK_START = 99999.0
	var tops: Array[TopTop] = []
	for c in main.get_children():
		if c is TopTop:
			var t := c as TopTop
			t.set_collides(true)
			t.freeze = false
			tops.append(t)

	var pl: TopTop = (main as TopsMain)._player
	var dir := Vector2(0.0, -1.0)
	pl.facing = dir.angle()
	pl.linear_velocity = Vector3(dir.x, 0.0, dir.y) * (pl.move_speed * 1.2)

	var log: Array[String] = []
	var guard := 0
	var escaped := false
	while guard < 2400:
		await physics_frame
		guard += 1
		# AI 驱动（复现主场景战斗阶段，缺了它玩家不会逃逸）
		for t in tops:
			if t != pl and t.alive:
				TopsRules.ai_drive(t, tops, "chase", TopsMain.CENTER)
		var d := pl.plane_pos().distance_to(TopsMain.CENTER)
		if not escaped and d > (main as TopsMain)._arena_radius + 20.0:
			escaped = true
			# 找最近的墙段
			var best_dist := INF
			var best_ang := 0.0
			for seg in main.get_children():
				if seg is StaticBody3D and seg.is_in_group(&"wall"):
					var sd: float = pl.plane_pos().distance_to(Vector2(seg.global_position.x, seg.global_position.z))
					if sd < best_dist:
						best_dist = sd
						best_ang = atan2(seg.global_position.z, seg.global_position.x)
			log.append("ESCAPE t=%.2f 玩家@%s v=%s wh=%d 最近墙段距离=%s 墙段角=%.1f° 玩家角=%.1f°" % [
				guard / 60.0, _f1(d), _f1(pl.plane_vel().length()), pl.wall_hits,
				_f1(best_dist), rad_to_deg(best_ang), rad_to_deg(atan2(pl.plane_vel().y, pl.plane_vel().x))])
		if escaped and guard % 30 == 0:
			log.append("post@%s v=%s wh=%d" % [_f1(d), _f1(pl.plane_vel().length()), pl.wall_hits])
		if guard > 240 and escaped:
			break

	# 写文件到项目目录，方便读取
	var path := "res://probe_escape.log"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		for l in log:
			f.store_line(l)
		f.close()
	print("[PROBE] lines=%d written to user://probe_escape.log" % log.size())
	quit(0)


func _f1(x: float) -> String:
	return "%.1f" % x
