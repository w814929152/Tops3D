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
## ── spin_max 是三者的**平衡砝码**，别乱改 ──
## 碰撞损耗 Δω = J_t/(k·m·r)：RAM 又重又大，挨一下只掉 DART 的 1/4，
## 所以必须用**更少的初始转速**来换；DART 最脆，用**最多的转速**补。
## 两者互相制衡，任一头给多了都会翻盘（2026-09-28 实测，10 局）：
##   · 全部归一成 100  → 制衡消失，RAM 严格更优 → **RAM 90%**、DART 0%
##   · 原型原值 115/100/82 → 自然衰减那头压过碰撞 → **DART 40%**、RAM 0%
## 定档 105 / 102 / 88（2026-09-28，20 局实测胜率：DART 10~20% / BAL 20~35% / RAM 15%）。
## 调这个数字时注意**两股力量相反**，只盯着一头会来回翻盘：
##   给多了（如全部归一成 100）→ 碰撞抗性主导 → RAM 90%
##   给少了（如原型原值 115/100/82）→ 自然衰减主导 → DART 40%、RAM 0%
## 自然寿命指数 = spin_max ÷ (μ /(k·r))，本档为 DART 6827 / BAL 5982 / RAM 5105。
const ARCHETYPES: Dictionary = {
	&"DART": {"mass": 0.7, "radius": 13.0, "max_speed": 250.0, "accel": 1000.0, "turn_rate": 5.2, "spin_max": 105.0, "decay_mult": 1.00, "shape_k": 0.50, "tip_mu": 0.10},
	&"BALANCED": {"mass": 1.0, "radius": 16.0, "max_speed": 285.0, "accel": 700.0, "turn_rate": 4.2, "spin_max": 102.0, "decay_mult": 1.00, "shape_k": 0.55, "tip_mu": 0.15},
	&"RAM": {"mass": 1.6, "radius": 19.0, "max_speed": 320.0, "accel": 430.0, "turn_rate": 3.0, "spin_max": 88.0, "decay_mult": 1.00, "shape_k": 0.58, "tip_mu": 0.19},
}

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
	b.spin_max = float(t["spin_max"])
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
