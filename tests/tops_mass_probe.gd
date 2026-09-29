extends SceneTree
##
## 质量因素探针：把「质量」单独拎出来，看它在自然衰减 / 互撞 / 撞墙里到底起多大作用。
##
## 跑法：
##   "Godot_..._console.exe" --headless --path "D:/Tops3D" --script res://tests/tops_mass_probe.gd
##
## 四个实验：
##   ① 原型物理量：m → I = k·m·r² 真的是按质量算出来的吗
##   ② 自然衰减  ：轴尖干摩擦 τ ∝ m、惯量 I ∝ m → 理论上**质量约掉**，差异只来自 r/k/μ
##   ③ 互撞      ：Δω = J_t·r/I，J_t ∝ m_red → 自己越重掉得越少、对手越重自己掉得越多
##   ④ 撞墙      ：J_n ∝ m、I ∝ m → 理论上也**约掉**
## ②④ 都用「把 RAM 的质量换成 DART 的，其余一律不变」做对照，直接分离出质量的贡献。
##

const SPIN := 100.0          # 参与对比的转速（点）
const HIT_SPEED := 200.0     # 单侧接近速度（wu/s），相向 → 相对 400


func _initialize() -> void:
	await process_frame
	var archs: Array[StringName] = [&"DART", &"BALANCED", &"RAM"]
	var tops: Array[TopTop] = []
	for i in archs.size():
		tops.append(TopTop.create(archs[i], i + 1))

	print("════════ 质量在「旋转 / 碰撞」里的作用 ════════")

	print("\n① 原型物理量（质量是否真的进了惯量）")
	# ⚠ GDScript 的 % 不支持 %e/%g，惯量用 ×10⁻⁶ 自己拼
	print("  原型        质量    半径   shape_k  I(×10⁻⁶ kg·m²)  ω_c(rad/s)")
	for i in tops.size():
		var t: TopTop = tops[i]
		print("  %-10s %5.0f g %5.0f mm %7.2f %14.2f %10.1f"
				% [String(archs[i]), t.mass_kg * 1000.0, t.radius_m * 1000.0,
				   t.shape_k, t.axial_inertia * 1e6, t.omega_crit])
	print("  · I = k·m·r²：质量 0.7→1.6（2.3×）、半径 13→19，两者叠出 %.1f× 的惯量差"
			% [tops[2].axial_inertia / tops[0].axial_inertia])

	# ── ② 自然衰减 ──
	print("\n② 自然衰减（满转速 %d 点 = %.0f rad/s）" % [int(SPIN), TopsSpin.omega_of(SPIN)])
	print("  原型      dω/dt(rad/s²)   掉光约(s)   换成DART质量后  →  变化")
	var w0: float = TopsSpin.omega_of(SPIN)
	var base_decay: float = 0.0
	for i in tops.size():
		var t: TopTop = tops[i]
		var d: float = TopsSpin.natural_domega(t.mass_kg, t.radius_m, t.axial_inertia,
				t.tip_mu, t.tip_r_eff, w0)
		if i == 0:
			base_decay = d
		# 对照：只把质量换成 DART 的，r / k / μ / I 的定义不变（I 随质量重算）
		var m_dart: float = float(TopBody.ARCHETYPES[&"DART"]["mass"]) * TopsSpin.MASS_UNIT_KG
		var i_dart: float = TopsSpin.axial_inertia(m_dart, t.radius_m, t.shape_k)
		var d_sw: float = TopsSpin.natural_domega(m_dart, t.radius_m, i_dart,
				t.tip_mu, t.tip_r_eff, w0)
		var rel: float = (d_sw / d) if absf(d) > 1e-9 else 0.0
		print("  %-10s %12.2f %10.1f %14.2f  →  ×%.3f"
				% [String(archs[i]), d, w0 / absf(d), d_sw, rel])
	print("  · 同一颗陀螺只改质量：若 ×1.000 说明质量在这一项里**完全约掉**（干摩擦 τ∝m、I∝m）")

	# ── ③ 互撞：DART / BALANCED / RAM 两两对撞 ──
	print("\n③ 正面对撞（各以 %d wu/s 相向，双方转速 %d 点）" % [int(HIT_SPEED), int(SPIN)])
	print("  组合                 A 掉(点)   B 掉(点)")
	var n := Vector2(1.0, 0.0)
	var rel_vel := Vector2(-HIT_SPEED * 2.0, 0.0)   # b 相对 a 的速度
	for i in tops.size():
		for j in range(i + 1, tops.size()):
			var a: TopTop = tops[i]
			var b: TopTop = tops[j]
			var dw: Vector2 = TopsSpin.contact_domega(
					a.mass_kg, a.radius_m, a.axial_inertia, TopsSpin.omega_of(SPIN),
					b.mass_kg, b.radius_m, b.axial_inertia, TopsSpin.omega_of(SPIN),
					n, rel_vel, Vector2.ZERO, Vector2.ZERO, 0.0)
			print("  %-9s vs %-9s %8.2f %9.2f"
					% [String(archs[i]), String(archs[j]),
					   TopsSpin.spin_of(dw.x), TopsSpin.spin_of(dw.y)])

	# 对照：RAM 挨打时，只把「自己」的质量换成 DART 的 → 自己掉多少
	print("\n  对照（RAM 挨 BALANCED 撞，只改 RAM 自己的质量）")
	var bal: TopTop = tops[1]
	var ram: TopTop = tops[2]
	for m in [0.7, 1.0, 1.6, 2.4]:
		var m_kg: float = m * TopsSpin.MASS_UNIT_KG
		var i_kg: float = TopsSpin.axial_inertia(m_kg, ram.radius_m, ram.shape_k)
		var dw2: Vector2 = TopsSpin.contact_domega(
				m_kg, ram.radius_m, i_kg, TopsSpin.omega_of(SPIN),
				bal.mass_kg, bal.radius_m, bal.axial_inertia, TopsSpin.omega_of(SPIN),
				n, rel_vel, Vector2.ZERO, Vector2.ZERO, 0.0)
		# ⚠ GDScript 的 % 不支持 %e/%g，科学计数法要自己拼
		print("    RAM 质量 %.1f（I=%.2f×10⁻⁶）→ 自己掉 %6.2f 点，对手掉 %6.2f 点"
				% [m, i_kg * 1e6, TopsSpin.spin_of(dw2.x), TopsSpin.spin_of(dw2.y)])

	# ── ④ 撞墙 ──
	print("\n④ 撞墙（以 %d wu/s 撞上碗壁，转速 %d 点）" % [int(HIT_SPEED), int(SPIN)])
	print("  原型      掉(点)   换成DART质量后  →  变化")
	for i in tops.size():
		var t: TopTop = tops[i]
		var dw_w: float = TopsSpin.wall_domega(t.mass_kg, t.radius_m, t.axial_inertia,
				TopsSpin.omega_of(SPIN), HIT_SPEED)
		var m_dart2: float = float(TopBody.ARCHETYPES[&"DART"]["mass"]) * TopsSpin.MASS_UNIT_KG
		var i_dart2: float = TopsSpin.axial_inertia(m_dart2, t.radius_m, t.shape_k)
		var dw_sw: float = TopsSpin.wall_domega(m_dart2, t.radius_m, i_dart2,
				TopsSpin.omega_of(SPIN), HIT_SPEED)
		var rel2: float = (dw_sw / dw_w) if absf(dw_w) > 1e-9 else 0.0
		print("  %-10s %6.2f %14.2f  →  ×%.3f"
				% [String(archs[i]), TopsSpin.spin_of(dw_w), TopsSpin.spin_of(dw_sw), rel2])
	print("  · 撞墙时 J_n ∝ m、I ∝ m，若 ×1.000 说明质量在这一项里也**完全约掉**")

	# ── ⑤ 初始转速：当前是手写档位，若按「等发射能量」建模该是多少 ──
	print("\n⑤ 初始转速与质量（发射能量假定与陀螺无关）")
	var ref: TopTop = tops[1]
	var e_launch: float = 0.5 * ref.axial_inertia * pow(TopsSpin.omega_of(ref.spin_max), 2.0)
	print("  以 BALANCED 档位 %d 点为基准 → 发射转动动能 E = %.3f J" % [int(ref.spin_max), e_launch])
	print("  原型      当前档位    等能量推算     差值")
	for i in tops.size():
		var t: TopTop = tops[i]
		var w_eq: float = sqrt(2.0 * e_launch / maxf(t.axial_inertia, 1e-12))
		print("  %-10s %6.0f 点 %9.0f 点 %+8.0f"
				% [String(archs[i]), t.spin_max, TopsSpin.spin_of(w_eq),
				   TopsSpin.spin_of(w_eq) - t.spin_max])
	print("  · 等能量下 ω₀ = √(2E/I) ∝ 1/√m：重的陀螺起手就该更慢。")
	print("    当前档位已由发射能量推导（含 β=%.2f 的传动滑移），「等能量推算」一列是 β=0 的纯理论值。"
			% TopsSpin.LAUNCH_SLIP_EXP)

	# ── ⑥ 起手转速 → 能转多久（纯自然衰减，dt=0.1s 积分到停）──
	print("\n⑥ 起手转速 → 自然寿命（纯衰减，不含碰撞）")
	print("  原型      起手(点)  起手(rad/s)  自然寿命(s)")
	for i in tops.size():
		var t: TopTop = tops[i]
		var w: float = TopsSpin.omega_of(t.spin_max)
		var tt: float = 0.0
		var dt: float = 0.1
		while w > 1.0 and tt < 900.0:
			var dwdt: float = TopsSpin.natural_domega(t.mass_kg, t.radius_m,
					t.axial_inertia, t.tip_mu, t.tip_r_eff, w)
			w = maxf(w + dwdt * dt, 0.0)
			tt += dt
		print("  %-10s %8.0f %12.0f %12.1f"
				% [String(archs[i]), t.spin_max, TopsSpin.omega_of(t.spin_max), tt])

	# ── ⑦ 反解：要让三者自然寿命都 ≈ TARGET，tip_mu 该给多少 ──
	const TARGET := 90.0
	print("\n⑦ 轴尖品质反解（目标：三者自然寿命都 %.0f s）" % TARGET)
	print("  原型      当前 tip_mu   当前寿命   达标所需 tip_mu")
	for i in tops.size():
		var t: TopTop = tops[i]
		var life_now: float = _lifetime(t.mass_kg, t.radius_m, t.axial_inertia,
				t.tip_mu, t.tip_r_eff, TopsSpin.omega_of(t.spin_max))
		var need_mu: float = _solve_tip_mu(t.mass_kg, t.radius_m, t.axial_inertia,
				t.tip_r_eff, TopsSpin.omega_of(t.spin_max), TARGET)
		print("  %-10s %9.2f %10.1f s %13.3f"
				% [String(archs[i]), t.tip_mu, life_now, need_mu])
	print("  · 起手快的（DART）需要**更钝**的轴尖才不至于通吃，起手慢的（RAM）需要**更尖**的轴尖。")
	print("    这正是「爆发型 vs 持久型」的真实分工，tip_mu 从此是新的平衡砝码。")

	# ── ⑧ 统一 tip_mu 时寿命呈什么格局（起手转速差会自己把寿命拉开）──
	print("\n⑧ 若三者 tip_mu 统一，寿命格局（起手转速差自己会拉开寿命）")
	print("  tip_mu    DART(%d)   BAL(%d)   RAM(%d)"
			% [int(tops[0].spin_max), int(tops[1].spin_max), int(tops[2].spin_max)])
	for mu in [0.10, 0.13, 0.15, 0.18, 0.21]:
		var row: Array = []
		for i in tops.size():
			var t: TopTop = tops[i]
			row.append(_lifetime(t.mass_kg, t.radius_m, t.axial_inertia, mu,
					t.tip_r_eff, TopsSpin.omega_of(t.spin_max)))
		print("  %6.2f %10.1f %10.1f %9.1f" % [mu, row[0], row[1], row[2]])
	print("  · 寿命必须**递减**（DART 最长、RAM 最短）才能抵消 RAM 的抗撞优势；")
	print("    三者拉平反而让「碰撞抗性」独占 → 实测 RAM 45%、DART 15%。")

	# ── ⑨ 校准靶：2026-09-28 手写档位的寿命格局（实测胜率均衡的那一版）──
	print("\n⑨ 校准靶：手写档位 105/102/88 + tip_mu 0.10/0.15/0.19 的寿命格局")
	var legacy_spin: Array = [105.0, 102.0, 88.0]
	var legacy_mu: Array = [0.10, 0.15, 0.19]
	var legacy_life: Array = []
	for i in tops.size():
		var t: TopTop = tops[i]
		var life: float = _lifetime(t.mass_kg, t.radius_m, t.axial_inertia,
				legacy_mu[i], t.tip_r_eff, TopsSpin.omega_of(legacy_spin[i]))
		legacy_life.append(life)
		print("  %-10s 档位 %3.0f 点 / tip_mu %.2f → 寿命 %6.1f s"
				% [String(archs[i]), legacy_spin[i], legacy_mu[i], life])
	print("  · 这是实测胜率均衡（DART 10~20% / BAL 20~35% / RAM 15%）那一版的格局，")
	print("    新档位（由能量推导）应当**复现这个寿命排序与差距**。")

	# ── ⑩ 当前推导档位下，要复现校准靶寿命，tip_mu 该给多少 ──
	print("\n⑩ 反解：当前推导档位 + 校准靶寿命 → 所需 tip_mu")
	print("  原型      推导档位(点)  目标寿命(s)   所需 tip_mu   当前 tip_mu")
	var need_mu_arr: Array = []
	for i in tops.size():
		var t: TopTop = tops[i]
		var need_mu: float = _solve_tip_mu(t.mass_kg, t.radius_m, t.axial_inertia,
				t.tip_r_eff, TopsSpin.omega_of(t.spin_max), float(legacy_life[i]))
		need_mu_arr.append(need_mu)
		print("  %-10s %9.0f %12.1f %13.3f %12.3f"
				% [String(archs[i]), t.spin_max, float(legacy_life[i]), need_mu, t.tip_mu])
	print("  · 把这三个数写进 ARCHETYPES 的 tip_mu，就能在「能量推导档位」下复现旧版寿命格局。")

	print("\n═══════════════════════════════════════════")
	for t in tops:
		t.free()
	quit(0)


## 纯自然衰减下从 w0 转到停的秒数
func _lifetime(m_kg: float, r_m: float, inertia: float, tip_mu: float,
		tip_r_eff: float, w0: float) -> float:
	var w: float = w0
	var tt: float = 0.0
	const dt := 0.1
	while w > 1.0 and tt < 900.0:
		var dwdt: float = TopsSpin.natural_domega(m_kg, r_m, inertia, tip_mu, tip_r_eff, w)
		w = maxf(w + dwdt * dt, 0.0)
		tt += dt
	return tt


## 二分反解 tip_mu：μ 越大寿命越短
func _solve_tip_mu(m_kg: float, r_m: float, inertia: float, tip_r_eff: float,
		w0: float, target: float) -> float:
	var lo: float = 0.005
	var hi: float = 2.0
	for _k in 48:
		var mid: float = (lo + hi) * 0.5
		if _lifetime(m_kg, r_m, inertia, mid, tip_r_eff, w0) > target:
			lo = mid      # 转太久 → 轴尖要更钝
		else:
			hi = mid
	return (lo + hi) * 0.5
