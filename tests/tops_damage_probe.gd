extends SceneTree
##
## 伤害归因探针：一次碰撞里「受到的伤害 / 造成的伤害」到底由谁决定？
##
## 跑法：
##   "Godot_..._console.exe" --headless --path "D:/Tops3D" --script res://tests/tops_damage_probe.gd
##
## 三个自变量各扫一遍（其余一律不变，标准对照实验）：
##   ① 接近速度 u_n（= 双方的移动速度沿连心线的分量）
##   ② 自转角速度 ω（转速）
##   ③ 质量 m
## 每次都打印 J_t 的**两个候选上限**：
##   coulomb = μ·J_n        法向冲量给的摩擦上限（撞得越猛越松）
##   slip    = |u_s|/inv_k  让接触点完全止滑所需的冲量（转得越快越松）
## J_t = min(两者) —— 谁小谁说了算。所以「转速有没有用」取决于当时谁在卡。
##
## ⚠ 规则层还会把物理结果再乘 CONTACT_LOSS_SCALE(0.10) 才是**实际扣的转速**，
##   两列都打印，别拿物理量当实战数值。
##

const SPIN := 100.0          # 默认转速（点）
const HIT := 200.0           # 默认单侧接近速度（wu/s）→ 相对 400
const PRESS_DT := 0.50       # TopsRules.CONTACT_COOLDOWN


func _initialize() -> void:
	await process_frame
	var archs: Array[StringName] = [&"DART", &"BALANCED", &"RAM"]
	var tops: Array[TopTop] = []
	for i in archs.size():
		tops.append(TopTop.create(archs[i], i + 1))

	print("════════ 碰撞伤害归因：转速 / 移动速度 / 质量 ════════")
	print("  实战扣血 = 物理 Δω × CONTACT_LOSS_SCALE %.2f"
			% TopsRules.CONTACT_LOSS_SCALE)
	print("  公式：Δω = J_t·r / I = J_t / (k·m·r)   J_t = min(μ·J_n, |u_s|/inv_k)")

	# ── ① 扫接近速度（移动速度）──
	print("\n① 移动速度 → 伤害（BALANCED vs BALANCED，双方 %d 点）" % int(SPIN))
	print("  相对接近(wu/s)  J_n(N·s)     库仑上限   止滑上限   谁在卡   自己掉(点)  实战(点)")
	for v in [50.0, 100.0, 200.0, 400.0, 800.0, 1600.0]:
		var r: Dictionary = _hit(tops[1], tops[1], SPIN, SPIN, v)
		_row(v, r, "BAL")

	# ── ② 扫自转角速度 ──
	print("\n② 转速 → 伤害（BALANCED vs BALANCED，相对接近 %d wu/s）" % int(HIT * 2.0))
	print("  双方转速(点)   u_s(m/s)   库仑上限   止滑上限   谁在卡   掉(点)   实战(点)")
	for sp in [10.0, 25.0, 50.0, 100.0, 150.0, 220.0]:
		var r2: Dictionary = _hit(tops[1], tops[1], sp, sp, HIT)
		print("  %8.0f %11.2f %10.4f %10.4f   %-6s %8.2f %9.2f"
				% [sp, float(r2["u_s"]), float(r2["coulomb"]), float(r2["slip"]),
				   _who(r2), _pts(r2, "a"), _real(r2, "a")])
	print("  · 转速只出现在「止滑上限」里：只要库仑上限更小，转多快都不影响伤害。")

	# ── ③ 自转方向（同向 / 反向 / 一方不转）──
	print("\n③ 自转方向：同向互磨 vs 反向啮合（相对接近 %d wu/s）" % int(HIT * 2.0))
	print("  A 转速   B 转速    u_s(m/s)   谁在卡    A 掉(点)   B 掉(点)")
	for pair in [[100.0, 100.0], [100.0, 50.0], [100.0, 0.0],
			[100.0, -100.0], [100.0, -99.0]]:
		var r3: Dictionary = _hit(tops[1], tops[1], pair[0], pair[1], HIT)
		print("  %6.0f %8.0f %11.2f   %-6s %9.2f %9.2f"
				% [pair[0], pair[1], float(r3["u_s"]), _who(r3),
				   _pts(r3, "a"), _pts(r3, "b")])
	print("  · 反向自转时接触点几乎不滑 → 趋近齿轮啮合，慢的一方反而被带快（掉的点变负）。")

	# ── ④ 扫质量：自己重 → 自己掉得少？对手重 → 我掉得多？──
	print("\n④ 质量 → 伤害（A 只改质量，B 恒为 BALANCED，双方 %d 点，相对 %d wu/s）"
			% [int(SPIN), int(HIT * 2.0)])
	print("  A 质量(单位)  m_red(kg)   A 掉(点)   B 掉(点)   实战 A / B")
	for m in [0.5, 0.7, 1.0, 1.6, 2.4]:
		var r4: Dictionary = _hit_m(tops[1], tops[1], m, 1.0, SPIN, SPIN, HIT)
		print("  %8.1f %11.4f %9.2f %9.2f %9.2f / %.2f"
				% [m, float(r4["m_red"]), _pts(r4, "a"), _pts(r4, "b"),
				   _real(r4, "a"), _real(r4, "b")])
	print("  · 自己越重 → 自己掉得越少（分母 k·m·r 涨得比 m_red 快）；")
	print("    同时 m_red 变大 → **对手掉得越多**（又抗撞又能打，代价是起手转速低）。")

	# ── ⑤ 贴身对磨（没有撞击，只有持续挤压）──
	print("\n⑤ 贴身对磨（接近速度 0，只有挤压 N·Δt=%.2f s）：转速在这里才起作用" % PRESS_DT)
	print("  双方转速(点)   库仑上限   止滑上限   谁在卡   掉(点)   实战(点)")
	for sp in [10.0, 50.0, 100.0, 200.0]:
		var r5: Dictionary = _grind(tops[1], tops[1], sp, sp)
		print("  %8.0f %11.5f %10.4f   %-6s %8.3f %9.3f"
				% [sp, float(r5["coulomb"]), float(r5["slip"]), _who(r5),
				   _pts(r5, "a"), _real(r5, "a")])
	print("  · 没有撞击时 J_n 只剩「挤压力 × Δt」，小到库仑上限远低于止滑上限")
	print("    → 掉得很少，且**仍然与转速无关**（除非慢到快止滑）。")

	# ── ⑥ 实战：三原型两两对撞，各带自己的推导档位 ──
	print("\n⑥ 实战对照：三原型两两正撞（各自推导档位，相对接近 %d wu/s）" % int(HIT * 2.0))
	print("  A        vs B         A 起手   B 起手   A 掉(点)  B 掉(点)  实战 A / B")
	for i in tops.size():
		for j in range(i + 1, tops.size()):
			var a: TopTop = tops[i]
			var b: TopTop = tops[j]
			var r6: Dictionary = _hit(a, b, a.spin_max, b.spin_max, HIT)
			print("  %-9s vs %-9s %6.0f %8.0f %9.2f %9.2f %9.2f / %.2f"
					% [String(archs[i]), String(archs[j]), a.spin_max, b.spin_max,
					   _pts(r6, "a"), _pts(r6, "b"), _real(r6, "a"), _real(r6, "b")])
	print("  · 掉得最多的永远是**又轻又小**的那个（∝ 1/(k·m·r)），与谁撞谁无关。")

	print("\n═══════════════════════════════════════════")
	for t in tops:
		t.free()
	quit(0)


# ── 单次对撞：A 沿 +x、B 沿 −x，各以 v wu/s 相向 ──
func _hit(a: TopTop, b: TopTop, spin_a: float, spin_b: float, v: float) -> Dictionary:
	return _hit_m(a, b, a.mass, b.mass, spin_a, spin_b, v)


## 可覆写质量（游戏单位）的版本
func _hit_m(a: TopTop, b: TopTop, m_a: float, m_b: float,
		spin_a: float, spin_b: float, v: float) -> Dictionary:
	var ma: float = m_a * TopsSpin.MASS_UNIT_KG
	var mb: float = m_b * TopsSpin.MASS_UNIT_KG
	var Ia: float = TopsSpin.axial_inertia(ma, a.radius_m, a.shape_k)
	var Ib: float = TopsSpin.axial_inertia(mb, b.radius_m, b.shape_k)
	var n := Vector2(1.0, 0.0)
	var rel := Vector2(-v * 2.0, 0.0)
	var r := TopsSpin.contact_resolve(ma, a.radius_m, Ia, TopsSpin.omega_of(spin_a),
			mb, b.radius_m, Ib, TopsSpin.omega_of(spin_b),
			n, rel, Vector2.ZERO, Vector2.ZERO, 0.0)
	r["m_red"] = (ma * mb) / maxf(ma + mb, 1e-9)
	return r


## 贴身对磨：无接近速度、无推进，只有基础挤压力
func _grind(a: TopTop, b: TopTop, spin_a: float, spin_b: float) -> Dictionary:
	var r := TopsSpin.contact_resolve(a.mass_kg, a.radius_m, a.axial_inertia,
			TopsSpin.omega_of(spin_a),
			b.mass_kg, b.radius_m, b.axial_inertia, TopsSpin.omega_of(spin_b),
			Vector2(1.0, 0.0), Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, PRESS_DT)
	r["m_red"] = (a.mass_kg * b.mass_kg) / maxf(a.mass_kg + b.mass_kg, 1e-9)
	return r


## 谁在卡 J_t
func _who(r: Dictionary) -> String:
	if float(r["j_t"]) <= 1e-12:
		return "无"
	return "库仑" if float(r["coulomb"]) <= float(r["slip"]) else "止滑"


func _pts(r: Dictionary, side: String) -> float:
	return TopsSpin.spin_of(float(r["domega_" + side]))


func _real(r: Dictionary, side: String) -> float:
	return TopsSpin.spin_of(float(r["domega_" + side]) * TopsRules.CONTACT_LOSS_SCALE)


func _row(v: float, r: Dictionary, _tag: String) -> void:
	print("  %12.0f %10.4f %10.4f %10.4f   %-6s %9.2f %9.2f"
			% [v * 2.0, float(r["j_n"]), float(r["coulomb"]), float(r["slip"]),
			   _who(r), _pts(r, "a"), _real(r, "a")])
