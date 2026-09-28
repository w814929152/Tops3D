extends SceneTree
##
## 转速损耗物理层（TopsSpin）的验证 —— 纯数值断言，不需要真物理世界。
##
## 查的是「公式有没有按物理走」，而不是手感：
##   ① 转动惯量 I = k·m·r²（∝ m、∝ r²）
##   ② 自然衰减：转速越高掉得越快（空气阻力 ω² 项）
##   ③ 轴尖干摩擦与质量**无关**（重的陀螺摩擦大、惯量也大，正好约掉）
##   ④ 撞击速度越快，转速损失越大（线性）
##   ⑤ 碰撞里质量起作用：轻的掉得远比重的狠
##   ⑥ 转动动能单调下降（摩擦只会耗散，不会凭空生能量）
##   ⑦ 反向自转 → 趋近齿轮啮合，慢的一方被带快
##   ⑧ 撞墙：接近速度越大，轮缘擦掉的转速越多
##   ⑨ 三种性格的纯自然寿命落在合理区间
##
## 跑法：--headless --path D:/Tops3D --script res://tests/tops_spin_physics.gd
##

const STEP := 1.0 / 60.0


func _initialize() -> void:
	var h := TestHarness.new()
	await process_frame
	TopsSpin.reset_tuning()

	print("════════ 转速损耗 · 物理层验证 ════════")

	h.suite("① 转动惯量 I = k·m·r²")
	_inertia(h)

	h.suite("② 自然衰减：转速越高掉得越快（空气阻力 ω²）")
	_natural_speed(h)

	h.suite("③ 轴尖干摩擦与质量无关（重的摩擦大、惯量也大）")
	_natural_mass(h)

	h.suite("④ 撞击速度越快，转速损失越大")
	_impact_speed(h)

	h.suite("⑤ 碰撞里质量起作用：轻的掉得狠")
	_impact_mass(h)

	h.suite("⑥ 转动动能单调下降（摩擦只耗散）")
	_energy(h)

	h.suite("⑦ 反向自转 → 齿轮啮合，慢的一方被带快")
	_counter_spin(h)

	h.suite("⑧ 撞墙：接近速度越大损失越大")
	_wall(h)

	h.suite("⑨ 三种性格的纯自然寿命")
	_lifetime(h)

	print("")
	print("── 汇总：PASS %d / FAIL %d" % [h.pass_count(), h.fail_count()])
	for f in h.failures():
		print("   FAIL: ", f)
	quit(1 if h.fail_count() > 0 else 0)


# ── 造一颗「只取物理量」的陀螺（不入场景树，纯数据用）──
func _mk(arch: StringName, spin: float) -> TopTop:
	var t := TopTop.create(arch, 1)
	t.spin = spin
	return t


func _inertia(h: TestHarness) -> void:
	var base := TopsSpin.axial_inertia(0.05, 0.016, 0.55)
	var m2 := TopsSpin.axial_inertia(0.10, 0.016, 0.55)
	var r2 := TopsSpin.axial_inertia(0.05, 0.032, 0.55)
	h.ck(absf(m2 / base - 2.0) < 1e-6, "质量翻倍 → 惯量翻倍（%s → %s）" % [_e(base), _e(m2)])
	h.ck(absf(r2 / base - 4.0) < 1e-6, "半径翻倍 → 惯量 ×4（%s → %s）" % [_e(base), _e(r2)])
	var dart := _mk(&"DART", 100.0)
	var ram := _mk(&"RAM", 100.0)
	print("   DART I=%s kg·m² / BALANCED I=%s / RAM I=%s"
			% [_e(dart.axial_inertia), _e(base), _e(ram.axial_inertia)])
	h.ck(ram.axial_inertia > base and base > dart.axial_inertia,
			"惯量排序 RAM > BALANCED > DART")
	dart.free()
	ram.free()


func _natural_speed(h: TestHarness) -> void:
	var t := _mk(&"BALANCED", 100.0)
	var curve: Array[float] = []
	for sp in [5.0, 20.0, 40.0, 60.0, 80.0, 90.0, 100.0]:
		var d: float = TopsSpin.natural_domega(t.mass_kg, t.radius_m, t.axial_inertia,
				t.tip_mu, t.tip_r_eff, TopsSpin.omega_of(sp))
		curve.append(d)
		print("   转速 %s → dω/dt = %s rad/s²（%s 转/秒）"
				% [_f1(sp), _f2(d), _f2(TopsSpin.spin_of(d))])
	# 整条曲线是 U 形：高转速端由空气阻力（∝ω²）主导，低转速端由失稳刮擦主导
	var hi100: float = curve[6]
	var hi90: float = curve[5]
	var hi80: float = curve[4]
	h.ck(hi100 < hi90 and hi90 < hi80,
			"高转速区（80→90→100）掉得越来越快 —— 空气阻力 ω² 项在起作用")
	var lo5: float = curve[0]
	var mid60: float = curve[3]
	h.ck(lo5 < mid60, "临停前失稳刮擦加剧，掉得比 60 转时还快（U 形左端）")
	h.ck(hi100 < 0.0, "满转速时确实在掉转速")
	t.free()


func _natural_mass(h: TestHarness) -> void:
	# ω→0 时只剩轴尖干摩擦：dω/dt = -μ·g·r_eff/(k·r²)，与质量无关
	var r := 0.016
	var k := 0.55
	var mu := 0.15
	var r_eff := TopsSpin.tip_effective_radius(r)
	var a: float = TopsSpin.natural_domega(0.02, r, TopsSpin.axial_inertia(0.02, r, k),
			mu, r_eff, 0.0)
	var b: float = TopsSpin.natural_domega(0.20, r, TopsSpin.axial_inertia(0.20, r, k),
			mu, r_eff, 0.0)
	print("   20 g 与 200 g 陀螺的 dω/dt：%s / %s rad/s²" % [_f4(a), _f4(b)])
	h.ck(absf(a - b) < 1e-6, "质量差 10 倍，轴尖摩擦造成的角减速度完全相同")
	# 但换成大半径，就明显不一样：dω/dt ∝ 1/(k·r²)
	var c: float = TopsSpin.natural_domega(0.05, 0.032, TopsSpin.axial_inertia(0.05, 0.032, k),
			mu, TopsSpin.tip_effective_radius(0.032), 0.0)
	var d: float = TopsSpin.natural_domega(0.05, 0.016, TopsSpin.axial_inertia(0.05, 0.016, k),
			mu, TopsSpin.tip_effective_radius(0.016), 0.0)
	print("   半径 32 mm 与 16 mm：%s / %s rad/s²" % [_f4(c), _f4(d)])
	h.ck(absf(c) < absf(d), "半径越大转得越久（∝1/r²）—— 决定寿命的是尺寸不是重量")


func _impact_speed(h: TestHarness) -> void:
	var n := Vector2(1.0, 0.0)
	var res: Array[float] = []
	for sp in [80.0, 160.0, 320.0]:
		var a := _mk(&"BALANCED", 100.0)
		var b := _mk(&"BALANCED", 100.0)
		# 相向对撞：B 相对 A 的速度 = -2·sp 沿 +x（法线 n 指 A→B）
		var dw := TopsSpin.contact_domega(a.mass_kg, a.radius_m, a.axial_inertia, a.omega(),
				b.mass_kg, b.radius_m, b.axial_inertia, b.omega(),
				n, Vector2(-2.0 * sp, 0.0), Vector2.ZERO, Vector2.ZERO, 0.0)
		var loss: float = -(dw.x + dw.y) * 0.5
		res.append(loss)
		print("   接近速度 %s wu/s → 双方各掉 %s 转" % [_f1(2.0 * sp), _f2(TopsSpin.spin_of(loss))])
		a.free()
		b.free()
	h.ck(res[0] < res[1] and res[1] < res[2], "撞得越快，转速掉得越多（单调递增）")
	h.ck(absf(res[1] / res[0] - 2.0) < 0.02, "接近速度翻倍 → 损失翻倍（冲量线性）")


func _impact_mass(h: TestHarness) -> void:
	var n := Vector2(1.0, 0.0)
	var dart := _mk(&"DART", 100.0)
	var ram := _mk(&"RAM", 100.0)
	var dw := TopsSpin.contact_domega(dart.mass_kg, dart.radius_m, dart.axial_inertia, dart.omega(),
			ram.mass_kg, ram.radius_m, ram.axial_inertia, ram.omega(),
			n, Vector2(-300.0, 0.0), Vector2.ZERO, Vector2.ZERO, 0.0)
	var ld: float = TopsSpin.spin_of(-dw.x)
	var lr: float = TopsSpin.spin_of(-dw.y)
	print("   DART(%s kg) 掉 %s 转 / RAM(%s kg) 掉 %s 转"
			% [_f3(dart.mass_kg), _f2(ld), _f3(ram.mass_kg), _f2(lr)])
	h.ck(ld > lr * 2.0, "同样一撞，轻的转速损失是重的 2 倍以上（Δω = J·r/I ∝ 1/m）")
	dart.free()
	ram.free()


func _energy(h: TestHarness) -> void:
	var n := Vector2(1.0, 0.0)
	var cases := [[100.0, 100.0], [100.0, 60.0], [100.0, 20.0], [40.0, 40.0]]
	for c in cases:
		var sa: float = float(c[0])
		var sb: float = float(c[1])
		var a := _mk(&"BALANCED", sa)
		var b := _mk(&"BALANCED", sb)
		var wa: float = a.omega()
		var wb: float = b.omega()
		var Ia: float = a.axial_inertia
		var Ib: float = b.axial_inertia
		var e0: float = 0.5 * Ia * wa * wa + 0.5 * Ib * wb * wb
		var dw := TopsSpin.contact_domega(a.mass_kg, a.radius_m, Ia, wa,
				b.mass_kg, b.radius_m, Ib, wb,
				n, Vector2(-260.0, 40.0), Vector2.ZERO, Vector2.ZERO, 0.5)
		var e1: float = 0.5 * Ia * maxf(wa + dw.x, 0.0) * maxf(wa + dw.x, 0.0) \
				+ 0.5 * Ib * maxf(wb + dw.y, 0.0) * maxf(wb + dw.y, 0.0)
		print("   %s vs %s → 转动动能 %s → %s J（Δ=%s）"
				% [_f1(sa), _f1(sb), _e(e0), _e(e1), _e(e1 - e0)])
		h.ck(e1 <= e0 + 1e-12, "动能没有增加（%s J → %s J）" % [_e(e0), _e(e1)])
		a.free()
		b.free()


func _counter_spin(h: TestHarness) -> void:
	var n := Vector2(1.0, 0.0)
	var a := _mk(&"BALANCED", 100.0)
	var b := _mk(&"BALANCED", -100.0)   # 反向自转
	var dw := TopsSpin.contact_domega(a.mass_kg, a.radius_m, a.axial_inertia, a.omega(),
			b.mass_kg, b.radius_m, b.axial_inertia, b.omega(),
			n, Vector2(-200.0, 0.0), Vector2.ZERO, Vector2.ZERO, 0.0)
	print("   同速反向：Δω_a=%s  Δω_b=%s rad/s" % [_f2(dw.x), _f2(dw.y)])
	h.ck(absf(dw.x + dw.y) < 1e-6, "完全对称的反向自转：两者受力矩大小相等、方向相反")
	# 一快一慢反向：轮缘速度差 → 摩擦把快的往慢的方向拖，慢的被带快（齿轮啮合）
	var c := _mk(&"BALANCED", 100.0)
	var d := _mk(&"BALANCED", -20.0)
	var dw2 := TopsSpin.contact_domega(c.mass_kg, c.radius_m, c.axial_inertia, c.omega(),
			d.mass_kg, d.radius_m, d.axial_inertia, d.omega(),
			n, Vector2(-200.0, 0.0), Vector2.ZERO, Vector2.ZERO, 0.0)
	print("   100 vs -20：Δω_a=%s  Δω_b=%s rad/s" % [_f2(dw2.x), _f2(dw2.y)])
	h.ck(dw2.x < 0.0, "快的一方（+100）被拖慢")
	h.ck(dw2.y < 0.0, "慢的一方（-20）被带快（ω 更负 = 反向转得更快）")
	c.free()
	d.free()
	a.free()
	b.free()


func _wall(h: TestHarness) -> void:
	var res: Array[float] = []
	for sp in [100.0, 250.0, 450.0]:
		var t := _mk(&"BALANCED", 100.0)
		var dw: float = TopsSpin.wall_domega(t.mass_kg, t.radius_m, t.axial_inertia,
				t.omega(), sp)
		res.append(dw)
		print("   撞墙接近速度 %s → 掉 %s 转" % [_f1(sp), _f2(TopsSpin.spin_of(-dw))])
		t.free()
	h.ck(res[0] > res[1] and res[1] > res[2], "撞墙越快，轮缘擦掉的转速越多")
	h.ck(res[2] < 0.0, "撞墙确实扣转速")


func _lifetime(h: TestHarness) -> void:
	for arch in [&"DART", &"BALANCED", &"RAM"]:
		var t := _mk(arch, 100.0)
		var time := 0.0
		var guard := 0
		while t.spin > 0.0 and guard < 60 * 600:
			var dw: float = TopsSpin.natural_domega(t.mass_kg, t.radius_m, t.axial_inertia,
					t.tip_mu, t.tip_r_eff, t.omega())
			t.spin = maxf(0.0, t.spin + TopsSpin.spin_of(dw) * STEP)
			time += STEP
			guard += 1
		print("   %s（%s kg / r=%s mm / k=%s / μ=%s）→ 纯自然寿命 %s s"
				% [arch, _f3(t.mass_kg), _f1(t.radius_m * 1000.0), _f2(t.shape_k),
						_f2(t.tip_mu), _f1(time)])
		h.ck(time > 45.0 and time < 200.0, "%s 的自然寿命 %s s 落在 45–200 s" % [arch, _f1(time)])
		t.free()


func _f1(x: float) -> String:
	return "%.1f" % x


func _f2(x: float) -> String:
	return "%.2f" % x


func _f3(x: float) -> String:
	return "%.3f" % x


func _f4(x: float) -> String:
	return "%.4f" % x


## 科学计数法（GDScript 的 % 不支持 %e/%g，手写一个）
func _e(x: float) -> String:
	if x == 0.0:
		return "0"
	var ex: int = int(floor(log(absf(x)) / log(10.0)))
	var mant: float = x / pow(10.0, float(ex))
	return "%.2fe%d" % [mant, ex]
