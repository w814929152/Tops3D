extends SceneTree
##
## 诊断：陀螺「紧挨着不弹开」到底挨到什么程度、靠什么机制分开。
##
## 跑法：--headless --path D:/Tops3D --script res://tests/tops_stick_probe.gd
##
## 为什么要写这个：tops_stick_check.gd 只量 gap<1.0（**物理接触**），报 0.38 s
## 看着很健康。但玩家看到的是「画面上挨在一起」，那是更大的距离口径（gap 几个 wu）。
## 更关键的是：轮缘摩擦给的 dv 是**切向**的 —— 切向滑动只让两颗陀螺**绕着彼此转圈**，
## 中心距并不增大。所以「能错开」≠「能弹开」。本探针按多个距离口径分别统计，
## 并拆开记录法向分离速度 vs 切向绕行速度，定位到底是「死顶」还是「并排游走」。
##

const PROX_LIST := [1.0, 3.0, 6.0, 10.0]


func _initialize() -> void:
	Engine.physics_ticks_per_second = 60
	await process_frame
	var scene := load("res://tops/tops_main.tscn")
	var mm: TopsMain = scene.instantiate()
	root.add_child(mm)
	await process_frame
	mm.start_game()
	for _i in 5:
		await physics_frame
	mm._launch(0.8)

	# 480 Hz × 8 倍速：每 tick 推进的**游戏内**时长仍是 1/60 s，等价于真机 60 Hz
	Engine.physics_ticks_per_second = 480
	Engine.time_scale = 8.0

	var tops: Array[TopTop] = []
	for c in mm.get_children():
		if c is TopTop:
			tops.append(c as TopTop)

	var cur: Dictionary = {}      # key -> 段记录
	var runs: Array = []
	var guard := 0

	while guard < 9000 and mm._phase != TopsMain.Phase.RESULT:
		await physics_frame
		guard += 1
		for i in tops.size():
			for j in range(i + 1, tops.size()):
				var a: TopTop = tops[i]
				var b: TopTop = tops[j]
				if not is_instance_valid(a) or not is_instance_valid(b):
					continue
				var key := "%d-%d" % [a.top_id, b.top_id]
				if not a.alive or not b.alive:
					cur.erase(key)
					continue
				var delta: Vector2 = b.plane_pos() - a.plane_pos()
				var dist: float = delta.length()
				if dist < 0.001:
					continue
				var gap: float = dist - (a.top_radius + b.top_radius)
				var n: Vector2 = delta / dist
				var t_hat := Vector2(n.y, -n.x)
				var rel: Vector2 = b.plane_vel() - a.plane_vel()
				var press: float = maxf(0.0, -(b.drive_accel - a.drive_accel).dot(n))
				var thrust_toward: bool = (a.thrusting and a.input_dir.dot(n) > 0.5) \
						or (b.thrusting and b.input_dir.dot(-n) > 0.5)

				if gap < PROX_LIST[PROX_LIST.size() - 1]:
					if not cur.has(key):
						cur[key] = {
							"id": key, "f": 1, "min_gap": gap, "sum_gap": gap,
							"min_gap_1": gap, "f_touch": 0, "f_prox3": 0, "f_prox6": 0,
							"sum_vn": 0.0, "sum_vt": 0.0, "sum_press": press,
							"f_thrust": 1 if thrust_toward else 0,
							"sum_spin": (a.spin + b.spin) * 0.5,
						}
					else:
						var r: Dictionary = cur[key]
						r["f"] = int(r["f"]) + 1
						r["min_gap"] = minf(float(r["min_gap"]), gap)
						r["sum_gap"] = float(r["sum_gap"]) + gap
						r["sum_press"] = float(r["sum_press"]) + press
						r["sum_spin"] = float(r["sum_spin"]) + (a.spin + b.spin) * 0.5
						if thrust_toward:
							r["f_thrust"] = int(r["f_thrust"]) + 1
					if gap < 1.0:
						cur[key]["f_touch"] = int(cur[key]["f_touch"]) + 1
					if gap < 3.0:
						cur[key]["f_prox3"] = int(cur[key]["f_prox3"]) + 1
					if gap < 6.0:
						cur[key]["f_prox6"] = int(cur[key]["f_prox6"]) + 1
					cur[key]["sum_vn"] = float(cur[key]["sum_vn"]) + rel.dot(n)
					cur[key]["sum_vt"] = float(cur[key]["sum_vt"]) + absf(rel.dot(t_hat))
				elif cur.has(key):
					var r2: Dictionary = cur[key]
					r2["sep_vn"] = rel.dot(n)
					runs.append(r2)
					cur.erase(key)
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60

	print("")
	print("════════ 贴靠诊断 ════════")
	print("对局 %.1f s｜近距离段 %d 个" % [mm._elapsed, runs.size()])
	if runs.is_empty():
		print("（没有检测到任何近距离段）")
		mm.free()
		quit(0)
		return

	# 各口径下的「最长停留」与总占比
	print("")
	print("口径        最长段(s)   平均段(s)   ≥0.5s 段数   ≥1.0s 段数")
	for prox in PROX_LIST:
		var fk: String = "f" if prox == 1.0 else ("f_touch" if prox == 1.0 else "")
		var longest := 0
		var sumf := 0.0
		var n05 := 0
		var n10 := 0
		var cnt := 0
		for r in runs:
			var f: int = _frames_in(r, prox)
			if f <= 0:
				continue
			cnt += 1
			longest = maxi(longest, f)
			sumf += float(f)
			if float(f) / 60.0 >= 0.5:
				n05 += 1
			if float(f) / 60.0 >= 1.0:
				n10 += 1
		if cnt == 0:
			print("gap<%4.1f      （无）" % prox)
			continue
		print("gap<%4.1f     %6.2f     %6.2f      %4d        %4d"
				% [prox, float(longest) / 60.0, sumf / float(cnt) / 60.0, n05, n10])

	# 最坏的几个段：看它是「死顶」还是「并排游走」
	runs.sort_custom(func(x, y): return int(x["f"]) > int(y["f"]))
	print("")
	print("── 停留最久的 6 段明细（f=帧, 60帧=1s）──")
	print("  段       帧数  最小gap  平均gap  平均切向v  平均法向v  挤压  推进占比  平均转速")
	for k in mini(6, runs.size()):
		var r: Dictionary = runs[k]
		var f: int = int(r["f"])
		print("  %-7s %5d  %7.2f  %7.2f  %9.0f  %9.1f  %5.0f  %6.0f%%  %7.1f"
				% [String(r["id"]), f, float(r["min_gap"]),
						float(r["sum_gap"]) / float(f),
						float(r["sum_vt"]) / float(f),
						float(r["sum_vn"]) / float(f),
						float(r["sum_press"]) / float(f),
						float(r["f_thrust"]) / float(f) * 100.0,
						float(r["sum_spin"]) / float(f)])

	var sep_sum := 0.0
	var sep_min := INF
	for r in runs:
		var s: float = float(r.get("sep_vn", 0.0))
		sep_sum += s
		sep_min = minf(sep_min, s)
	print("")
	print("分手瞬间法向速度：平均 %.0f wu/s｜最小 %.0f wu/s" % [sep_sum / float(runs.size()), sep_min])
	mm.free()
	quit(0)


func _frames_in(r: Dictionary, prox: float) -> int:
	if prox <= 1.0:
		return int(r["f_touch"])
	if prox <= 3.0:
		return int(r["f_prox3"])
	if prox <= 6.0:
		return int(r["f_prox6"])
	return int(r["f"])
