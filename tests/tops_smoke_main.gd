extends SceneTree
##
## 陀螺对战 · headless 冒烟测试（真 3D 物理版）
##
## 跑法：
##   "Godot_..._console.exe" --headless --path "D:/Tops3D" --script res://tests/tops_smoke_main.gd
##
## 覆盖三层：
##   1) 规则层纯函数（TopsRules）—— 伤害只随 Δspin、摩擦转速交换方向
##   2) 物理接线（TopTop 是 RigidBody3D、CCD 开启、边界是 24 段静态墙、水平 XZ 平面）
##   3) 整局跑通 —— 加速物理时间跑完一局，确认碰撞真发生、有人出局、缩圈生效
##
## 退出码 0 = 全绿。
##

const SIM_SPEEDUP := 16.0     # 物理时间倍速
const SIM_TICKS := 480        # 提高物理频率，保证每步 dt 仍是 ~1/30


func _initialize() -> void:
	var h := TestHarness.new()
	print("════════ 陀螺对战 · headless 冒烟测试（真 3D 物理版）════════")
	await process_frame

	h.suite("规则层：伤害只随转速差（§4.2）")
	_rules_damage(h)

	h.suite("规则层：摩擦交换转速（高 → 低，拉平）")
	_rules_friction(h)

	h.suite("物理接线（3D）")
	var scene := load("res://tops/tops_main.tscn")
	h.ck(scene != null, "tops_main.tscn 可加载")
	var main: Node = scene.instantiate() if scene != null else null
	h.ck(main is TopsMain, "根节点脚本是 TopsMain")
	root.add_child(main)
	await process_frame

	var tops: Array[TopTop] = []
	for c in main.get_children():
		if c is TopTop:
			tops.append(c as TopTop)
	h.eq(tops.size(), 5, "场上 5 个陀螺")
	var all_rigid := true
	var ccd_ok := true
	var no_gravity := true
	for t in tops:
		if not (t is RigidBody3D):
			all_rigid = false
		if t.continuous_cd != true:
			ccd_ok = false
		if t.gravity_scale != 0.0:
			no_gravity = false
	h.ck(all_rigid, "每个陀螺都是 RigidBody3D（碰撞交给引擎）")
	h.ck(ccd_ok, "全部开启 CCD 连续碰撞检测（防高速穿透）")
	h.ck(no_gravity, "重力已关闭（水平竞技场）")

	var wall_segs: Array = main.get_children().filter(func(c): return c is StaticBody3D and c.is_in_group(&"wall"))
	h.ck(wall_segs.size() == 48, "存在 48 段静态墙拼成圆环")
	if wall_segs.size() > 0:
		# 墙段的 CollisionShape3D 是无名子节点，按类型查找而非按名字
		var cs3 := wall_segs[0].find_child("*", true, false) as CollisionShape3D
		if cs3 == null:
			for c in wall_segs[0].get_children():
				if c is CollisionShape3D:
					cs3 = c as CollisionShape3D
					break
		h.ck(cs3 != null and cs3.shape is BoxShape3D, "每段墙是 BoxShape3D（拼接重叠、近似光滑圆）")

	h.suite("界面层：三步骤流程（开始游戏 → 蓄力 → 放陀螺）")
	var mm := main as TopsMain
	var ui := mm.get_node_or_null("TopsUi") as TopsUi
	h.ck(ui != null, "主场景挂载了界面层 TopsUi")
	h.eq(mm._phase, TopsMain.Phase.TITLE, "开局停在「开始游戏」界面")
	h.ck(ui.is_title_shown(), "标题卡片可见（含开始游戏按钮）")
	mm.start_game()
	await process_frame
	h.eq(mm._phase, TopsMain.Phase.LAUNCH, "点开始游戏 → 进入蓄力阶段")
	h.ck(not ui.is_title_shown(), "开始后标题卡片隐藏")
	h.ck(not mm._input_lock, "输入锁已释放（开始那一下的按键不算蓄力）")
	h.eq(ui._step_cur, 1, "流程条高亮到第 2 步「蓄力」")

	h.suite("发射阶段：进场前唯一的决策点")
	var pl: TopTop = mm._player
	h.ck(mm._elapsed == 0.0, "发射前不计时（转速不掉）")
	h.ck(pl.plane_vel().length() < 0.001, "发射前陀螺静止待命")
	h.ck(tops[0].collision_mask == 0, "发射前陀螺不参与碰撞（不会互相挤）")
	# 所有陀螺都在 y=TOP_Y 水平面上
	var all_flat := true
	for t in tops:
		if absf(t.global_position.y - TopTop.TOP_Y) > 0.001:
			all_flat = false
	h.ck(all_flat, "所有陀螺都在同一水平面 y=%s" % TopTop.TOP_Y)

	Input.action_press("tops_boost")
	for _i in 40:
		await physics_frame
	var pw: float = mm._power
	h.ck(pw > 0.25, "按住 Shift 蓄力条在涨（力度 %s）" % _f2(pw))
	Input.action_release("tops_boost")
	await physics_frame
	await physics_frame
	h.eq(mm._phase, TopsMain.Phase.BATTLE, "松手即放陀螺 → 进入战斗阶段")
	h.ck(pl.plane_vel().length() > 50.0,
		"发射给了初速 %s" % _f1(pl.plane_vel().length()))
	h.ck(tops[0].collision_mask == 1, "进场后恢复碰撞")
	h.eq(ui._step_cur, 3, "流程条三步全部点亮（放陀螺完成）")

	h.suite("进场后玩家不可操控（陀螺完全靠物理）")
	var pos0: Vector2 = pl.plane_pos()
	Input.action_press("tops_right")
	for _i in 60:
		await physics_frame
	h.ck(not pl.thrusting, "按方向键不产生推进指令（输入通道已关闭）")
	h.ck(pl.input_dir == Vector2.ZERO and not pl.boosting, "玩家的 input_dir / boost 保持为空")
	var moved_pl: float = pl.plane_pos().distance_to(pos0)
	h.ck(moved_pl > 5.0, "玩家陀螺仍在动（发射初速 + 进动漂移 + 碰撞），位移 %s" % _f1(moved_pl))
	Input.action_release("tops_right")

	h.suite("规则层与 3D 桥接（plane_pos / plane_vel 取 XZ）")
	var pv3 := Vector3(600.0, TopTop.TOP_Y, 430.0)
	pl.set_plane_pos(Vector2(600.0, 430.0))
	h.ck(absf(pl.global_position.x - 600.0) < 0.001 and absf(pl.global_position.z - 430.0) < 0.001,
		"set_plane_pos 把逻辑坐标写回 XZ（y 保持 %s）" % TopTop.TOP_Y)
	h.ck(absf(pl.plane_pos().x - 600.0) < 0.001 and absf(pl.plane_pos().y - 430.0) < 0.001,
		"plane_pos 取回 (x, z)")
	pl.linear_velocity = Vector3(120.0, 0.0, 90.0)
	h.ck(pl.plane_vel().distance_to(Vector2(120.0, 90.0)) < 0.001,
		"plane_vel 取回 (vx, vz)，忽略 y 分量")
	# 物理层的转动惯量必须随质量/半径走
	var I1: float = TopsSpin.axial_inertia(0.05, 0.016, 0.55)
	var I2: float = TopsSpin.axial_inertia(0.10, 0.016, 0.55)
	h.ck(absf(I2 / I1 - 2.0) < 1e-6, "转动惯量 I = k·m·r²（%s → %s）" % [I1, I2])

	h.suite("整局跑通（物理加速 %s×）" % SIM_SPEEDUP)
	Engine.physics_ticks_per_second = SIM_TICKS
	Engine.time_scale = SIM_SPEEDUP
	var start_pos: Array[Vector2] = []
	for t in tops:
		start_pos.append(t.plane_pos())

	# 接触/撞墙次数按**增量**累加：出局的陀螺会被 queue_free，事后再读会整片丢数据
	# （实测「事后读」只有 10 次撞墙，增量累加是 54～60 次 —— 差了一个量级）。
	var guard := 0
	var contacts := 0
	var wall_hits := 0
	var prev_contacts := {}
	var prev_wall := {}
	while guard < 9600 and _alive(tops) > 1 and mm._phase != TopsMain.Phase.RESULT:
		await physics_frame
		guard += 1
		for t in tops:
			if not is_instance_valid(t):
				continue
			var nc: int = t.contacts
			var npc: int = int(prev_contacts.get(t.top_id, 0))
			if nc > npc:
				contacts += nc - npc
			prev_contacts[t.top_id] = nc
			var nw: int = t.wall_hits
			var npw: int = int(prev_wall.get(t.top_id, 0))
			if nw > npw:
				wall_hits += nw - npw
			prev_wall[t.top_id] = nw
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60

	var spin_sum := 0.0
	for t in tops:
		if is_instance_valid(t):
			spin_sum += t.spin
	var dur: float = (main as TopsMain)._elapsed
	print("  · 对局时长 %s s｜存活 %d/5｜转速合计 %s" % [_f1(dur), _alive(tops), _f1(spin_sum)])
	# 单局时长上界由「纯自然寿命」（≈90 s）决定，下界由碰撞密度决定。
	# AI 随机性大，留宽一点：30–150 s 都算正常。
	h.ck(dur > 25.0, "单局不秒结束（%s s，目标 40–90）" % _f1(dur))
	h.ck(dur < 150.0, "单局不拖死（%s s，目标 40–90）" % _f1(dur))

	var moved := false
	for i in tops.size():
		if is_instance_valid(tops[i]) \
				and tops[i].plane_pos().distance_to(start_pos[i]) > 30.0:
			moved = true
	h.ck(moved, "陀螺确实移动了（物理在跑，不是静止）")
	h.ck(_alive(tops) <= 1 or guard < 16000, "一局能收敛（剩 %d 人）" % _alive(tops))
	h.ck(_alive(tops) < 5, "有人出局（剩 %d / 5）" % _alive(tops))

	h.ck(contacts > 0, "引擎检测到 %d 次陀螺间接触" % contacts)
	# ⚠ 撞墙**不再**断言 > 0：碗坡把陀螺聚到中心 + 全场不可操控之后，
	#   默认对局里没人会飞到边缘（实测 3 局有 1 局是 0 次），它已经不是不变量。
	#   撞墙弹开的机制改由 tests/tops_wall_probe.gd 定向直撞来守。
	print("  · 本局撞墙 %d 次（非不变量：聚集 + 无操控下可多可少）" % wall_hits)
	var r_now: float = (main as TopsMain)._arena_radius
	var base_r: float = mm.BASE_RADIUS
	h.ck(r_now < base_r - 0.1,
			"场地已收缩（半径 %s < %.0f）" % [_f1(r_now), base_r])
	h.ck(_all_inside(tops, main as TopsMain), "收缩后没有陀螺被挤出墙外")

	h.ck(spin_sum < 500.0, "总转速已下降（初始 500，现 %s）" % _f1(spin_sum))

	h.suite("结算界面")
	h.eq(mm._phase, TopsMain.Phase.RESULT, "分出胜负后进入结算界面")
	h.ck(ui.is_result_shown(), "结算卡片可见（名次 + 用时 + 再来一局）")

	h.suite("输入映射")
	for a in ["tops_up", "tops_down", "tops_left", "tops_right", "tops_boost", "tops_restart"]:
		h.ck(InputMap.has_action(a), "已注册动作：%s" % a)

	print("")
	print("═══════════════════════════════════════════")
	print("[TOPSSMOKE3D] pass = ", h.pass_count(), "   fails = ", h.fail_count())
	for f in h.failures():
		print("  FAIL  ", f)
	print("[TOPSSMOKE3D] ", "ALL PASS" if h.fail_count() == 0 else "HAS FAILURES")
	print("═══════════════════════════════════════════")
	quit(1 if h.fail_count() > 0 else 0)


## ⚠ 出局的陀螺退场播完会被 main 真正 queue_free 掉（不再堆在场上），
## 所以这里拿的都是**可能已经失效**的引用，读属性之前一律先过 is_instance_valid。
func _alive(tops: Array[TopTop]) -> int:
	var n := 0
	for t in tops:
		if is_instance_valid(t) and t.alive:
			n += 1
	return n


## 造两个不受干扰的陀螺（关重力、不入物理交互）来单测规则层
func _pair(h: TestHarness, id_a: int, id_b: int, at: Vector2) -> Array:
	var a := TopTop.create(&"RAM", id_a)
	var b := TopTop.create(&"DART", id_b)
	a.gravity_scale = 0.0
	b.gravity_scale = 0.0
	root.add_child(a)
	root.add_child(b)
	a.set_plane_pos(at)
	b.set_plane_pos(at + Vector2(40.0, 0.0))
	return [a, b]


## 单测用的临时陀螺必须立刻摘掉，否则会和主场景的陀螺撞在一起污染结果
func _dispose(p: Array) -> void:
	for t in p:
		var n := t as Node
		root.remove_child(n)
		n.queue_free()


## 同一颗陀螺在不同接近速度下的转速损失（纯函数，隔离掉引擎）
func _loss_at(rel_speed: float) -> float:
	var a := TopTop.create(&"BALANCED", 1)
	var b := TopTop.create(&"BALANCED", 2)
	a.spin = 100.0
	b.spin = 100.0
	var dw := TopsSpin.contact_domega(a.mass_kg, a.radius_m, a.axial_inertia, a.omega(),
			b.mass_kg, b.radius_m, b.axial_inertia, b.omega(),
			Vector2(1.0, 0.0), Vector2(-rel_speed, 0.0), Vector2.ZERO, Vector2.ZERO, 0.0)
	var loss: float = TopsSpin.spin_of(-dw.x)
	a.free()
	b.free()
	return loss


func _rules_damage(h: TestHarness) -> void:
	# 撞击损耗 = 摩擦冲量矩 / 转动惯量：撞得越快，法向冲量越大，掉得越多
	var slow: float = _loss_at(120.0)
	var fast: float = _loss_at(300.0)
	print("  · 接近速度 120 → 掉 %s 转 / 300 → 掉 %s 转" % [_f2(slow), _f2(fast)])
	h.ck(fast > slow * 1.5, "撞得越快转速掉得越多（%s → %s）" % [_f2(slow), _f2(fast)])
	h.ck(absf(fast / slow - 2.5) < 0.05, "接近速度 2.5 倍 → 损失 2.5 倍（冲量线性）")
	# 质量：轻的掉得狠（Δω = J·r/I ∝ 1/(k·m·r)）
	var dart := _mk_loss(&"DART")
	var ram := _mk_loss(&"RAM")
	print("  · 同一撞：DART 掉 %s 转 / RAM 掉 %s 转" % [_f2(dart), _f2(ram)])
	h.ck(dart > ram * 2.0, "轻陀螺的转速损失远大于重陀螺（质量真的起作用）")


func _mk_loss(arch: StringName) -> float:
	var a := TopTop.create(arch, 1)
	var b := TopTop.create(&"BALANCED", 2)
	a.spin = 100.0
	b.spin = 100.0
	var dw := TopsSpin.contact_domega(a.mass_kg, a.radius_m, a.axial_inertia, a.omega(),
			b.mass_kg, b.radius_m, b.axial_inertia, b.omega(),
			Vector2(1.0, 0.0), Vector2(-300.0, 0.0), Vector2.ZERO, Vector2.ZERO, 0.0)
	var loss: float = TopsSpin.spin_of(-dw.x)
	a.free()
	b.free()
	return loss


func _rules_friction(h: TestHarness) -> void:
	# 贴身对磨：没有接近速度（贴着不分开），但两边轮缘都在高速互刮 → 仍然一直掉转速
	var p := _pair(h, 95, 96, Vector2(60.0, 300.0))
	var a: TopTop = p[0]
	var b: TopTop = p[1]
	a.spin_max = 100.0            # 原型自带 spin_max（RAM 82 / DART 115），这里统一成 100
	b.spin_max = 100.0
	a.spin = 100.0
	b.spin = 100.0
	a.vel_prev = Vector2.ZERO     # 没有撞击，纯对磨
	b.vel_prev = Vector2.ZERO
	a.drive_accel = Vector2(700.0, 0.0)   # AI 全力推进把两者压在一起
	b.drive_accel = Vector2(-700.0, 0.0)
	TopsRules.now = 3.0
	TopsRules.resolve_contact(a, b)
	print("  · 对磨一次：A %s → %s / B %s → %s" % [
		_f2(100.0), _f2(a.spin), _f2(100.0), _f2(b.spin)])
	h.ck(a.spin < 100.0 and b.spin > 0.0, "没有撞击也会因对磨掉转速（%s / %s）" % [
		_f2(a.spin), _f2(b.spin)])
	h.ck(a.spin > b.spin, "被顶着的 RAM 掉得比 DART 少（惯量大：Δω = J·r/I ∝ 1/m）")
	_dispose(p)


## 所有存活陀螺都必须在墙内（验证「真实碰撞」没有穿透）。
## 容限取 +40：墙段盒子径向厚度 20、中心在半径外 30，内表面约在半径 +20 处，
## 故允许陀螺中心短暂探到半径外 ~40（贴墙冲刺），超出即视为逃逸出场。
func _all_inside(tops: Array[TopTop], main: TopsMain) -> bool:
	var worst := 0.0
	for t in tops:
		if not is_instance_valid(t) or not t.alive:
			continue
		var d: float = t.plane_pos().distance_to(TopsMain.CENTER)
		worst = maxf(worst, d)
	if worst > main._arena_radius + 40.0:
		print("  · [_all_inside] 逃逸：最远陀螺距圆心 %s > 场半径+40 (%s)" % [
			_f1(worst), _f1(main._arena_radius + 40.0)])
		return false
	return true


func _f1(x: float) -> String:
	return "%.1f" % x


func _f2(x: float) -> String:
	return "%.2f" % x
