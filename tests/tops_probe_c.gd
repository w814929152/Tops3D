extends SceneTree
##
## 探针 C：整局跑完后，把每个陀螺的最终距圆心、最远距离、wall_hits 写入 res://probe_c.log。
## 用 FileAccess（res 只读时改写 user），避免 per-frame print 卡顿。
## 跑法：--headless --path D:/Tops3D --script res://tests/tops_probe_c.gd
##

func _initialize() -> void:
	Engine.physics_ticks_per_second = 60
	var scene := load("res://tops/tops_main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame

	var mm := main as TopsMain
	# 保留缩圈（默认），复现真实对局，观察是否有陀螺被墙环落下
	var tops: Array[TopTop] = []
	for c in main.get_children():
		if c is TopTop:
			tops.append(c as TopTop)

	# 记录每帧所有陀螺的最远距离
	var log: Array[String] = []
	var frame := 0
	while frame < 4800 and _alive(tops) > 1:
		await physics_frame
		frame += 1
		if frame % 120 == 0:
			var parts: Array[String] = []
			var worst := 0.0
			for t in tops:
				if not t.alive:
					continue
				var d := t.plane_pos().distance_to(TopsMain.CENTER)
				worst = maxf(worst, d)
				parts.append("#%d@%s/wh%d" % [t.top_id, _f1(d), t.wall_hits])
			log.append("f%d arenaR=%s worst=%s | %s" % [frame, _f1(mm._arena_radius), _f1(worst), " ".join(parts)])

	var f := FileAccess.open("user://probe_c.log", FileAccess.WRITE)
	if f != null:
		for l in log:
			f.store_line(l)
		f.close()
	print("[PROBE-C] frames=%d alive=%d lines=%d" % [frame, _alive(tops), log.size()])
	quit(0)


func _alive(tops: Array[TopTop]) -> int:
	var n := 0
	for t in tops:
		if t.alive:
			n += 1
	return n


func _f1(x: float) -> String:
	return "%.1f" % x
