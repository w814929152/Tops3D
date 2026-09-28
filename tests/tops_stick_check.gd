extends SceneTree
##
## 防回归：旋转的陀螺应该互相弹开，不该死死顶在一起磨。
##
## 背景（2026-09-28 修的 bug）：
##   轮缘摩擦的切向冲量 J_t **同时**作用在自转和平移上 ——
##     · 自转：Δω = J_t·r / I       → 磨掉转速
##     · 平移：A 受 +s·J_t·t̂、B 受 −s·J_t·t̂ → 沿切向把两颗「搓」开
##   早期只算了自转那一半，漏掉平移那一半，结果两颗被 AI 顶在一起的陀螺能连续
##   贴 9 秒不分开（一局里 33% 的帧都有陀螺在互相粘着）。补上平移那一半之后
##   （并把挤压压力上限 GRIND_FORCE_MAX 放开到真实量级），最长接触段降到 0.25 s。
##
## 本测试把「最长接触段」和「贴着帧占比」钉死，防止这个 bug 悄悄回来。
##
## 跑法：--headless --path D:/Tops3D --script res://tests/tops_stick_check.gd
##

## 单个接触段的时长上限（秒）。
## AI 有随机性，实测最长段在 0.5～2.4 s 之间波动（修复前是 9.0 s），
## 阈值取 3.0 s 既能吃掉波动，又足够抓住「漏掉搓开」那个回归。
## 偶发的 1～2 秒是真实的「对磨」——两颗陀螺被顶住时边磨边错开，不是死顶。
const LONG_LIMIT := 3.0
## 一局里「有任意一对贴着」的帧占比上限。实测 7%～20%。
const TOUCH_RATIO_LIMIT := 0.35


func _initialize() -> void:
	Engine.physics_ticks_per_second = 60
	var h := TestHarness.new()
	await process_frame

	h.suite("旋转的陀螺会互相弹开，不会死顶")
	var scene := load("res://tops/tops_main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame
	var mm := main as TopsMain
	mm.start_game()
	for i in 5:
		await physics_frame
	mm._launch(0.8)
	# 加速跑：物理频率与倍速同比例放大，每帧的**游戏内**时长仍是 1/60 s，
	# 下面「帧数 / 60」换算成秒才成立（对局动辄 60～80 s，实时跑太慢）。
	Engine.physics_ticks_per_second = 480
	Engine.time_scale = 8.0

	var tops: Array[TopTop] = []
	for c in mm.get_children():
		if c is TopTop:
			tops.append(c as TopTop)

	var cur: Dictionary = {}
	var runs: Array = []
	var guard := 0
	var frames_touching := 0
	var frames_total := 0

	# 上限按「对局可能拖到 ~100 s」留足（碗坡向心力上线后一局普遍 50～80 s）
	while guard < 9000 and mm._phase != TopsMain.Phase.RESULT:
		await physics_frame
		guard += 1
		frames_total += 1
		var any := false
		for i in tops.size():
			for j in range(i + 1, tops.size()):
				var a: TopTop = tops[i]
				var b: TopTop = tops[j]
				# 出局的陀螺退场播完会被 main 真正 queue_free —— 先问还活着没，
				# 再碰它的任何属性（连 top_id 都读不到）
				if not is_instance_valid(a) or not is_instance_valid(b):
					continue
				var key := "%d-%d" % [a.top_id, b.top_id]
				if not a.alive or not b.alive:
					cur.erase(key)
					continue
				var delta: Vector2 = b.plane_pos() - a.plane_pos()
				var dist: float = delta.length()
				var gap: float = dist - (a.top_radius + b.top_radius)
				var n: Vector2 = delta / dist if dist > 0.001 else Vector2(1.0, 0.0)
				var rel: Vector2 = b.plane_vel() - a.plane_vel()
				var vt: float = absf(rel.dot(Vector2(n.y, -n.x)))
				if gap < 1.0:
					any = true
					if not cur.has(key):
						cur[key] = {
							"f": 1, "gap": gap, "min_gap": gap, "vt": vt,
							"press": maxf(0.0, -(b.drive_accel - a.drive_accel).dot(n)),
							"approach": -rel.dot(n), "sep": 0.0,
							"spin": (a.spin + b.spin) * 0.5,
						}
					else:
						var r: Dictionary = cur[key]
						r["f"] = int(r["f"]) + 1
						r["gap"] = float(r["gap"]) + gap
						r["min_gap"] = minf(float(r["min_gap"]), gap)
						r["vt"] = float(r["vt"]) + vt
						r["press"] = float(r["press"]) + maxf(0.0,
								-(b.drive_accel - a.drive_accel).dot(n))
						r["spin"] = float(r["spin"]) + (a.spin + b.spin) * 0.5
				elif cur.has(key):
					var r2: Dictionary = cur[key]
					r2["sep"] = rel.dot(n)
					runs.append(r2)
					cur.erase(key)
		if any:
			frames_touching += 1

	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	var ratio: float = float(frames_touching) / maxf(frames_total, 1)
	print("  对局 %.1f s｜接触段 %d 个｜贴着帧占比 %.0f%%"
			% [mm._elapsed, runs.size(), ratio * 100.0])
	main.free()

	h.ck(runs.size() > 0, "一局里确实发生过接触（%d 个接触段）" % runs.size())
	if runs.is_empty():
		print("")
		print("── 汇总：PASS %d / FAIL %d" % [h.pass_count(), h.fail_count()])
		quit(1 if h.fail_count() > 0 else 0)
		return

	runs.sort_custom(func(x, y): return int(x["f"]) > int(y["f"]))
	var longest: float = float(runs[0]["f"]) / 60.0
	var sum_f := 0.0
	var sum_sep := 0.0
	for r in runs:
		sum_f += float(r["f"])
		sum_sep += float(r["sep"])
	print("  最长接触段 %.2f s｜平均 %.2f s｜平均分离速度 %.0f wu/s"
			% [longest, sum_f / float(runs.size()) / 60.0,
					sum_sep / float(runs.size())])

	h.ck(longest < LONG_LIMIT,
			"最长接触段 %.2f s < %.1f s（没有陀螺死死顶在一起）" % [longest, LONG_LIMIT])
	h.ck(ratio < TOUCH_RATIO_LIMIT,
			"贴着帧占比 %.0f%% < %.0f%%" % [ratio * 100.0, TOUCH_RATIO_LIMIT * 100.0])
	h.ck(sum_sep / float(runs.size()) > 0.0,
			"接触之后是弹开的（平均分离速度 %.0f wu/s）" % [sum_sep / float(runs.size())])

	print("")
	print("── 汇总：PASS %d / FAIL %d" % [h.pass_count(), h.fail_count()])
	for f in h.failures():
		print("   FAIL: ", f)
	quit(1 if h.fail_count() > 0 else 0)
