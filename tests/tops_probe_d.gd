extends SceneTree
##
## 探针 D：直接跑 TopsMain 场景（含 AI + 缩圈，经 _physics_process），
## 每 2 秒把全体陀螺距圆心写入 user://probe_d.log。复现真实逃逸并定位是谁、何时。
## 跑法：--headless --path D:/Tops3D --script res://tests/tops_probe_d.gd
##

func _initialize() -> void:
	Engine.physics_ticks_per_second = 480
	Engine.time_scale = 16.0
	var scene := load("res://tops/tops_main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame

	var log: Array[String] = []
	var guard := 0
	while guard < 9600 and not (main as TopsMain)._finished:
		await physics_frame
		guard += 1
		if guard % 96 == 0:   # 约每 2 秒（480Hz×16× / 96 ≈ 2s）
			var mm := main as TopsMain
			var parts: Array[String] = []
			for c in mm.get_children():
				if c is TopTop and (c as TopTop).alive:
					var d := (c as TopTop).plane_pos().distance_to(TopsMain.CENTER)
					parts.append("#%d@%s/wh%d" % [(c as TopTop).top_id, _f1(d), (c as TopTop).wall_hits])
			log.append("t=%.1f arenaR=%s | %s" % [mm._elapsed, _f1(mm._arena_radius), " ".join(parts)])

	var f := FileAccess.open("user://probe_d.log", FileAccess.WRITE)
	if f != null:
		for l in log:
			f.store_line(l)
		f.close()
	print("[PROBE-D] frames=%d finished=%s lines=%d" % [guard, (main as TopsMain)._finished, log.size()])
	quit(0)


func _f1(x: float) -> String:
	return "%.1f" % x
