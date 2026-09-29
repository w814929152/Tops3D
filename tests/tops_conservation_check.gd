extends SceneTree
##
## 碰撞求解的守恒律审计 —— 一次 contact_resolve 之后，线动量与角动量必须都不变。
##
## 跑法：
##   "Godot_..._console.exe" --headless --path "D:/Tops3D" --script res://tests/tops_conservation_check.gd
##
## 为什么专门验这个：
##   摩擦冲量是**一对**等大反向的力（A 受 +f·t̂、B 受 −f·t̂），作用在同一个接触点上。
##   它俩对线动量的贡献自动抵消，但**对角动量不自动抵消** —— 自转角动量变了
##   （两颗都减速），必须靠「两颗被沿切向搓开」带来的**轨道角动量**补回来。
##   两者符号对不上，总角动量就会凭空增减：物理上不成立，画面上表现为
##   「互磨时两颗陀螺被往错误的方向拖着绕圈」。
##
## 几何（全部取 SI，t̂ = n 顺时针转 90°）：
##   A 在原点，B 在 (r_a+r_b)·n̂ 处，n̂ = (1,0) → t̂ = (0,−1)
##   L = Σ I_i·ω_i + Σ (pos_i × m_i·v_i)_z
##

const HIT := 200.0        # 单侧接近速度 wu/s
const SPIN_A := 100.0
const SPIN_B := 100.0


func _initialize() -> void:
	await process_frame
	var h := TestHarness.new()
	print("════════ 碰撞求解 · 守恒律审计 ════════")

	var a := TopTop.create(&"BALANCED", 1)
	var b := TopTop.create(&"DART", 2)

	for case in [
			{"name": "同向自转正面对撞", "wa": SPIN_A, "wb": SPIN_B, "grind": false},
			{"name": "一快一慢正面对撞", "wa": 140.0, "wb": 40.0, "grind": false},
			{"name": "反向自转（啮合）", "wa": 120.0, "wb": -120.0, "grind": false},
			{"name": "贴身对磨（无撞击）", "wa": SPIN_A, "wb": SPIN_B, "grind": true},
			{"name": "纯切向擦过", "wa": SPIN_A, "wb": SPIN_B, "grind": false, "shear": true},
	]:
		var r: Dictionary = _resolve(a, b, float(case["wa"]), float(case["wb"]),
				bool(case["grind"]), bool(case.get("shear", false)))
		_audit(h, a, b, String(case["name"]), float(case["wa"]), float(case["wb"]),
				bool(case.get("shear", false)), r)

	print("")
	print("═══════════════════════════════════════════")
	print("[TOPSCONS] pass = ", h.pass_count(), "   fails = ", h.fail_count())
	for f in h.failures():
		print("  FAIL  ", f)
	print("[TOPSCONS] ", "ALL PASS" if h.fail_count() == 0 else "HAS FAILURES")
	print("═══════════════════════════════════════════")
	a.free()
	b.free()
	quit(1 if h.fail_count() > 0 else 0)


func _resolve(a: TopTop, b: TopTop, spin_a: float, spin_b: float,
		grind: bool, shear: bool) -> Dictionary:
	var n := Vector2(1.0, 0.0)
	var rel: Vector2
	if grind:
		rel = Vector2.ZERO
	elif shear:
		rel = Vector2(0.0, -HIT * 2.0)     # 沿切向错开，没有接近分量
	else:
		rel = Vector2(-HIT * 2.0, 0.0)     # 正面相向
	return TopsSpin.contact_resolve(a.mass_kg, a.radius_m, a.axial_inertia,
			TopsSpin.omega_of(spin_a),
			b.mass_kg, b.radius_m, b.axial_inertia, TopsSpin.omega_of(spin_b),
			n, rel, Vector2.ZERO, Vector2.ZERO,
			TopsSpin.GRIND_BASE_FORCE * 0.0 + (0.50 if grind else 0.0))


## 把求解结果代回真实几何，验两条守恒律
func _audit(h: TestHarness, a: TopTop, b: TopTop, tag: String,
		spin_a: float, spin_b: float, shear: bool, r: Dictionary) -> void:
	var n := Vector2(1.0, 0.0)
	var pa := Vector2.ZERO
	var pb := n * (a.radius_m + b.radius_m)
	var wa: float = TopsSpin.omega_of(spin_a)
	var wb: float = TopsSpin.omega_of(spin_b)
	# 平动初速：由 rel = v_b − v_a 反推，取质心系（总动量为零）最直观
	var rel: Vector2 = Vector2(-HIT * 2.0, 0.0) if not shear else Vector2(0.0, -HIT * 2.0)
	var rel_m: Vector2 = rel * TopsSpin.WU_TO_M * TopsSpin.VEL_GAIN
	var m_tot: float = a.mass_kg + b.mass_kg
	var va: Vector2 = -rel_m * (b.mass_kg / m_tot)
	var vb: Vector2 = rel_m * (a.mass_kg / m_tot)

	var dwa: float = float(r["domega_a"])
	var dwb: float = float(r["domega_b"])
	var dva: Vector2 = (r["dv_a"] as Vector2) * TopsSpin.WU_TO_M * TopsSpin.VEL_GAIN
	var dvb: Vector2 = (r["dv_b"] as Vector2) * TopsSpin.WU_TO_M * TopsSpin.VEL_GAIN

	var p0: Vector2 = a.mass_kg * va + b.mass_kg * vb
	var p1: Vector2 = a.mass_kg * (va + dva) + b.mass_kg * (vb + dvb)
	var l0: float = a.axial_inertia * wa + b.axial_inertia * wb \
			+ _cross(pa, a.mass_kg * va) + _cross(pb, b.mass_kg * vb)
	var l1: float = a.axial_inertia * (wa + dwa) + b.axial_inertia * (wb + dwb) \
			+ _cross(pa, a.mass_kg * (va + dva)) + _cross(pb, b.mass_kg * (vb + dvb))
	var dp: float = (p1 - p0).length()
	var dl: float = l1 - l0
	var scale: float = maxf(absf(l0), 1e-9)

	print("\n  ── %s ──" % tag)
	print("     Δω_a = %+8.2f 点   Δω_b = %+8.2f 点"
			% [TopsSpin.spin_of(dwa), TopsSpin.spin_of(dwb)])
	# ⚠ GDScript 的 % 不支持 %e/%g，小量统一乘 10⁶ 后用 %.3f 打印
	print("     线动量变化 %.3f ×10⁻⁶ kg·m/s（应 ≈ 0）" % [dp * 1e6])
	print("     角动量变化 %+.3f ×10⁻⁶ / 初值 %.3f ×10⁻⁶ = %+.2f%%（应 ≈ 0）"
			% [dl * 1e6, l0 * 1e6, dl / scale * 100.0])

	# 阈值 1e-7（不是 1e-9）：J_t 量级 1e-2，双精度累加噪声就到 1e-9 量级
	h.ck(dp < 1e-7, "%s：线动量守恒（%.3f ×10⁻⁶）" % [tag, dp * 1e6])
	# ⚠ 相对误差给 0.5% 的容忍：Δω 本身是「掉转速」，量级远小于 L0，
	#   这里要抓的是「符号反了」这种 100% 级错误，不是浮点噪声。
	h.ck(absf(dl) / scale < 0.005,
			"%s：角动量守恒（变化 %+.2f%%）" % [tag, dl / scale * 100.0])


func _cross(p: Vector2, v: Vector2) -> float:
	return p.x * v.y - p.y * v.x
