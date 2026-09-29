extends SceneTree
##
## 陀螺对战 · 「转速表」UI 校验（headless）
##
## 跑法：
##   "Godot_..._console.exe" --headless --path "D:/Tops3D" --script res://tests/tops_roster_check.gd
##
## 验的是 UI 上那张「全部陀螺真实转速」表：
##   1) 它显示的是**物理量** —— rpm 必须严格等于 ω·60/2π，ω = spin × 6 rad/s
##   2) 一局内行序固定：出局的陀螺**不移除**，只压暗置 0（列表不跳）
##   3) 已 queue_free 的对象读不到时不能崩，必须落回「已出局」
##
## 退出码 0 = 全绿。
##

const SIM_SPEEDUP := 16.0
const SIM_TICKS := 480


func _initialize() -> void:
	var h := TestHarness.new()
	print("════════ 陀螺对战 · 转速表 UI 校验 ════════")
	await process_frame

	var scene := load("res://tops/tops_main.tscn")
	var main: TopsMain = scene.instantiate()
	root.add_child(main)
	await process_frame
	var ui := main.get_node_or_null("TopsUi") as TopsUi
	h.ck(ui != null, "主场景挂载了界面层 TopsUi")

	h.suite("标题 / 蓄力：转速表的显隐")
	h.ck(not ui.is_roster_shown(), "标题界面不显示转速表（还没有对局）")
	main.start_game()
	await process_frame
	h.ck(ui.is_roster_shown(), "进入蓄力阶段后转速表可见")
	h.eq(ui.roster_rpms().size(), 5, "转速表有 5 行（一局 5 个陀螺，整局固定）")

	h.suite("数字对得上：rpm = ω·60/2π，ω = spin × 6")
	var rpms: Array = ui.roster_rpms()
	for i in rpms.size():
		var t: TopTop = main._roster[i]
		var want: float = t.omega() * 60.0 / TAU
		h.ck(absf(float(rpms[i]) - want) < 0.51,
				"第 %d 行 rpm 与真实角速度一致（%d vs %.1f）" % [i + 1, int(rpms[i]), want])
	# ⚠ 别再写死「满速 100 点 = 5730 rpm」：2026-09-28 起 spin_max 按原型分档
	#   （DART 105 / BALANCED 102 / RAM 88），这是三者互相制衡的**平衡砝码**——
	#   碰撞损耗 Δω = J_t/(k·m·r)，RAM 又重又大、挨打掉得少，就该用更少的初始转速换。
	#   抹平成 100 之后制衡消失，RAM 实测胜率 90%。所以满速 rpm 要用原型自带的 spin_max 反推，
	#   而「1 点 = 6 rad/s」这个标定常量单独钉死。
	var p0: TopTop = main._roster[0]
	var want0: float = p0.spin_max * TopsSpin.OMEGA_PER_SPIN * 60.0 / TAU
	h.ck(absf(float(rpms[0]) - want0) < 1.0,
			"玩家行满速 = spin_max(%d) × 6 rad/s ≈ %d rpm" % [int(p0.spin_max), int(roundf(want0))])
	h.ck(TopsSpin.OMEGA_PER_SPIN == 6.0, "标定常量未漂移：1 点转速 = 6 rad/s")

	# 防「抹平 spin_max」回归：一局里必须出现多个不同的转速上限
	var maxes: Array = []
	for t in main._roster:
		var sm: float = t.spin_max
		if not maxes.has(sm):
			maxes.append(sm)
	h.ck(maxes.size() >= 2, "原型转速上限未被抹平（本局有 %d 档：%s）" % [maxes.size(), str(maxes)])

	h.suite("电脑初始转速在区间内浮动（玩家仍是满速）")
	var lo: float = TopsMain.AI_SPIN_LO
	var hi: float = TopsMain.AI_SPIN_HI
	var in_range := 0
	var off_nominal := 0
	for i in main._roster.size():
		var t: TopTop = main._roster[i]
		var ratio: float = t.spin / t.spin_max
		if i == 0:   # 阵容第 0 位恒为玩家
			h.ck(absf(ratio - 1.0) < 1e-6, "玩家是满转速，不被随机浮动影响")
			continue
		if ratio >= lo - 1e-6 and ratio <= hi + 1e-6:
			in_range += 1
		if absf(ratio - 1.0) > 0.01:
			off_nominal += 1
		# spin_cap 必须等于初始转速：击杀回血按它封顶，否则高转速的那一颗
		# 一击杀就会被 minf 打回标称值，随机浮动等于白给。
		h.ck(absf(t.spin_cap - t.spin) < 1e-6,
				"对手 %d 的 spin_cap 跟着随机转速走（%.1f）" % [i + 1, t.spin_cap])
	h.eq(in_range, 4, "4 个电脑的初始转速都落在 [%.2f, %.2f] × spin_max 内" % [lo, hi])
	h.ck(off_nominal >= 2, "转速确实在浮动（%d/4 个偏离标称值）" % off_nominal)

	h.suite("战斗：转速实时下降，出局只置 0 不移除")
	Input.action_press("tops_boost")
	for _i in 30:
		await physics_frame
	Input.action_release("tops_boost")
	await physics_frame
	h.eq(main._phase, TopsMain.Phase.BATTLE, "已进场，进入战斗阶段")

	Engine.physics_ticks_per_second = SIM_TICKS
	Engine.time_scale = SIM_SPEEDUP
	var before: Array = ui.roster_rpms()
	var guard := 0
	var died_seen := 0
	while guard < 9600 and main._phase != TopsMain.Phase.RESULT:
		await physics_frame
		guard += 1
		# 中途采一次：要看到「有人在掉、有人已出局」而不是全员同步
		if guard == 1200:
			var mid: Array = ui.roster_rpms()
			var dropped := 0
			for i in mid.size():
				if float(mid[i]) < float(before[i]) - 1.0:
					dropped += 1
			h.ck(dropped >= 3, "战斗中 %d/5 行的转速确实在掉" % dropped)
			for i in mid.size():
				if float(mid[i]) <= 0.001:
					died_seen += 1
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	await process_frame

	h.eq(ui.roster_rpms().size(), 5, "对局结束转速表仍是 5 行（出局不摘行）")
	var alive_rows := 0
	var dead_rows := 0
	var final_rpms: Array = ui.roster_rpms()
	for i in final_rpms.size():
		var v: float = float(final_rpms[i])
		if v > 0.001:
			alive_rows += 1
		else:
			dead_rows += 1
	print("  · 终局：存活行 %d / 出局行 %d" % [alive_rows, dead_rows])
	h.ck(dead_rows >= 3, "出局的陀螺 rpm 归 0（%d 行）" % dead_rows)
	h.ck(alive_rows >= 1, "至少还有一行在转（胜者 %d 行）" % alive_rows)

	# 退场动画播完后对象会被 queue_free —— 此时再刷新不能抛错，必须落回 0
	var freed := 0
	for t in main._roster:
		if not is_instance_valid(t):
			freed += 1
	print("  · 已从场景释放的陀螺：%d / 5" % freed)
	h.ck(freed >= 1, "倒下的陀螺确实被清出场景（%d 个）" % freed)
	main._update_roster()
	ui.set_roster(main._roster_data)
	var after: Array = ui.roster_rpms()
	h.eq(after.size(), 5, "对象释放后刷新，行数不变")
	for i in after.size():
		if not is_instance_valid(main._roster[i]):
			h.ck(absf(float(after[i])) < 0.001, "已释放对象的行落回 0 rpm（第 %d 行）" % (i + 1))

	print("")
	print("═══════════════════════════════════════════")
	print("[TOPSROSTER] pass = ", h.pass_count(), "   fails = ", h.fail_count())
	for f in h.failures():
		print("  FAIL  ", f)
	print("[TOPSROSTER] ", "ALL PASS" if h.fail_count() == 0 else "HAS FAILURES")
	print("═══════════════════════════════════════════")
	quit(1 if h.fail_count() > 0 else 0)
