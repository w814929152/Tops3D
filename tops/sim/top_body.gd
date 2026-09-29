class_name TopBody
extends RefCounted
##
## 陀螺个体状态 —— 纯数据 + 纯运动学，**零渲染依赖**（headless 可断言）。
##
## 双轴模型（design/tops/core_mechanic_design.md §4）：
##   A 轴 spin     : float  标量 —— 血量 + 伤害来源，归零即出局
##   B 轴 velocity : Vector2 矢量 —— 动量 p = m·v，决定击飞与位移，归零无惩罚
## 两轴正交：伤害只由 Δspin 决定，击飞只由 Δp 决定（§4.2 必须拍死的地雷）。
##
## 说明：vel / pos 是**水平面** Vector2(x, z)，对应 3D 世界的 XZ 平面。
##

## 三种物理性格（§4.1 拆轴收益）。
##
## shape_k / tip_mu 是**物理层**的固有参数（TopsSpin 用），不是手感旋钮：
##   · shape_k 形状系数 I = k·m·r²：0.5≈实心盘，越大说明重量越靠外圈（飞轮）
##   · tip_mu  轴尖与盘面的滑动摩擦系数：尖而细的轴尖小（转得久），宽而钝的轴尖大
## 转速寿命差异**完全由 m / r / shape_k / tip_mu 推出来**，不再手写 decay 倍率。
##
## ── tip_mu 是**平衡砝码**（2026-09-29，配合能量推导的起手转速）──
## 起手转速由 √(2E/I) 推出来之后，寿命（自然衰减）只能靠 tip_mu 调，它是唯一的寿命旋钮。
## 但 tip_mu 不是随便拍的：**寿命必须递减**（DART 最长、RAM 最短）才能抵消 RAM 的抗撞优势
## （RAM 挨一下只掉 DART 的 1/4）。实测过三种配法：
##   · 全拉平到 90 s  → 「碰撞抗性」独占，RAM 45%、DART 15%
##   · 全部统一 0.15  → 寿命反而递增（86/92/92），RAM 65%、DART 0%
##   · **递减** 104/92/77 s（当前 0.132 / 0.150 / 0.164）→ 复现实测均衡那一版的寿命格局
##     （β=0.40 档位下电脑之间 DART 50% / BAL 27% / RAM 23%，理论 50/25/25）
## 数值由 `tests/tops_mass_probe.gd` 第 ⑩ 节二分反解得到（靶 = 旧手写档位的寿命格局）。
## 这也符合真实产品分工：轻快的攻击型用精密尖轴（转得久但一撞就掉），
## 重型用宽面轴尖（磨得凶，靠抗撞而不是靠耐久吃饭）。
##
## ── 起手转速（2026-09-29 起）：由发射能量推出来，不再是手写档位 ──
## 发射器做的功 E 与装哪颗陀螺无关 → E = ½·I·ω₀² → ω₀ = √(2E/I) ∝ 1/√(k·m·r)。
## 于是**重而大的陀螺起手更慢**（惯量大，同样的功转不快），与碰撞抗性天然形成制衡：
##   RAM 重且大 → 起手慢（吃亏） ＋ 挨打掉得少（占便宜）
## 在此之前 spin_max 是手写档位 105/102/88（2026-09-28），实测胜率
##   DART 10~20% / BAL 20~35% / RAM 15%，但那三个数是拍出来的，没有物理来源。
## 纯等能量（β=0）会拉成 157 / 102 / 66，差距过大 → DART 通吃；
## 计入发射器传动滑移（β=0.40）后是 **132 / 102 / 79**，与手写档位同向、幅度更大。
## ⚠ 改 LAUNCH_ENERGY_J / LAUNCH_SLIP_EXP / shape_k 都会让这一行整体变动，
##   改完必须用 tests/tops_mass_probe.gd 第 ⑩ 节重解 tip_mu，再跑 60 局胜率复核。
## ⚠ 别用 spin_bias 把三者拉平：拉平 = 只留下「碰撞抗性」一头 → RAM 严格更优 → 90%。
## ⚠ 表里**没有** spin_max：起手转速由发射能量 E 与转动惯量 I 推出来（见 derived_spin_max）。
## spin_bias 是唯一的平衡微调旋钮（默认 1.0 = 纯等能量）。
const ARCHETYPES: Dictionary = {
	&"DART": {"mass": 0.7, "radius": 13.0, "max_speed": 250.0, "accel": 1000.0, "turn_rate": 5.2, "decay_mult": 1.00, "shape_k": 0.50, "tip_mu": 0.132, "spin_bias": 1.00},
	&"BALANCED": {"mass": 1.0, "radius": 16.0, "max_speed": 285.0, "accel": 700.0, "turn_rate": 4.2, "decay_mult": 1.00, "shape_k": 0.55, "tip_mu": 0.150, "spin_bias": 1.00},
	&"RAM": {"mass": 1.6, "radius": 19.0, "max_speed": 320.0, "accel": 430.0, "turn_rate": 3.0, "decay_mult": 1.00, "shape_k": 0.58, "tip_mu": 0.164, "spin_bias": 1.00},
}


## 起手转速 = 等发射能量下的起手角速度：E = ½·I·ω₀² → ω₀ = √(2E/I) ∝ 1/√(k·m·r)。
## 重而大的陀螺转动惯量大，同样的功转不快 → **起手转速更低**（真物理如此）。
##
## ⚠ 与「碰撞抗性」是**相反的两头**：RAM 重且大 → 起手慢（吃亏），但挨打掉得少（占便宜）。
##   两头互相制衡，所以不要再用 spin_bias 把三者拉平 —— 拉平就等于把碰撞那一头
##   单独放大，会退回「RAM 严格更优、胜率 90%」的老问题（2026-09-28 实测）。
## 基准原型的转动惯量：β 的参照点，也是发射能量 E 的反算基准（BALANCED 起手 102 点）
static func reference_inertia() -> float:
	var t: Dictionary = ARCHETYPES[&"BALANCED"]
	return TopsSpin.axial_inertia(float(t["mass"]) * TopsSpin.MASS_UNIT_KG,
			float(t["radius"]) * TopsSpin.WU_TO_M, float(t.get("shape_k", 0.55)))


static func derived_spin_max(arch: StringName) -> float:
	var t: Dictionary = ARCHETYPES.get(arch, ARCHETYPES[&"BALANCED"])
	var m_kg: float = float(t["mass"]) * TopsSpin.MASS_UNIT_KG
	var r_m: float = float(t["radius"]) * TopsSpin.WU_TO_M
	var shape_k: float = float(t.get("shape_k", 0.55))
	var inertia: float = TopsSpin.axial_inertia(m_kg, r_m, shape_k)
	return TopsSpin.spin_of(TopsSpin.launch_omega(inertia, reference_inertia())) \
			* float(t.get("spin_bias", 1.0))

var id: int = 0
var archetype: StringName = &"BALANCED"

# ---- 固有属性（不随时间变化）----
var mass: float = 1.0
var radius: float = 16.0
var max_speed: float = 285.0
var accel: float = 700.0
var turn_rate: float = 4.2
var spin_max: float = 100.0
## 自然衰减的性格倍率：转得越猛磨得越快（高转速性格的成本阀门）
var decay_mult: float = 1.0

# ---- A 轴 / B 轴 ----
var spin: float = 100.0
var vel: Vector2 = Vector2.ZERO
var pos: Vector2 = Vector2.ZERO
var facing: float = 0.0

# ---- 输入（由 AI 或玩家写入）----
var input_dir: Vector2 = Vector2.ZERO
var thrusting: bool = true
## 加速：推力变大，但转速额外损耗（双刃剑，服务 Pillar 1 与「时机」决策钩子）
var boosting: bool = false

# ---- 统计 ----
var alive: bool = true
var kills: int = 0
var last_hit_by: int = -1
var wall_cooldown: float = 0.0
var survival_time: float = 0.0


static func create(arch: StringName, p_id: int) -> TopBody:
	var b := TopBody.new()
	var t: Dictionary = ARCHETYPES.get(arch, ARCHETYPES[&"BALANCED"])
	b.id = p_id
	b.archetype = arch
	b.mass = float(t["mass"])
	b.radius = float(t["radius"])
	b.max_speed = float(t["max_speed"])
	b.accel = float(t["accel"])
	b.turn_rate = float(t["turn_rate"])
	b.spin_max = derived_spin_max(arch)
	b.decay_mult = float(t["decay_mult"])
	b.spin = b.spin_max
	return b


func facing_vec() -> Vector2:
	return Vector2.from_angle(facing)


## 动量大小 p = m·v（§4.1 B 轴）
func momentum() -> float:
	return mass * vel.length()


func spin_ratio() -> float:
	return spin / spin_max


func reset_state(p_pos: Vector2, p_facing: float) -> void:
	pos = p_pos
	facing = p_facing
	vel = Vector2.ZERO
	spin = spin_max
	alive = true
	kills = 0
	last_hit_by = -1
	wall_cooldown = 0.0
	survival_time = 0.0
	boosting = false
	input_dir = Vector2.ZERO
	thrusting = true
