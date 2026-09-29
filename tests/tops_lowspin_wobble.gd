extends SceneTree
##
## 低转速下陀螺的「旋转状态」—— 摆头 / 进动 / 章动 的物理与实机验证。
##
## 真陀螺在转速掉到**临界转速** ω_c = 2·sqrt(I_x·m·g·d)/I_z 之前是「睡着」的：
## 轴立得笔直、看不出晃。掉到 ω_c 以下，直立自转不再稳定，于是摆头（θ 长起来）、
## 进动（倾斜方位绕圈，Ω = m·g·d/(I·ω)，**越慢摆得越快**）、章动（小点头）
## 三件事一起冒出来 —— 这就是陀螺临停前那阵「哗啦哗啦」。
##
## 查的是这几件事：
##   ① 临界转速：量级合理、与**质量无关**、个头大/外圈配重的更稳
##   ② 摆角随转速单调增大：满速只有残余不平衡，停转时歪到上限
##   ③ 进动角速度 ∝ 1/ω（并有视觉上限，不会快到频闪）
##   ④ 章动频率 ∝ ω、幅度是摆角的一小部分
##   ⑤ 真机：TopTop 的模型真的绕**轴尖**歪出去（尖头不动）、方位在转、出局接着倒
##   ⑥ 时间轴模拟：从满速自然衰减到停，各个阶段各占多少秒
##
## 跑法：--headless --path D:/Tops3D --script res://tests/tops_lowspin_wobble.gd
##

const STEP := 1.0 / 60.0

var _h: TestHarness
var _world: Node3D


func _initialize() -> void:
	Engine.physics_ticks_per_second = 60
	_h = TestHarness.new()
	await process_frame
	TopsSpin.reset_tuning()

	print("════════ 低转速旋转状态 · 摆头 / 进动 / 章动 ════════")

	_h.suite("① 临界转速 ω_c = 2√(I_x·m·g·d)/I_z")
	_critical(_h)

	_h.suite("② 摆角：转速越低歪得越多")
	_tilt(_h)

	_h.suite("③ 进动 Ω = m·g·d/(I·ω)：越慢摆得越快")
	_precess(_h)

	_h.suite("④ 章动：频率 ∝ ω，幅度是摆角的一小部分")
	_nutation(_h)

	_h.suite("⑤ 真机姿态（真 TopTop + 真模型节点）")
	await _live(_h)

	_h.suite("⑥ 时间轴模拟：满速自然衰减到停")
	_timeline(_h)

	_h.suite("⑦ 低转速三档判定：稳定 / 摆头 / 倾倒")
	_phases(_h)

	_h.suite("⑧ 濒死惩罚：摆头 / 倾倒的陀螺挨打掉得更多（可被补刀）")
	_topple_damage(_h)

	print("")
	print("── 汇总：PASS %d / FAIL %d" % [_h.pass_count(), _h.fail_count()])
	for f in _failures():
		print("   FAIL: ", f)
	quit(1 if _h.fail_count() > 0 else 0)


func _failures() -> Array[String]:
	return _h.failures()


# ══════════════════════════════════════════════════════════
# ⑧ 濒死惩罚（TopsRules.WOBBLE_DAMAGE_MULT）
# ══════════════════════════════════════════════════════════
func _topple_damage(h: TestHarness) -> void:
	var t := TopTop.create(&"BALANCED", 1)
	t.spin = t.spin_max
	h.eq(t.wobble_phase(), TopsSpin.WobblePhase.STEADY, "前置：满转速是「稳定」档")
	h.ck(absf(TopsRules.damage_mult(t) - 1.00) < 1e-6,
			"稳定档伤害倍率 %.2f" % TopsRules.damage_mult(t))

	t.spin = TopsSpin.spin_of(t.omega_crit) * 1.20
	h.eq(t.wobble_phase(), TopsSpin.WobblePhase.WOBBLING, "前置：1.2×ω_c 是「摆头」档")
	h.ck(absf(TopsRules.damage_mult(t) - 1.20) < 1e-6,
			"摆头档伤害倍率 %.2f" % TopsRules.damage_mult(t))

	t.spin = TopsSpin.spin_of(t.omega_crit) * 0.50
	h.eq(t.wobble_phase(), TopsSpin.WobblePhase.TOPPLING, "前置：0.5×ω_c 是「倾倒」档")
	h.ck(absf(TopsRules.damage_mult(t) - 1.50) < 1e-6,
			"倾倒档伤害倍率 %.2f" % TopsRules.damage_mult(t))
	t.free()

	# ── 端到端：同一道冲击，打在稳定 vs 倾倒两种状态上 ──
	# ⚠ 不能直接把转速压到 ω_c 以下做这个对比：倾倒档只剩 11 点，
	#   一道 −4 点的冲击会撞上「钳到 0」的下限，量出来的差额是假的。
	#   改成**把 ω_c 抬高**到 200 点，90 点转速就稳稳落在倾倒档，且不触发钳制。
	var t2 := TopTop.create(&"BALANCED", 2)
	var dmg: float = -TopsSpin.omega_of(4.0)     # 一道 −4 点的冲击
	t2.spin = 90.0
	var loss_steady: float = t2.spin - _after_hit(t2, dmg)
	t2.omega_crit = TopsSpin.omega_of(200.0)    # 强制进入倾倒档
	t2.spin = 90.0
	h.eq(t2.wobble_phase(), TopsSpin.WobblePhase.TOPPLING, "ω_c 抬高后 90 点确实是「倾倒」")
	var loss_topple: float = t2.spin - _after_hit(t2, dmg)
	print("   同一道 −4 点冲击：稳定档掉 %.2f 点，倾倒档掉 %.2f 点（×%.2f）"
			% [loss_steady, loss_topple, loss_topple / maxf(loss_steady, 1e-6)])
	h.ck(loss_topple > loss_steady * 1.40,
			"倾倒档挨同一道冲击掉得更多（%.2f vs %.2f 点）" % [loss_topple, loss_steady])
	h.ck(loss_topple < loss_steady * 1.60,
			"倍率没有失控（×%.2f，设计值 1.50）" % [loss_topple / maxf(loss_steady, 1e-6)])
	t2.free()


## 打一道 Δω，返回打完之后还剩多少点
func _after_hit(t: TopTop, domega: float) -> float:
	TopsRules.apply_domega(t, domega)
	return t.spin


# ══════════════════════════════════════════════════════════
# ⑦ 低转速三档判定
# ══════════════════════════════════════════════════════════
##
## ω_c 是物理分界：ω < ω_c 时「直立自转」这个解不再稳定 → **必然倒**，
## 只是倒下还要几秒。所以「还没归零」≠「还有救」，这一档必须单独认出来，
## 否则玩法层和 UI 只能看到「血还没空」，看不到「已经在倒了」。
func _phases(h: TestHarness) -> void:
	var bal := _phys(&"BALANCED")
	var wc: float = TopsSpin.critical_omega(bal["m"], bal["r"], bal["I"], bal["k"])
	var onset: float = wc * TopsSpin.WOBBLE_ONSET_GAIN
	print("   BALANCED：ω_c = %.1f rad/s（%.1f 点）｜摆头起始 = %.1f 点"
			% [wc, TopsSpin.spin_of(wc), TopsSpin.spin_of(onset)])

	# 三档边界：转速从 0 往上扫，档位只能**单调变好**（倾倒→摆头→稳定），绝不回跳。
	# 反过来也就是「转速往下掉时档位单向恶化」—— 中间不会出现「先倒又站直」的抖动。
	var seen: Array[int] = []
	var monotonic := true
	var prev: int = 99
	for sp in range(0, 220, 4):
		var ph: int = TopsSpin.wobble_phase_of(TopsSpin.omega_of(float(sp)), wc)
		if not seen.has(ph):
			seen.append(ph)
		if ph > prev:
			monotonic = false
		prev = ph
	h.eq(seen.size(), 3, "转速从 0 扫到 220 点，三档都出现过（%s）" % str(seen))
	h.ck(monotonic, "档位随转速**单调**变化，不回跳（0=稳定 1=摆头 2=倾倒）")

	# 具体落点
	var p_full: int = TopsSpin.wobble_phase_of(TopsSpin.omega_of(float(bal["spin_max"])), wc)
	var p_onset: int = TopsSpin.wobble_phase_of(onset * 1.01, wc)
	var p_mid: int = TopsSpin.wobble_phase_of((wc + onset) * 0.5, wc)
	var p_crit: int = TopsSpin.wobble_phase_of(wc * 0.99, wc)
	var p_zero: int = TopsSpin.wobble_phase_of(0.0, wc)
	h.eq(p_full, TopsSpin.WobblePhase.STEADY, "满转速判定为「稳定」")
	h.eq(p_onset, TopsSpin.WobblePhase.STEADY, "刚过摆头起始仍是「稳定」")
	h.eq(p_mid, TopsSpin.WobblePhase.WOBBLING, "ω_c 与起始之间判定为「摆头」")
	h.eq(p_crit, TopsSpin.WobblePhase.TOPPLING, "掉到 ω_c 以下判定为「倾倒」")
	h.eq(p_zero, TopsSpin.WobblePhase.TOPPLING, "停转判定为「倾倒」")

	# 「还有血 ≠ 还有救」：这一档的关键价值就在这里
	var spin_at_crit: float = TopsSpin.spin_of(wc)
	h.ck(spin_at_crit > 1.0,
			"倾倒档的转速还剩 %.1f 点（>0）—— 血没空但已经在倒了，光看血量看不出来"
					% spin_at_crit)

	# 结构无关：三原型的 ω_c 不同，但**按 ω/ω_c 归一**后档位必须一致
	var same := true
	for arch in [&"DART", &"BALANCED", &"RAM"]:
		var ph2: Dictionary = _phys(arch)
		var wc2: float = TopsSpin.critical_omega(ph2["m"], ph2["r"], ph2["I"], ph2["k"])
		if TopsSpin.wobble_phase_of(wc2 * 0.5, wc2) != TopsSpin.WobblePhase.TOPPLING:
			same = false
		if TopsSpin.wobble_phase_of(wc2 * 1.2, wc2) != TopsSpin.WobblePhase.WOBBLING:
			same = false
		if TopsSpin.wobble_phase_of(wc2 * 2.0, wc2) != TopsSpin.WobblePhase.STEADY:
			same = false
	h.ck(same, "三个原型按 ω/ω_c 归一后档位一致（判定只认比例，不认绝对转速）")

	# 真机：TopTop 上的包装能取到，且和物理层一致
	var t := TopTop.create(&"BALANCED", 1)
	t.spin = t.spin_max
	h.eq(t.wobble_phase(), TopsSpin.WobblePhase.STEADY,
			"真机 TopTop 满转速 → 稳定（%s）" % t.wobble_phase_name())
	t.spin = TopsSpin.spin_of(t.omega_crit) * 0.5
	h.eq(t.wobble_phase(), TopsSpin.WobblePhase.TOPPLING,
			"真机 TopTop 半临界转速 → 倾倒（%s）" % t.wobble_phase_name())
	t.spin = 0.0
	h.eq(t.wobble_phase(), TopsSpin.WobblePhase.TOPPLING, "真机 TopTop 停转 → 倾倒")
	t.free()


# ══════════════════════════════════════════════════════════
# 工具
# ══════════════════════════════════════════════════════════

## 把某种性格的物理量取出来（SI）
func _phys(arch: StringName) -> Dictionary:
	var p: Dictionary = TopBody.ARCHETYPES[arch]
	var m: float = float(p["mass"]) * TopsSpin.MASS_UNIT_KG
	var r: float = float(p["radius"]) * TopsSpin.WU_TO_M
	var k: float = float(p["shape_k"])
	return {
		"m": m, "r": r, "k": k,
		"I": TopsSpin.axial_inertia(m, r, k),
		# ⚠ ARCHETYPES 里已经没有 spin_max 了（2026-09-29 起由发射能量推导）
		"spin_max": TopBody.derived_spin_max(arch),
	}


## 摆角（度）
func _tilt_deg(ph: Dictionary, spin: float) -> float:
	var w: Dictionary = TopsSpin.wobble_state(ph["m"], ph["r"], ph["I"], ph["k"],
			TopsSpin.omega_of(spin))
	return rad_to_deg(float(w["tilt"]))


func _state(ph: Dictionary, spin: float) -> Dictionary:
	return TopsSpin.wobble_state(ph["m"], ph["r"], ph["I"], ph["k"],
			TopsSpin.omega_of(spin))


# ══════════════════════════════════════════════════════════
# ① 临界转速
# ══════════════════════════════════════════════════════════
func _critical(h: TestHarness) -> void:
	var dart := _phys(&"DART")
	var bal := _phys(&"BALANCED")
	var ram := _phys(&"RAM")
	var wc: Dictionary = {}
	for pair in [["DART", dart], ["BALANCED", bal], ["RAM", ram]]:
		var ph: Dictionary = pair[1]
		var w: float = TopsSpin.critical_omega(ph["m"], ph["r"], ph["I"], ph["k"])
		wc[pair[0]] = w
		print("   %-9s ω_c=%6.1f rad/s = %5.1f 点转速（占满速 %4.1f%%）"
				% [pair[0], w, TopsSpin.spin_of(w),
				TopsSpin.spin_of(w) / ph["spin_max"] * 100.0])

	for a in wc:
		var v: float = wc[a]
		h.ck(v > 40.0 and v < 120.0, "%s 的 ω_c = %.1f rad/s 落在真实量级（40~120）"
				% [a, v])

	# 质量**约掉**：重力矩 ∝ m、惯量 ∝ m → ω_c 与质量无关
	var w1: float = TopsSpin.critical_omega(bal["m"], bal["r"], bal["I"], bal["k"])
	var w2: float = TopsSpin.critical_omega(bal["m"] * 2.0, bal["r"],
			TopsSpin.axial_inertia(bal["m"] * 2.0, bal["r"], bal["k"]), bal["k"])
	print("   质量翻倍: ω_c %.6f → %.6f" % [w1, w2])
	h.ck(absf(w2 - w1) < 0.01 * maxf(w1, 1e-6),
			"ω_c 与质量无关（%.3f vs %.3f，差 <1%%）" % [w1, w2])

	# 结构 ω_c ∝ 1/(k·√r)：把 k·√r 乘回去，三者应当几乎相等
	var prod: Array[float] = []
	for pair in [["DART", dart], ["BALANCED", bal], ["RAM", ram]]:
		var ph: Dictionary = pair[1]
		prod.append(float(wc[pair[0]]) * ph["k"] * sqrt(ph["r"]))
	print("   ω_c·k·√r = ", _f3(prod[0]), " / ", _f3(prod[1]), " / ", _f3(prod[2]))
	h.ck(prod.max() / prod.min() < 1.05,
			"ω_c ∝ 1/(k·√r)（乘回去三者相差 <5%）")

	# 小而轻（r 小、k 小）的先开始晃
	h.ck(float(wc["DART"]) > float(wc["BALANCED"])
			and float(wc["BALANCED"]) > float(wc["RAM"]),
			"个头大、外圈配重的更稳（DART > BALANCED > RAM）")


# ══════════════════════════════════════════════════════════
# ② 摆角
# ══════════════════════════════════════════════════════════
func _tilt(h: TestHarness) -> void:
	var bal := _phys(&"BALANCED")
	var spins: Array[float] = [100.0, 80.0, 60.0, 40.0, 30.0, 20.0, 15.0,
			10.0, 6.0, 3.0, 1.0, 0.0]
	var prev: float = -1.0
	var mono := true
	for s in spins:
		var d: float = _tilt_deg(bal, s)
		if d < prev - 1e-9:
			mono = false
		prev = d
	print("   BALANCED: ", _f1(_tilt_deg(bal, 100.0)), "°(100) → ",
			_f1(_tilt_deg(bal, 20.0)), "°(20) → ", _f1(_tilt_deg(bal, 10.0)),
			"°(10) → ", _f1(_tilt_deg(bal, 6.0)), "°(6) → ",
			_f1(_tilt_deg(bal, 3.0)), "°(3) → ", _f1(_tilt_deg(bal, 0.0)), "°(0)")
	h.ck(mono, "转速越低摆角越大（单调不减）")
	h.ck(_tilt_deg(bal, 100.0) <= 2.0,
			"满转速几乎直立（残余不平衡 %.2f° ≤ 2°）" % _tilt_deg(bal, 100.0))
	h.ck(_tilt_deg(bal, 30.0) <= 2.0,
			"三成转速还没开始晃（%.2f° ≤ 2°）" % _tilt_deg(bal, 30.0))
	h.ck(absf(_tilt_deg(bal, 0.0) - TopsSpin.WOBBLE_MAX_DEG) < 0.5,
			"停转瞬间歪到上限 %.1f°（实际 %.2f°）"
					% [TopsSpin.WOBBLE_MAX_DEG, _tilt_deg(bal, 0.0)])
	h.ck(_tilt_deg(bal, 6.0) > 8.0,
			"临停前摆角已经很明显（6 点时 %.2f° > 8°）" % _tilt_deg(bal, 6.0))


# ══════════════════════════════════════════════════════════
# ③ 进动
# ══════════════════════════════════════════════════════════
func _precess(h: TestHarness) -> void:
	var bal := _phys(&"BALANCED")
	var d: float = TopsSpin.com_height(bal["r"])
	# 原始公式严格 ∝ 1/ω
	var o1: float = TopsSpin.precession_rate(bal["m"], d, bal["I"], 200.0)
	var o2: float = TopsSpin.precession_rate(bal["m"], d, bal["I"], 100.0)
	print("   原始 Ω: ω=200 → %s rad/s，ω=100 → %s rad/s" % [_f3(o1), _f3(o2)])
	h.ck(absf(o2 / o1 - 2.0) < 1e-6, "Ω ∝ 1/ω（ω 减半 → Ω 加倍，实测 %.4f 倍）"
			% [o2 / o1])

	# 实际用的那一份带视觉上限，且随转速单调加快（转速越低越快）
	var prev: float = -1.0
	var mono := true
	var capped := true
	for s in [100.0, 60.0, 40.0, 20.0, 15.0, 10.0, 6.0, 3.0, 1.0, 0.0]:
		var w: Dictionary = _state(bal, s)
		var om: float = float(w["precess"])
		if om > TopsSpin.WOBBLE_PRECESS_CAP + 1e-9:
			capped = false
		if om < prev - 1e-9:
			mono = false
		prev = om
	print("   实际 Ω: 100→%s  20→%s  10→%s  6→%s  3→%s  0→%s rad/s"
			% [_f2(float(_state(bal, 100.0)["precess"])),
			_f2(float(_state(bal, 20.0)["precess"])),
			_f2(float(_state(bal, 10.0)["precess"])),
			_f2(float(_state(bal, 6.0)["precess"])),
			_f2(float(_state(bal, 3.0)["precess"])),
			_f2(float(_state(bal, 0.0)["precess"]))])
	h.ck(mono, "转速越低进动越快（单调不减）")
	h.ck(capped, "进动被视觉上限 %.1f rad/s 夹住（60fps 下不会频闪）"
			% TopsSpin.WOBBLE_PRECESS_CAP)
	h.ck(float(_state(bal, 0.0)["precess"]) >= TopsSpin.WOBBLE_PRECESS_CAP - 1e-9,
			"停转前进动已顶到上限（转得越慢摆得越快，画面上最急）")


# ══════════════════════════════════════════════════════════
# ④ 章动
# ══════════════════════════════════════════════════════════
func _nutation(h: TestHarness) -> void:
	var bal := _phys(&"BALANCED")
	var d: float = TopsSpin.com_height(bal["r"])
	var I_t: float = TopsSpin.transverse_inertia(bal["m"], bal["r"], bal["k"], d)
	var n1: float = TopsSpin.nutation_rate(bal["I"], I_t, 100.0)
	var n2: float = TopsSpin.nutation_rate(bal["I"], I_t, 200.0)
	h.ck(absf(n2 / n1 - 2.0) < 1e-6, "章动频率 ∝ ω（实测 %.4f 倍）" % [n2 / n1])

	var w10: Dictionary = _state(bal, 10.0)
	var tilt10: float = rad_to_deg(float(w10["tilt"]))
	var nut10: float = rad_to_deg(float(w10["nut"]))
	print("   10 点转速: 摆角 %s° + 章动 ±%s°，点头频率 %s rad/s"
			% [_f1(tilt10), _f1(nut10), _f2(float(w10["nut_rate"]))])
	h.ck(absf(nut10 - tilt10 * TopsSpin.WOBBLE_NUT_RATIO) < 0.01,
			"章动幅度 = %.0f%% 摆角（%.2f° vs %.2f°）"
					% [TopsSpin.WOBBLE_NUT_RATIO * 100.0, nut10,
					tilt10 * TopsSpin.WOBBLE_NUT_RATIO])
	h.ck(float(w10["nut_rate"]) <= TopsSpin.WOBBLE_NUT_CAP + 1e-9,
			"章动频率有上限 %.1f rad/s（真值 ≈ ω，画不出来）" % TopsSpin.WOBBLE_NUT_CAP)


# ══════════════════════════════════════════════════════════
# ⑤ 真机姿态
# ══════════════════════════════════════════════════════════
func _live(h: TestHarness) -> void:
	_new_world()
	var t := TopTop.create(&"BALANCED", 1)
	t.model = TopsModel.build(t)
	t.add_child(t.model)
	t.freeze = true            # 只看姿态，不让它漂移
	t.set_collides(false)
	_world.add_child(t)
	t.set_plane_pos(Vector2(0.0, 0.0))
	t.spin = 100.0
	for _i in 8:
		await process_frame
	var tilt_hi: float = _axis_tilt(t)
	print("   满转速实机摆角 %s°" % _f1(rad_to_deg(tilt_hi)))
	h.ck(rad_to_deg(tilt_hi) <= 2.0,
			"满转速时模型基本直立（%.2f°）" % rad_to_deg(tilt_hi))

	# 掉到临停区间
	t.spin = 5.0
	for _i in 20:
		await process_frame
	var tilt_lo: float = _axis_tilt(t)
	print("   5 点转速实机摆角 %s°（理论 %s°）"
			% [_f1(rad_to_deg(tilt_lo)), _f1(_tilt_deg(_phys(&"BALANCED"), 5.0))])
	h.ck(rad_to_deg(tilt_lo) > 8.0,
			"低转速时模型真的歪出去了（%.2f° > 8°）" % rad_to_deg(tilt_lo))

	# 支点是轴尖：模型容器原点必须原地不动（整串旋转只改朝向）
	h.ck(t.model.position.length() < 1e-6,
			"摆头绕**轴尖**旋转（模型原点位移 %.6f ≈ 0）" % t.model.position.length())

	# 进动：倾斜的方位在绕竖直轴转圈
	var az0: float = _azimuth(t)
	for _i in 12:
		await process_frame
	var az1: float = _azimuth(t)
	var daz: float = absf(wrapf(az1 - az0, -PI, PI))
	print("   进动方位 12 帧转过 %s°" % _f1(rad_to_deg(daz)))
	h.ck(daz > 0.02, "倾斜方位在进动（12 帧转过 %.2f°）" % rad_to_deg(daz))

	# 出局：从当时歪着的角度接着倒，最后躺平
	t.kill()
	Engine.time_scale = 20.0
	for _i in 60:
		await process_frame
	Engine.time_scale = 1.0
	var tilt_dead: float = _axis_tilt(t)
	print("   出局后躺平角度 %s°" % _f1(rad_to_deg(tilt_dead)))
	h.ck(rad_to_deg(tilt_dead) > 80.0,
			"出局后倒地躺平（轴与竖直方向 %.1f°）" % rad_to_deg(tilt_dead))
	_free_world()


func _new_world() -> void:
	_world = Node3D.new()
	root.add_child(_world)


func _free_world() -> void:
	if _world != null and is_instance_valid(_world):
		_world.free()
		_world = null


## 模型自身轴（局部 +Y）与世界上方的夹角 = 摆角
func _axis_tilt(t: TopTop) -> float:
	var up: Vector3 = t.model.global_transform.basis.y.normalized()
	return acos(clampf(up.dot(Vector3.UP), -1.0, 1.0))


## 倾斜方位（模型自转轴的水平投影方向角）
func _azimuth(t: TopTop) -> float:
	var up: Vector3 = t.model.global_transform.basis.y.normalized()
	return Vector2(up.x, up.z).angle()


# ══════════════════════════════════════════════════════════
# ⑥ 时间轴模拟
# ══════════════════════════════════════════════════════════
func _timeline(h: TestHarness) -> void:
	var bal := _phys(&"BALANCED")
	var tip_mu: float = float(TopBody.ARCHETYPES[&"BALANCED"]["tip_mu"])
	var tip_r: float = TopsSpin.tip_effective_radius(bal["r"])
	var spin: float = 100.0
	var time: float = 0.0
	var t_wobble: float = -1.0      # 摆角首次 ≥ 3°
	var t_big: float = -1.0         # 摆角首次 ≥ 12°
	var t_stop: float = -1.0
	var log: Array[String] = []
	var next_log: float = 0.0

	var guard := 0
	while spin > 0.0 and guard < 60 * 400:
		guard += 1
		var w: Dictionary = _state(bal, spin)
		var td: float = rad_to_deg(float(w["tilt"]))
		if t_wobble < 0.0 and td >= 3.0:
			t_wobble = time
		if t_big < 0.0 and td >= 12.0:
			t_big = time
		if time >= next_log and spin <= 20.0:
			log.append("      t=%5.1fs  spin=%5.1f  摆角=%5.1f°  进动=%4.1f rad/s"
					% [time, spin, td, float(w["precess"])])
			next_log = time + 1.0
		var dw: float = TopsSpin.natural_domega(bal["m"], bal["r"], bal["I"],
				tip_mu, tip_r, TopsSpin.omega_of(spin), 1.0, 1.0)
		spin = maxf(0.0, spin + TopsSpin.spin_of(dw * TopsRules.NATURAL_LOSS_SCALE)
				* STEP)
		time += STEP

	t_stop = time
	print("   自然衰减时间轴（BALANCED，纯自然衰减不计碰撞）：")
	print("      满速 → 开始晃(3°):  %s s" % _f1(t_wobble))
	print("      开始晃 → 明显晃(12°): %s s" % _f1(t_big - t_wobble))
	print("      明显晃 → 停:        %s s" % _f1(t_stop - t_big))
	print("      总寿命:             %s s" % _f1(t_stop))
	for line in log:
		print(line)

	h.ck(t_wobble > 0.0, "自然衰减最终会晃起来（t=%s s）" % _f1(t_wobble))
	h.ck(t_stop - t_wobble > 3.0, "摆头阶段至少持续 3 秒（%.1f s，看得见）"
			% (t_stop - t_wobble))
	h.ck(t_wobble / t_stop > 0.6, "大半个生命周期都是直立「睡着」的（%.0f%%）"
			% (t_wobble / t_stop * 100.0))


# ── 打印小工具 ──
func _f1(v: float) -> String:
	return "%.1f" % v


func _f2(v: float) -> String:
	return "%.2f" % v


func _f3(v: float) -> String:
	return "%.3f" % v
