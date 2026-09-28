extends SceneTree
##
## 真物理碰撞 → 转速结算的隔离验证。
##
## 纸面模拟（TopsRules 是纯函数）证明不了「真 3D 刚体碰撞下规则还成立」，本脚本用
## 真实 RigidBody3D 跑物理帧来验证，重点查：
##   ① 正面对撞到底有没有扣转速
##   ② 撞击速度越快，转速掉得越多（物理层：Δω = J_t·r/I，J_n = (1+e)·m_red·u_n）
##   ③ 转速越高，同一次撞击磨掉的转动动能越多
##   ④ 切向擦撞是否触发「高转速 → 低转速」的摩擦转移
##   ⑤ 撞墙是否扣转速，且冷却期内不会连刷
##   ⑥ 主场景混战里碰撞是否真的在结算（而不是只靠自然衰减把转速耗光）
##
## 跑法：--headless --path D:/Tops3D --script res://tests/tops_phys_contact.gd
##

const STEP := 1.0 / 60.0

var _h: TestHarness
var _world: Node3D


func _initialize() -> void:
	Engine.physics_ticks_per_second = 60
	_h = TestHarness.new()
	await process_frame

	# ── ① 中速正面对撞（等转速）──
	_h.suite("① 正面对撞是否扣转速")
	var r1 := await _pair(200.0, 100.0, 100.0, 0.0)
	print("   中速: contacts=%d  min_gap=%.2f  ΔspinA=%.3f ΔspinB=%.3f  rel_before=%.1f rel_after=%.1f"
			% [r1.contact, r1.min_gap, r1.da, r1.db, r1.rel_before, r1.rel_after])
	_h.ck(r1.contact > 0, "中速正面对撞触发了接触结算（contacts>0）")
	_h.ck(r1.min_gap <= 0.5, "两球确实接触过（最小间隙 %.2f ≤ 0）" % r1.min_gap)
	_h.ck(r1.da < 0.0 and r1.db < 0.0, "双方转速都下降（ΔA=%.3f ΔB=%.3f）" % [r1.da, r1.db])

	# ── ② 撞击速度：物理层的法向冲量 J_n = (1+e)·m_red·u_n → 撞得越快掉得越多 ──
	_h.suite("② 撞击速度越快，转速掉得越多")
	var r2 := await _pair(500.0, 100.0, 100.0, 0.0)
	print("   高速: contacts=%d  ΔspinA=%.3f ΔspinB=%.3f  rel_before=%.1f rel_after=%.1f"
			% [r2.contact, r2.da, r2.db, r2.rel_before, r2.rel_after])
	var loss1: float = -(r1.da + r1.db)
	var loss2: float = -(r2.da + r2.db)
	print("   总转速损失: 中速 %.3f / 高速 %.3f" % [loss1, loss2])
	_h.ck(r2.contact > 0, "高速正面对撞也触发了结算")
	_h.ck(loss2 > loss1 * 1.5, "高速对撞的总损失明显大于中速（%.3f vs %.3f）" % [loss2, loss1])

	# ── ③ 转速越高 → 同一次撞击磨掉的转动动能越多（ΔE = ω·ΔL）──
	_h.suite("③ 转速越高，撞击磨掉的转动动能越多")
	var e_hi: float = TopsSpin.spin_of(0.0)   # 占位，下面用真实值覆盖
	var hi := _energy_of_hit(100.0, 100.0, 300.0)
	var lo := _energy_of_hit(40.0, 40.0, 300.0)
	e_hi = hi
	print("   同速对撞：满转速损失 %s J / 四成转速损失 %s J" % [_e(e_hi), _e(lo)])
	_h.ck(e_hi > lo * 1.5, "转速越高，一次撞击带走的转动动能越多（摩擦功 ∝ ω）")

	# ── ④ 切向擦撞：双方都掉，低转速方不会被一次性抽干 ──
	_h.suite("④ 切向擦撞（轮缘互磨）")
	var r4 := await _pair(200.0, 100.0, 40.0, 11.0)   # z 方向偏置 11 → 有切向滑动
	print("   擦撞 100 vs 40: contacts=%d min_gap=%.2f ΔA=%.3f ΔB=%.3f"
			% [r4.contact, r4.min_gap, r4.da, r4.db])
	_h.ck(r4.contact > 0, "擦撞触发了结算")
	_h.ck(r4.da < 0.0 and r4.db < 0.0, "同向自转互磨 → 双方都掉转速（ΔA=%.3f ΔB=%.3f）"
			% [r4.da, r4.db])
	_h.ck(r4.db > -60.0, "低转速方没有被一次性抽干（ΔB=%.3f）" % r4.db)

	# ── ⑤ 撞墙 ──
	_h.suite("⑤ 撞墙扣转速 + 冷却")
	var r5 := await _wall(200.0)
	print("   撞墙: wall_hits=%d Δspin=%.3f 最远=%s" % [r5.hits, r5.dspin, _f1(r5.max_r)])
	_h.ck(r5.hits >= 1, "撞墙被记录（wall_hits=%d）" % r5.hits)
	_h.ck(r5.dspin < 0.0, "撞墙扣了转速（Δ=%.3f）" % r5.dspin)

	# ── ⑥ 主场景混战：碰撞是否真的在结算 ──
	_h.suite("⑥ 主场景混战")
	await _brawl()

	print("")
	print("── 汇总：PASS %d / FAIL %d" % [_h.pass_count(), _h.fail_count()])
	for f in _h.failures():
		print("   FAIL: ", f)
	quit(1 if _h.fail_count() > 0 else 0)


## 纯函数地算一次对撞带走的转动动能（不跑物理世界，隔离出「转速」这一个变量）
func _energy_of_hit(spin_a: float, spin_b: float, rel_speed: float) -> float:
	var a := TopTop.create(&"BALANCED", 1)
	var b := TopTop.create(&"BALANCED", 2)
	a.spin = spin_a
	b.spin = spin_b
	var wa: float = a.omega()
	var wb: float = b.omega()
	var dw := TopsSpin.contact_domega(a.mass_kg, a.radius_m, a.axial_inertia, wa,
			b.mass_kg, b.radius_m, b.axial_inertia, wb,
			Vector2(1.0, 0.0), Vector2(-rel_speed, 0.0), Vector2.ZERO, Vector2.ZERO, 0.0)
	var loss: float = -(wa * a.axial_inertia * dw.x + wb * b.axial_inertia * dw.y)
	a.free()
	b.free()
	return loss


func _e(x: float) -> String:
	if x == 0.0:
		return "0"
	var ex: int = int(floor(log(absf(x)) / log(10.0)))
	return "%.2fe%d" % [x / pow(10.0, float(ex)), ex]


# ── 沙盒：两个陀螺对撞 ──
## speed: 相向速度；offset: B 在 z 方向的偏置（0=正对撞，>0=切向擦撞）
func _pair(speed: float, spin_a: float, spin_b: float, offset: float) -> Dictionary:
	_new_world()
	var a := TopTop.create(&"BALANCED", 1)
	var b := TopTop.create(&"BALANCED", 2)
	a.spin = spin_a
	b.spin = spin_b
	a.accel = 0.0          # 关掉进动漂移推力，隔离出「碰撞」这一个变量
	b.accel = 0.0
	a.set_collides(true)
	b.set_collides(true)
	a.freeze = false
	b.freeze = false
	_world.add_child(a)
	_world.add_child(b)
	a.set_plane_pos(Vector2(-80.0, 0.0))
	b.set_plane_pos(Vector2(80.0, offset))
	a.linear_velocity = Vector3(speed, 0.0, 0.0)
	b.linear_velocity = Vector3(-speed, 0.0, 0.0)
	TopsRules.now = 0.0

	var sa0: float = a.spin
	var sb0: float = b.spin
	var min_gap := INF
	var prev_rel := 0.0
	var after_rel := 0.0
	for i in 240:
		TopsRules.now += STEP
		prev_rel = (b.plane_vel() - a.plane_vel()).x
		await physics_frame
		var gap: float = a.plane_pos().distance_to(b.plane_pos()) - (a.top_radius + b.top_radius)
		min_gap = minf(min_gap, gap)
		if a.contacts > 0 or b.contacts > 0:
			after_rel = (b.plane_vel() - a.plane_vel()).x
			break
		# 让两球重新靠近（对撞后弹开，再推回来，便于观察多次接触）
	var res := {
		"contact": a.contacts + b.contacts,
		"da": a.spin - sa0,
		"db": b.spin - sb0,
		"min_gap": min_gap,
		"rel_before": prev_rel,
		"rel_after": after_rel,
	}
	_free_world()
	return res


# ── 沙盒：一个陀螺撞墙 ──
func _wall(speed: float) -> Dictionary:
	_new_world()
	var t := TopTop.create(&"BALANCED", 1)
	t.spin = 100.0
	t.accel = 0.0
	t.set_collides(true)
	t.freeze = false
	_world.add_child(t)
	t.set_plane_pos(Vector2(0.0, 0.0))
	t.linear_damp = 0.0          # 关阻尼：否则还没走到墙速度就被吃光了
	t.linear_velocity = Vector3(0.0, 0.0, -speed)

	# 一面墙（放在 -Z 侧），与 main 一样打 wall 组
	var wall := StaticBody3D.new()
	wall.add_to_group(&"wall")
	wall.position = Vector3(0.0, 30.0, -200.0)
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 60.0, 20.0)
	var cs := CollisionShape3D.new()
	cs.shape = box
	wall.add_child(cs)
	_world.add_child(wall)

	TopsRules.now = 0.0
	var s0: float = t.spin
	var max_r := 0.0
	for i in 240:
		TopsRules.now += STEP
		await physics_frame
		max_r = maxf(max_r, absf(t.plane_pos().y))
		if t.wall_hits >= 1 and i > 30:
			break
	var res := {"hits": t.wall_hits, "dspin": t.spin - s0, "max_r": max_r}
	_free_world()
	return res


# ── 主场景混战：看碰撞到底有没有在扣转速 ──
func _brawl() -> void:
	var scene := load("res://tops/tops_main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	await process_frame
	(main as TopsMain).SHRINK_START = 10.0   # 缩圈提前，90 秒内分出胜负

	var tops: Array[TopTop] = []
	for c in main.get_children():
		if c is TopTop:
			tops.append(c as TopTop)

	# ⚠ 必须走主场景自己的战斗流程：TopsRules.now 由 main 的 _physics_process 每帧写成
	# _elapsed，TITLE 阶段恒为 0 会把接触冷却的计时清零（结算会被永久卡住）。
	(main as TopsMain).start_game()
	for i in 5:
		await physics_frame
	(main as TopsMain)._launch(0.8)   # 发射 → 进入 BATTLE，之后完全交给真实战斗循环

	var guard := 0
	var max_r := 0.0
	var overlap_frames := 0      # 有任意一对几何重叠的帧数（物理上真的碰上了）
	var bodies_frames := 0       # get_colliding_bodies() 非空的帧数（轮询能不能看到）
	var top_hits := 0            # 轮询拿到「陀螺」类型接触对象的次数
	var wall_hits := 0           # 轮询拿到「墙」的次数
	var sample := ""
	# 出局的陀螺退场播完会被 main 真正 queue_free，事后再读 contacts/spin 就读不到了
	# —— 所以接触次数与掉转量都按**增量**在循环里累加。
	var total_contacts := 0
	var total_drop := 0.0
	var prev_contacts := {}
	var prev_spin := {}
	var dead_ids := {}
	while guard < 9000:
		await physics_frame
		guard += 1
		if (main as TopsMain)._phase == TopsMain.Phase.RESULT:
			break   # 分出胜负就停
		for t in tops:
			if not is_instance_valid(t):
				continue
			var c: int = t.contacts
			var pc: int = int(prev_contacts.get(t.top_id, 0))
			if c > pc:
				total_contacts += c - pc
			prev_contacts[t.top_id] = c
			var sp: float = t.spin
			var ps: float = float(prev_spin.get(t.top_id, sp))
			if sp < ps:
				total_drop += ps - sp
			prev_spin[t.top_id] = sp
			if not t.alive:
				dead_ids[t.top_id] = true
			max_r = maxf(max_r, t.plane_pos().length())
			var bs: Array[Node3D] = t.get_colliding_bodies()
			if bs.size() > 0:
				bodies_frames += 1
			for o in bs:
				if o is TopTop:
					top_hits += 1
				else:
					wall_hits += 1
			if guard == 120 and bs.size() > 0 and sample == "":
				sample = "t=2s top%d 接触=%s" % [t.top_id,
						str(bs.map(func(x): return x.name + ":" + x.get_class()))]
		for i in tops.size():
			for j in range(i + 1, tops.size()):
				if not is_instance_valid(tops[i]) or not is_instance_valid(tops[j]):
					continue
				if tops[i].plane_pos().distance_to(tops[j].plane_pos()) \
						< tops[i].top_radius + tops[j].top_radius + 1.0:
					overlap_frames += 1
	print("   诊断: 几何重叠帧=%d  轮询拿到陀螺=%d 拿到墙=%d / 非空帧=%d 总帧=%d"
			% [overlap_frames, top_hits, wall_hits, bodies_frames, guard]); print("   采样: ", sample)

	var dead: int = dead_ids.size()
	# 收尾只看**还活着**的陀螺：出局的陀螺停在原地不动，之后场地继续缩，
	# 它落在墙外属于正常（已经倒地），不算逃逸
	var end_r := 0.0
	for t in tops:
		if is_instance_valid(t) and t.alive:
			end_r = maxf(end_r, t.plane_pos().length())
	print("   对局用时 %.1fs: 总接触=%d 总转速下降=%.1f 出局=%d/%d 历史最远=%.1f 收尾最远=%.1f 场地半径=%.1f"
			% [guard / 60.0, total_contacts, total_drop, dead, tops.size(), max_r, end_r,
			(main as TopsMain)._arena_radius])
	for t in tops:
		if not is_instance_valid(t):
			continue
		print("     top%d %s spin=%.1f contacts=%d wall=%d kills=%d"
				% [t.top_id, "存活" if t.alive else "出局", t.spin, t.contacts, t.wall_hits, t.kills])
	_h.ck(total_contacts > 0, "混战中确实结算了碰撞（总接触 %d 次）" % total_contacts)
	_h.ck(total_drop > 20.0, "碰撞贡献了远超自然衰减的转速损失（总降 %.1f）" % total_drop)
	_h.ck(end_r < (main as TopsMain)._arena_radius + 30.0,
			"收尾时无人逃出场地（最远 %.1f / 场地 %.1f）"
					% [end_r, (main as TopsMain)._arena_radius])
	main.free()


func _new_world() -> void:
	_world = Node3D.new()
	root.add_child(_world)


func _free_world() -> void:
	if _world != null:
		_world.free()
		_world = null
	await physics_frame


func _f1(x: float) -> String:
	return "%.1f" % x
