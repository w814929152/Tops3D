class_name TopsSpin
extends RefCounted
##
## 陀螺「转速损耗」物理层 —— 纯函数 + 纯数值，**零渲染依赖**（headless 可断言）。
##
## TopsRules 管的是玩法结算（冷却、击倒归属、回血、AI）；本文件只回答一件事：
## **这一份自转的转动动能，按物理该掉多少**。每一项都能追到真实的转动动力学：
##
##   转动惯量     I  = k · m · r²          k 形状系数：环/飞轮→1，实心盘 0.5，锥更小
##   摩擦力矩     τ  = μ · N · r_eff
##   气动阻力矩   τ  = ½ · C_m · ρ · ω² · r⁵
##   角冲量       ΔL = J_t · r      →    Δω = ΔL / I
##
## ── 单位标定 ──
## 世界单位（wu）当毫米用：陀螺半径 16 wu = 16 mm、场地半径 250 wu = 25 cm，
## 正是真实战斗陀螺与竞技盘的尺寸量级；质量 1 单位 = 50 g。
## 平移速度游戏里比真实慢（约 1/6），用 VEL_GAIN 折回真实 m/s，碰撞冲量
## J = (1+e)·m_red·u 才落在真实量级。转速 100 ↔ 600 rad/s（≈5700 rpm），
## 也是真陀螺刚发射时的量级。
##
## ── 三条「反直觉但真实」的结论（改数值前先看懂）──
## 1) 轴尖干摩擦里**质量会约掉**：重的陀螺轴尖压得紧（摩擦 ∝ m），转动惯量也大（∝ m），
##    dω/dt = -μ·g·r_eff/(k·r²) 与质量无关。所以「重 = 转得久」是错的，
##    决定自然寿命的是 r 与 k —— 大半径、外圈配重的陀螺才转得久。
## 2) 碰撞里质量**不约掉**：Δω = J_t·r / I = J_t / (k·m·r)，重的陀螺掉得慢得多。
##    实测 RAM 挨一下的转速损失只有 DART 的 1/4 —— 这是质量真正起作用的地方。
## 3) 两颗同向自转的陀螺互磨时，**双方都减速**（摩擦把转动动能磨成热）；
##    反向自转时则趋近「齿轮啮合」，慢的一方反而被带快。模型会自动给出这两种行为。
##

# ── 单位标定 ──
const WU_TO_M := 0.001        # 1 世界单位 = 1 mm
const MASS_UNIT_KG := 0.050   # 1 质量单位 = 50 g
const VEL_GAIN := 6.0         # 游戏平移速度 → 真实速度（游戏是慢放的）
const OMEGA_PER_SPIN := 6.0   # 1 点转速 = 6 rad/s → 转速 100 = 600 rad/s ≈ 5700 rpm
const OMEGA_REF := 600.0      # 满转速参考角速度（用于失稳度归一化）

# ── 环境与材料常数（真实量级）──
const G := 9.81               # 重力加速度 m/s²
const RHO_AIR := 1.20         # 空气密度 kg/m³
const C_M_AIR := 0.05         # 转盘气动阻力矩系数（光滑盘 Re≈10⁴ 量级）
const C_VISC := 0.0015        # 轴承黏性 + 微晃动的等效线性阻尼（1/s）
const TIP_CONTACT_RATIO := 0.035  # 轴尖接触半径 / 陀螺半径（16 mm 的陀螺 → 0.56 mm）
const WOBBLE_GAIN := 1.50     # 低转速失稳 → 轴尖刮擦加重的倍率上限
const RESTITUTION := 0.70     # 恢复系数（与 PhysicsMaterial.bounce 一致）
const MU_CONTACT := 0.35      # 金属攻击环之间的滑动摩擦系数
const MU_WALL := 0.18         # 陀螺轮缘 vs 碗壁的滑动摩擦系数

# 持续挤压：碗壁坡度 + 进动带来的基础挤压力（N），以及挤压力上限（只防病态值）。
# ⚠ 上限不要卡太死：法向压力 N 同时决定「磨掉多少转速」**和**「沿切向搓开多快」，
#   把 N 压小了，两颗被顶在一起的陀螺就搓不开，会出现好几秒不分开的死顶。
#   真实量级参考：两颗 BALANCED 被 AI 全力对推时 N = m_red·a_n ≈ 0.076 N，
#   RAM 互顶约 0.21 N。
const GRIND_BASE_FORCE := 0.010
const GRIND_FORCE_MAX := 0.250

# ── 轴尖摩擦的环境倍率（这两项是物理的，不是手感旋钮）──
static var BOOST_TIP_MULT := 2.0       # 开推进 → 晃动加剧 → 轴尖刮擦倍率
static var EDGE_FRICTION_MULT := 2.0   # 骑上碗壁坡面 → 接触面变大 + 附加坡向力（建模值）

static func reset_tuning() -> void:
	BOOST_TIP_MULT = 2.0
	EDGE_FRICTION_MULT = 2.0


# ══════════════════════════════════════════════════════════
# 一、几何 / 惯量
# ══════════════════════════════════════════════════════════

## 绕自转轴的转动惯量 I = k·m·r²（kg·m²）
## ⚠ 不叫 inertia：RigidBody3D 自带 inertia 属性（惯性张量），会撞名。
static func axial_inertia(m_kg: float, r_m: float, shape_k: float) -> float:
	return shape_k * m_kg * r_m * r_m


## 轴尖接触的等效摩擦半径：圆形接触面上积分 μ·N 的力矩 → (2/3)·r_contact
static func tip_effective_radius(r_m: float) -> float:
	return r_m * TIP_CONTACT_RATIO * (2.0 / 3.0)


## 转速（游戏点数）→ 角速度（rad/s）
static func omega_of(spin: float) -> float:
	return spin * OMEGA_PER_SPIN


## 角速度（rad/s）→ 转速（游戏点数）
static func spin_of(omega: float) -> float:
	return omega / OMEGA_PER_SPIN


## 低转速失稳度：ω 越接近 0，进动/摆头越大，轴尖刮得越狠（真陀螺临停前会哗啦作响）。
## 返回 0（满转速）～1（停转）
static func instability(omega: float) -> float:
	var x: float = clampf(absf(omega) / OMEGA_REF, 0.0, 1.0)
	var s: float = 1.0 - x
	return s * s


# ══════════════════════════════════════════════════════════
# 二、自然衰减
# ══════════════════════════════════════════════════════════

## 自然衰减的角减速度 dω/dt（rad/s²，恒为负）。三项真实机制叠加：
##
##   ① 轴尖与盘面的干摩擦  τ = μ_tip·m·g·r_eff·(1 + WOBBLE_GAIN·失稳度)
##      → dω/dt = -μ·g·r_eff/(k·r²)，**与质量无关**（见文件头结论 1）
##   ② 空气阻力矩          τ = ½·C_m·ρ·ω²·r⁵
##      → dω/dt ∝ -ω²·r³/(k·m)：高速时主导，转速掉下来后按平方律迅速变弱
##   ③ 轴承黏性 / 微晃动    τ = C_visc·I·ω  → dω/dt = -C_visc·ω
##
## tip_mult：骑上碗壁 / 开推进时放大轴尖那一项。
## quality：轴尖品质倍率（性格微调，1.0 = 标准轴尖）。
static func natural_domega(m_kg: float, r_m: float, I: float, tip_mu: float,
		tip_r_eff: float, omega: float, tip_mult: float = 1.0,
		quality: float = 1.0) -> float:
	if I <= 1e-12:
		return 0.0
	var w: float = absf(omega)
	var r2: float = r_m * r_m
	var r5: float = r2 * r2 * r_m
	var tau_tip: float = tip_mu * m_kg * G * tip_r_eff * tip_mult * quality \
			* (1.0 + WOBBLE_GAIN * instability(omega))
	var tau_air: float = 0.5 * C_M_AIR * RHO_AIR * w * w * r5
	var tau_visc: float = C_VISC * I * w
	return -(tau_tip + tau_air + tau_visc) / I


# ══════════════════════════════════════════════════════════
# 三、陀螺互撞 / 对磨
# ══════════════════════════════════════════════════════════

## 一次接触结算，返回 Vector2(Δω_a, Δω_b)（rad/s，可正可负）。
##
##   ① 法向冲量   J_n = (1+e)·m_red·u_n              u_n = 沿法线的**接近**速度
##                持续挤压再补 N·Δt：N = m_red·a_n（驱动把两者压在一起的加速度）
##   ② 接触点相对滑动速度（这是「转速越高磨得越狠」的来源）
##                u_s = 切向平动差 − (ω_a·r_a + ω_b·r_b)
##                自转贡献的轮缘线速度（约 10 m/s）通常是平动差（约 2 m/s）的 5 倍，
##                所以真正决定摩擦方向的几乎总是自转。
##   ③ 切向摩擦冲量 J_t = min(μ·J_n,  K·|u_s|)
##                库仑上限 vs 「完全止滑所需冲量」，K⁻¹ = 1/m_red + r_a²/I_a + r_b²/I_b
##   ④ 角冲量     ΔL = J_t·r  →  Δω = ΔL / I
##
## 参数里 rel_vel / drive_a / drive_b 用**游戏单位**（wu/s、wu/s²），内部折算成 SI。
##
## ⚠ 切向摩擦冲量 J_t 会**同时**作用在自转和平移上，两半都不能丢：
##   · 自转：Δω = J_t·r / I            （磨掉转速）
##   · 平移：A 受 +s·J_t·t̂，B 受 −s·J_t·t̂（把两颗陀螺沿切向**搓开**）
## 只算自转不算平移的话，两颗被外力顶在一起的陀螺会一直贴着磨到停 —— 实测一局里
## 出现过 9 秒不分开的接触段。真实陀螺一接触就被轮缘摩擦搓得边磨边错开，
## 绝不会死死顶住。加上平移那一半之后总动量与总角动量也才守恒
## （两道冲量等大反向、作用在同一点）。
static func contact_resolve(ma: float, ra: float, Ia: float, wa: float,
		mb: float, rb: float, Ib: float, wb: float,
		n: Vector2, rel_vel: Vector2, drive_a: Vector2, drive_b: Vector2,
		press_dt: float) -> Dictionary:
	var out := {
		"domega_a": 0.0, "domega_b": 0.0,
		"dv_a": Vector2.ZERO, "dv_b": Vector2.ZERO,
	}
	var m_red: float = (ma * mb) / maxf(ma + mb, 1e-9)
	var k_conv: float = WU_TO_M * VEL_GAIN

	# ① 法向冲量：一次性撞击
	var u_n: float = maxf(0.0, -rel_vel.dot(n)) * k_conv
	var J_n: float = (1.0 + RESTITUTION) * m_red * u_n
	# ① 续：持续挤压（贴身对磨）—— 把驱动加速度折算成法向力，再乘结算间隔
	if press_dt > 0.0:
		var a_n: float = maxf(0.0, -(drive_b - drive_a).dot(n)) * k_conv
		var N_press: float = minf(m_red * a_n + GRIND_BASE_FORCE, GRIND_FORCE_MAX)
		J_n += N_press * press_dt
	if J_n <= 1e-12:
		return out

	# ② 接触点两面相对滑动（沿切向 t̂ = n 顺时针转 90°）
	var t_hat := Vector2(n.y, -n.x)
	var u_s: float = rel_vel.dot(t_hat) * k_conv - (wa * ra + wb * rb)

	# ③ 切向摩擦冲量（库仑上限 / 止滑所需，取小）
	var inv_k: float = 1.0 / maxf(m_red, 1e-9) \
			+ ra * ra / maxf(Ia, 1e-12) + rb * rb / maxf(Ib, 1e-12)
	var J_t: float = minf(MU_CONTACT * J_n, absf(u_s) / maxf(inv_k, 1e-9))
	if J_t <= 1e-12 or absf(u_s) <= 1e-9:
		return out

	# ④ 摩擦总是阻碍相对滑动：A 受 +s·J_t·t̂ 于 +r_a·n̂，B 受 −s·J_t·t̂ 于 −r_b·n̂，
	#    两者对**各自**自转轴的力矩同号 → 同向自转时双减速，反向时趋近齿轮啮合。
	var s: float = signf(u_s)
	out["domega_a"] = s * J_t * ra / maxf(Ia, 1e-12)
	out["domega_b"] = s * J_t * rb / maxf(Ib, 1e-12)
	# ⑤ 同一道摩擦冲量的平移反作用：A 往 +s·t̂、B 往 −s·t̂ —— 沿切向互相搓开。
	#    除以 k_conv 把 m/s 换回游戏单位 wu/s。
	out["dv_a"] = t_hat * (s * J_t / maxf(ma, 1e-9) / k_conv)
	out["dv_b"] = t_hat * (-s * J_t / maxf(mb, 1e-9) / k_conv)
	return out


## 只要自转变化时的薄封装（测试与只读场景用）
static func contact_domega(ma: float, ra: float, Ia: float, wa: float,
		mb: float, rb: float, Ib: float, wb: float,
		n: Vector2, rel_vel: Vector2, drive_a: Vector2, drive_b: Vector2,
		press_dt: float) -> Vector2:
	var r := contact_resolve(ma, ra, Ia, wa, mb, rb, Ib, wb,
			n, rel_vel, drive_a, drive_b, press_dt)
	return Vector2(float(r["domega_a"]), float(r["domega_b"]))


# ══════════════════════════════════════════════════════════
# 四、撞墙
# ══════════════════════════════════════════════════════════

## 轮缘擦到碗壁的角速度变化（rad/s，通常为负）。墙静止 → 等效质量就是陀螺自身。
## u_n 是撞墙的接近速度（wu/s）。
static func wall_domega(m_kg: float, r_m: float, I: float, omega: float,
		u_n: float) -> float:
	var J_n: float = (1.0 + RESTITUTION) * m_kg * maxf(0.0, u_n) * WU_TO_M * VEL_GAIN
	var u_s: float = omega * r_m      # 轮缘相对墙面的滑动速度
	var 	inv_k: float = 1.0 / maxf(m_kg, 1e-9) + r_m * r_m / maxf(I, 1e-12)
	var J_t: float = minf(MU_WALL * J_n, absf(u_s) / maxf(inv_k, 1e-9))
	if J_t <= 1e-12 or absf(u_s) <= 1e-9:
		return 0.0
	return -signf(u_s) * J_t * r_m / maxf(I, 1e-12)


# ══════════════════════════════════════════════════════════
# 五、低转速失稳：摆头 / 进动 / 章动
# ══════════════════════════════════════════════════════════
##
## 真陀螺不是「越慢越歪」地匀速退化，中间有一道**门槛**：转速高于临界值时它是
## 「睡着」的（轴立得笔直、肉眼看不见晃），掉到临界值以下，直立自转这个解不再
## 稳定，于是三件事一起冒出来：
##
##   ① 摆头     倾斜角 θ 从零长起来，越接近停转越大，最后哗啦一声倒下
##   ② 进动     倾斜的方位绕竖直轴慢慢转圈，Ω = m·g·d / (I·ω)
##              **转得越慢，摆得越快** —— 这就是陀螺临停前越晃越急的原因
##   ③ 章动     叠在进动上的小「点头」，频率 ≈ (I_z/I_x)·ω
##
## ── 临界转速（睡陀螺稳定性判据）──
##   ω_c = 2·sqrt(I_x · m · g · d) / I_z
## I_x 与 I_z 都 ∝ m → **质量照样约掉**（和文件头结论 1 同一个道理：重力矩 ∝ m，
## 惯量也 ∝ m），于是 ω_c ∝ 1/(k·√r)：外圈配重（k 大）、个头大（r 大）的陀螺更稳、
## 更晚开始晃。16 mm 的 BALANCED 算出来 ω_c ≈ 68 rad/s ≈ 11 点转速 —— 真陀螺
## 确实只在最后那几秒才晃，摆起来到停掉往往不到十秒。
##
## ⚠ 这一节只回答「**看上去什么样**」：纯视觉，不参与任何规则判定，也不改转速损耗。
##   低转速对**转速**的影响走的是 instability()（轴尖刮擦加重），两条路各管各的。

## 质心离地高度 / 陀螺半径：七层模型叠出来的重心大致在这个位置（尖头触地起算）
const COM_H_RATIO := 0.72

# ── 视觉参数（只影响画面，不影响物理）──
const WOBBLE_RESIDUAL_DEG := 1.2   # 永远存在的残余不平衡（真陀螺不可能绝对对称）
const WOBBLE_MAX_DEG := 24.0       # 接近停转时的摆角上限
## 摆头「提前量」：严格按 ω_c 的话，16 mm 陀螺要到 11 点转速才开始晃，
## 画面上往往只闪两三秒就看不到了。乘 1.5 只是让失稳**提前可见**，
## 临界转速本身（critical_omega）保持物理原值不变。
const WOBBLE_ONSET_GAIN := 1.5
const WOBBLE_PRECESS_CAP := 6.5    # 进动角速度上限（rad/s）：再快就频闪，看不出在转圈
const WOBBLE_NUT_CAP := 9.0        # 章动频率上限（同上，真值 ≈ ω，快到没法画）
const WOBBLE_NUT_RATIO := 0.35     # 章动幅度 / 摆角


## 质心离轴尖的高度（m）
static func com_height(r_m: float) -> float:
	return r_m * COM_H_RATIO


## 绕**接触点**的横向转动惯量 I_x = ½·k·m·r² + m·d²（平行轴定理）。
## 陀螺是绕轴尖倾倒的，支点不在质心 —— 这一项的 m·d² 不能省。
static func transverse_inertia(m_kg: float, r_m: float, shape_k: float,
		d_m: float) -> float:
	return 0.5 * shape_k * m_kg * r_m * r_m + m_kg * d_m * d_m


## 临界自转角速度（rad/s）：ω > ω_c 直立稳定，ω < ω_c 开始摆头。
## 与质量无关（分子分母的 m 约掉）：ω_c = 2·sqrt(0.72·g·(½k + 0.72²)) / (k·√r)
static func critical_omega(m_kg: float, r_m: float, I_axial: float,
		shape_k: float) -> float:
	if I_axial <= 1e-12:
		return 0.0
	var d: float = com_height(r_m)
	var I_t: float = transverse_inertia(m_kg, r_m, shape_k, d)
	return 2.0 * sqrt(maxf(I_t * m_kg * G * d, 0.0)) / I_axial


## 进动角速度 Ω = m·g·d / (I_z·ω)（rad/s，未加上限）。转得越慢 → 摆得越快。
static func precession_rate(m_kg: float, d_m: float, I_axial: float,
		omega: float) -> float:
	return m_kg * G * d_m / (maxf(I_axial, 1e-12) * maxf(absf(omega), 1e-6))


## 章动角频率 ≈ (I_z / I_x)·ω（rad/s，未加上限）
static func nutation_rate(I_axial: float, I_trans: float, omega: float) -> float:
	return absf(omega) * I_axial / maxf(I_trans, 1e-12)


## 一套完整的低转速姿态（纯数值，渲染层照着摆就行）。返回：
##   tilt     摆角（rad，已含残余不平衡与章动以外的静态部分）
##   nut      章动幅度（rad）：叠在摆角上的小点头
##   precess  进动角速度（rad/s，已加视觉上限）
##   nut_rate 章动角频率（rad/s，已加上限）
##   omega_c  物理临界角速度（rad/s）
##   onset    摆头起始角速度（rad/s）= ω_c × WOBBLE_ONSET_GAIN
static func wobble_state(m_kg: float, r_m: float, I_axial: float, shape_k: float,
		omega: float) -> Dictionary:
	var wc: float = critical_omega(m_kg, r_m, I_axial, shape_k)
	var onset: float = wc * WOBBLE_ONSET_GAIN
	# x：离失稳还有多远（1 = 稳稳睡着，0 = 停转）。u = 1 - x 就是失稳度。
	var x: float = clampf(absf(omega) / maxf(onset, 1e-6), 0.0, 1.0)
	var u: float = 1.0 - x
	# 摆角按 u² 长：刚过门槛时几乎看不出，越接近停转窜得越快（真陀螺就这样）
	var amp_deg: float = WOBBLE_RESIDUAL_DEG \
			+ (WOBBLE_MAX_DEG - WOBBLE_RESIDUAL_DEG) * u * u
	var d: float = com_height(r_m)
	var I_t: float = transverse_inertia(m_kg, r_m, shape_k, d)
	return {
		"tilt": deg_to_rad(amp_deg),
		"nut": deg_to_rad(amp_deg * WOBBLE_NUT_RATIO),
		"precess": minf(precession_rate(m_kg, d, I_axial, omega), WOBBLE_PRECESS_CAP),
		"nut_rate": minf(nutation_rate(I_axial, I_t, omega), WOBBLE_NUT_CAP),
		"omega_c": wc,
		"onset": onset,
	}
