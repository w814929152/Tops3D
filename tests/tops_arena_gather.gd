extends SceneTree
##
## 碗坡「周围高、中间低」的聚集效果体检。
##
## 场地几何（TopsArena）与玩法向心力（TopsRules.slope_accel）是两件独立的事：
## 碗画得再像碗，只要 gravity_scale=0 且没人补向心分量，陀螺飘到边上就不会回来。
## 本脚本把「陀螺到底有没有往中间聚」量成数字，顺便盯住对局还能不能收敛。
##
## AI 的随机性很大，单局说明不了问题 —— 默认跑 3 局取平均（ROUNDS 可覆盖）。
##
## 跑法：--headless --path D:/Tops3D --script res://tests/tops_arena_gather.gd
## 扫参：SLOPE_SCALE=1.2 ROUNDS=3 ...（同上）
##

## 归一化半径超过这个值就算「在外圈游荡」
const OUTER_U := 0.70
## 前 / 后段的分界（秒）
const SPLIT_T := 25.0

const SIM_SPEEDUP := 16.0
const SIM_TICKS := 480
const MAX_GUARD := 12000

var _rounds := 3


func _initialize() -> void:
	var env_scale := OS.get_environment("SLOPE_SCALE")
	if env_scale != "":
		TopsRules.SLOPE_ACCEL_SCALE = float(env_scale)
	var env_rounds := OS.get_environment("ROUNDS")
	if env_rounds != "":
		_rounds = int(env_rounds)
	var env_start := OS.get_environment("SLOPE_START")
	if env_start != "":
		TopsRules.SLOPE_START_RATIO = float(env_start)
	var env_swirl := OS.get_environment("SWIRL")
	if env_swirl != "":
		TopsRules.SLOPE_SWIRL_DEG = float(env_swirl)

	Engine.physics_ticks_per_second = 60
	await process_frame
	var scene := load("res://tops/tops_main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame
	var mm := main as TopsMain

	print("  slope_scale = %.2f｜start_ratio = %.2f｜边缘向心加速度 %.0f wu/s²"
			% [TopsRules.SLOPE_ACCEL_SCALE, TopsRules.SLOPE_START_RATIO,
					TopsRules.slope_accel(
							Vector2(TopsRules.ARENA_RADIUS * 0.999, 0.0),
							Vector2.ZERO, TopsRules.ARENA_RADIUS).length()])

	var sum_all := 0.0
	var sum_outer := 0.0
	var sum_late_over_early := 0.0
	var sum_dur := 0.0
	var sum_contacts := 0.0
	var sum_wall := 0.0
	for r in _rounds:
		var st := await _one_match(mm)
		sum_all += float(st["mean_u"])
		sum_outer += float(st["outer_ratio"])
		sum_late_over_early += float(st["late_over_early"])
		sum_dur += float(st["dur"])
		sum_contacts += float(st["contacts"])
		sum_wall += float(st["wall_hits"])
		print("   第 %d 局：%.1f s｜平均 r/R %.3f｜外圈占比 %.0f%%｜后/前 %.2f｜接触 %d 次｜撞墙 %d 次"
				% [r + 1, float(st["dur"]), float(st["mean_u"]),
						float(st["outer_ratio"]) * 100.0, float(st["late_over_early"]),
						int(st["contacts"]), int(st["wall_hits"])])

	var n := float(_rounds)
	print("  ── %d 局平均：对局 %.1f s｜平均 r/R %.3f｜外圈占比 %.0f%%｜后/前 %.2f｜接触 %.0f 次｜撞墙 %.0f 次"
			% [_rounds, sum_dur / n, sum_all / n, sum_outer / n * 100.0,
					sum_late_over_early / n, sum_contacts / n, sum_wall / n])
	main.free()
	quit(0)


## 跑完整一局，返回统计量
func _one_match(mm: TopsMain) -> Dictionary:
	mm._reset()
	await process_frame
	mm.start_game()
	for i in 5:
		await physics_frame
	mm._launch(0.8)

	Engine.physics_ticks_per_second = SIM_TICKS
	Engine.time_scale = SIM_SPEEDUP

	var tops: Array[TopTop] = []
	for c in mm.get_children():
		if c is TopTop:
			tops.append(c as TopTop)

	var sum_u := 0.0
	var n_u := 0
	var n_outer := 0
	var sum_early := 0.0
	var n_early := 0
	var sum_late := 0.0
	var n_late := 0
	# 接触次数要按增量累加：陀螺退场后会被 queue_free，最后再读就读不到了
	var prev_contacts: Dictionary = {}
	var contacts := 0
	var prev_wall: Dictionary = {}
	var wall_hits := 0

	var guard := 0
	while guard < MAX_GUARD and mm._phase != TopsMain.Phase.RESULT:
		await physics_frame
		guard += 1
		for t in tops:
			# 出局的陀螺退场播完会被 queue_free —— 只读还活着的
			if not is_instance_valid(t) or not t.alive:
				continue
			var c: int = t.contacts
			var prev: int = int(prev_contacts.get(t.top_id, 0))
			if c > prev:
				contacts += c - prev
			prev_contacts[t.top_id] = c
			var w: int = t.wall_hits
			var pw: int = int(prev_wall.get(t.top_id, 0))
			if w > pw:
				wall_hits += w - pw
			prev_wall[t.top_id] = w
			var u: float = t.plane_pos().distance_to(Vector2.ZERO) \
					/ maxf(mm._arena_radius, 1.0)
			sum_u += u
			n_u += 1
			if u > OUTER_U:
				n_outer += 1
			if mm._elapsed < SPLIT_T:
				sum_early += u
				n_early += 1
			else:
				sum_late += u
				n_late += 1

	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60

	var mean_u: float = sum_u / maxf(float(n_u), 1.0)
	var outer_ratio: float = float(n_outer) / maxf(float(n_u), 1.0)
	var early: float = sum_early / maxf(float(n_early), 1.0)
	var late: float = sum_late / maxf(float(n_late), 1.0)
	var loe: float = late / maxf(early, 1e-6)
	return {
		"dur": mm._elapsed, "mean_u": mean_u, "outer_ratio": outer_ratio,
		"late_over_early": loe, "contacts": contacts, "wall_hits": wall_hits,
	}
