extends SceneTree
##
## 胜率体检：5 人混战里，玩家（top_id = 1）的理论胜率应该只有 ~20%、平均名次 ~3.0。
## 显著偏高 = 有系统性偏差，不是运气好。
##
## 跑法：--headless --path D:/Tops3D --script res://tests/tops_winrate_check.gd
##
## 同时分身份统计撞墙 / 接触 / 存活时长，用来定位偏差从哪来：
##   · 玩家进场后 thrusting 恒 false，只有漂移（drive_accel = accel×0.16）
##   · AI 每帧 thrusting + 全力推进（drive_accel ≈ accel×1.0）
## 而碰撞里 N_press = m_red·a_n 正比于 drive_accel 差 → 推进越猛，对磨掉转速越狠。
##

const ROUNDS := 20
const TICKS := 960      # 960 tick/s × 16 倍速 = 每秒实时推进 16 s 游戏时间，且每步仍是 1/60 s
const SPEEDUP := 16.0


func _initialize() -> void:
	Engine.physics_ticks_per_second = 60
	var scene := load("res://tops/tops_main.tscn")
	var mm: TopsMain = scene.instantiate()
	root.add_child(mm)
	await process_frame

	var places := {}      # top_id -> Array[名次]
	var wins := {}
	var life := {}        # top_id -> Array[存活时长]
	var walls := {}
	var contacts := {}
	var spin_end := {}
	for i in 5:
		var id: int = i + 1
		places[id] = []
		wins[id] = 0
		life[id] = []
		walls[id] = []
		contacts[id] = []
		spin_end[id] = []

	print("════════ 胜率体检 · %d 局 ════════" % ROUNDS)
	for r in ROUNDS:
		var order: Array[int] = []
		var death_at := {}
		var tops: Array[TopTop] = []
		for c in mm.get_children():
			if c is TopTop:
				var t := c as TopTop
				tops.append(t)
				# 用信号自带的参数，别在 lambda 里捕获循环变量
				t.died.connect(func(tt: TopTop) -> void:
					order.append(tt.top_id)
					death_at[tt.top_id] = mm._elapsed)

		mm.start_game()
		for _i in 5:
			await physics_frame
		# ⚠ 关键对照：玩家的发射方向与力度**跟 AI 用同一套随机分布**。
		# 否则测出来的「玩家弱」可能只是「固定朝圆心 + 固定 0.8 力度」这个策略本身差，
		# 而不是系统偏心。要验的是对称性，就得把策略这个变量先消掉。
		var to_c: Vector2 = (TopsMain.CENTER - mm._player.plane_pos()).normalized()
		mm._aim_dir = to_c.rotated(randf_range(-1.2, 1.2))
		mm._launch(randf_range(0.55, 1.0))

		Engine.physics_ticks_per_second = TICKS
		Engine.time_scale = SPEEDUP
		var guard := 0
		while guard < 20000 and mm._phase != TopsMain.Phase.RESULT:
			await physics_frame
			guard += 1
		Engine.time_scale = 1.0
		Engine.physics_ticks_per_second = 60
		await process_frame

		# 名次：没死的第 1，之后按死亡顺序倒推 2、3、4、5
		var place_of := {}
		for t in tops:
			if not is_instance_valid(t):
				continue
			(walls[t.top_id] as Array).append(t.wall_hits)
			(contacts[t.top_id] as Array).append(t.contacts)
			(spin_end[t.top_id] as Array).append(t.spin)
			if t.alive:
				place_of[t.top_id] = 1
				death_at[t.top_id] = mm._elapsed
		var p := 2
		for k in range(order.size() - 1, -1, -1):
			place_of[order[k]] = p
			p += 1

		var line := "  第%2d局 %5.1fs │" % [r + 1, mm._elapsed]
		for id in 5:
			var pid: int = id + 1
			if not place_of.has(pid):
				continue
			(places[pid] as Array).append(int(place_of[pid]))
			(life[pid] as Array).append(float(death_at.get(pid, mm._elapsed)))
			if int(place_of[pid]) == 1:
				wins[pid] = int(wins[pid]) + 1
			line += " %d号:%d名" % [pid, int(place_of[pid])]
		print(line)

		mm._reset()
		await process_frame

	print("")
	print("── 汇总（理论：胜率 20%%，平均名次 3.00）──")
	print("  陀螺      胜率    平均名次   平均存活   平均撞墙   平均接触   终局转速")
	var names := {1: "玩家·BAL", 2: "AI·DART ", 3: "AI·RAM  ", 4: "AI·DART ", 5: "AI·BAL  "}
	for id in 5:
		var pid: int = id + 1
		var pl: Array = places[pid]
		if pl.is_empty():
			continue
		var wr: float = float(wins[pid]) / float(pl.size()) * 100.0
		print("  %s   %5.0f%%    %6.2f     %6.1f s    %6.1f     %6.1f     %6.1f"
				% [names[pid], wr, _mean(pl), _mean(life[pid]),
						_mean(walls[pid]), _mean(contacts[pid]), _mean(spin_end[pid])])

	# 玩家 vs AI 全体
	var pl1: Array = places[1]
	var ai_wins := 0
	var ai_places := []
	for id in 5:
		var pid: int = id + 1
		if pid == 1:
			continue
		ai_wins += int(wins[pid])
		for v in (places[pid] as Array):
			ai_places.append(v)
	print("")
	print("  玩家胜率 %.0f%%（%d/%d）｜AI 合计胜率 %.0f%%（%d/%d）"
			% [float(wins[1]) / float(pl1.size()) * 100.0, wins[1], pl1.size(),
					float(ai_wins) / float(ai_places.size()) * 100.0, ai_wins, ai_places.size()])
	print("  玩家平均名次 %.2f｜AI 平均名次 %.2f"
			% [_mean(pl1), _mean(ai_places)])
	mm.free()
	quit(0)


func _mean(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += float(v)
	return s / float(a.size())
