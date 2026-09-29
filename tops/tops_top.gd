class_name TopTop
extends RigidBody3D
##
## 陀螺实体（真 3D）：平移运动与碰撞交给 Godot 内置物理
## （RigidBody3D + CCD + PhysicsMaterial），转速（血量/伤害来源）由 TopsRules 结算。
## 自转朝向由本文件自管（lock_rotation）。
##
## 玩法约束（用户拍板）：**进场之后玩家不能操控**，陀螺只靠
##   ① 发射时给的那一下初速度
##   ② 自转进动漂移（真实陀螺会自己晃着走，也避免它静止变成靶子）
##   ③ 物理碰撞与弹开
## 主动推进（thrusting）只留给 AI 对手；玩家陀螺进场后 thrusting 恒为 false。
##
## 3D 化说明：竞技场是水平面（XZ 平面）。逻辑位置/速度都是 Vector2(x, z)，
## 通过 plane_pos / plane_vel 与 RigidBody3D 的 global_position / linear_velocity
## 互转；高度 y 固定为 TOP_Y，只影响渲染高低，不参与规则判定。
##

## 转速变化（用于 HUD 与反馈）
signal spin_changed(new_spin: float)
## 出局
signal died(top: TopTop)

## 陀螺顶面相对地面的固定高度（3D 世界里所有陀螺都在同一水平面上转）
const TOP_Y := 0.0

## 进动漂移强度（相对 accel 的比例）
const DRIFT_ACCEL_RATIO := 0.16
## 漂移只把陀螺推到上限速度的这个比例。
## ⚠ 2026-09-28 改：AI 撤掉主动推进后，漂移是全场**唯一**的自驱力，
##   35% 太懒 —— 陀螺在中心慢慢磨、够不到边缘、对局拖到 90 s 以上。
##   55% 让它们能扫到大半个场子，撞墙弹开才重新有戏（不至于变成主动 AI：
##   漂移方向是缓慢自转的进动相位，不是朝目标的追踪）。
const DRIFT_SPEED_CAP := 0.55

var top_id: int = 0
var archetype: StringName = &"BALANCED"

# ── 物理量（SI，由 TopsSpin 标定，见 tops/tops_spin.gd）──
## 质量（kg）= 质量单位 × 50 g
var mass_kg: float = 0.050
## 轮缘半径（m）= 世界半径（mm）× 1e-3
var radius_m: float = 0.016
## 形状系数：I = k·m·r²，重量越靠外圈越大
var shape_k: float = 0.55
## 绕自转轴的转动惯量（kg·m²）—— 转速损耗的「分母」，一切损耗都除以它
var axial_inertia: float = 0.0
## 轴尖与盘面的滑动摩擦系数
var tip_mu: float = 0.15
## 轴尖接触等效摩擦半径（m）
var tip_r_eff: float = 0.001
## 本物理步**碰撞求解前**的平面速度 —— 碰撞结算要的是「接近速度」，
## 而 body_entered 送达时求解器已经把两球弹开，当场读到的永远是「正在分离」。
var vel_prev: Vector2 = Vector2.ZERO
## 内部：上一物理步结束时的速度。⚠ Godot 的 _integrate_forces 是在**求解之后**
## 调用的（实测对撞当帧读到的已经是弹开后的速度），所以只能用「上一步的末速度」
## 当作本步求解前的速度 —— 两者之间没有任何东西会改它。
var vel_post: Vector2 = Vector2.ZERO
## 本步的驱动加速度（wu/s²，进动漂移或 AI 推进）—— 折算持续挤压的法向力
var drive_accel: Vector2 = Vector2.ZERO

# ── 逻辑属性 ──
var spin: float = 100.0
## 原型的标称转速上限（平衡砝码，见 TopBody.ARCHETYPES）——UI 进度条的分母
var spin_max: float = 100.0
## 本局**实际**的转速上限 = 初始转速（可能带随机浮动，见 TopsMain.AI_SPIN_RANGE）。
## 击杀回血要按它封顶：否则随机到高于 spin_max 的陀螺一击杀就被 minf 打回标称值，
## 随机浮动等于白给。
var spin_cap: float = 100.0
## 轴尖品质倍率（1.0 = 标准轴尖；性格差异已由 m/r/shape_k/tip_mu 表达）
var decay_mult: float = 1.0
var boosting: bool = false
var input_dir: Vector2 = Vector2.ZERO
var thrusting: bool = false
var facing: float = 0.0
var alive: bool = true
var kills: int = 0
var last_hit_by: int = -1
var wall_cooldown: float = 0.0
## 撞完之后的「松劲」计时（秒）：>0 时 AI 不再朝对手直冲，改为绕行。
## 没有它的话，两家 AI 会撞完立刻又全力顶上去，画面上就是黏在一起不分开
## （实测贴身段里推进占比 100%、挤压 917 wu/s²）。
var disengage: float = 0.0
var contacts: int = 0
var wall_hits: int = 0
var last_contact: Dictionary = {}

# ── 手感属性 ──
var move_speed: float = 285.0
var accel: float = 700.0
var turn_rate: float = 4.2
var top_radius: float = 16.0

## 速度硬上限倍率（§5：封顶防「炮弹失控」）。混战中陀螺被弹性碰撞反复加速时，
## 强制削平到 move_speed×此值，防止逃逸出场。3D 物理解算比 2D 更弹，需要显式钳制。
const MAX_SPEED_MULT := 1.8

## 平动阻尼（1/s）。见 create() 里的说明：随「AI 撤掉主动推进」一起下调。
const LINEAR_DAMP := 0.22

# ── 进动漂移（发射后唯一的自驱力）──
var drift_phase: float = 0.0
var drift_rate: float = 0.55

var trail: Array[Vector2] = []

## 视觉模型容器（由 TopsModel.build() 搭建，本文件只负责驱动它自转/倒下）
var model: Node3D

## 满转速时的视觉自转角速度（rad/s）。纯视觉，不参与任何规则判定。
##
## ⚠ 上限受**频闪**约束：陀螺有 8 个齿，转 360/8 = 45° 看上去和没转一样。
## 60 fps 下每帧转过的角度必须小于半个周期（22.5°），否则会看到倒转或静止的混叠。
## 22.5°/帧 → 23.6 rad/s 是硬上限，这里取 20 rad/s（19.1°/帧）留安全余量。
const VISUAL_SPIN_RATE := 20.0
## 出局后倒地的角速度（rad/s）
const FALL_RATE := 3.2

## 物理临界角速度（rad/s）：ω 掉到它以下，直立自转不再稳定 → 开始摆头。
## 由 create() 按 m / r / shape_k 算好（TopsSpin.critical_omega）。
var omega_crit: float = 0.0
## 视觉姿态的三个相位 —— 自转（绕自身轴）/ 进动（倾斜方位绕竖直轴转圈）/
## 章动（叠在摆角上的小点头）。用四元数合成，见 _process。
var _spin_angle: float = 0.0
var _precess_phase: float = 0.0
var _nut_phase: float = 0.0
## 当前摆角（rad）。出局倒地时从它接着往下倒，不从直立弹回去。
var _tilt_now: float = 0.0
var _fall_angle: float = 0.0

## ── 出局后的退场：倒地躺一会儿 → 一边下沉一边缩小 → 从场景里清掉 ──
const DESPAWN_HOLD := 1.20   # 倒地后停留（秒），让人看清是谁停了
const DESPAWN_FADE := 0.90   # 下沉 + 缩小的时长（秒）
const DESPAWN_SINK := 26.0   # 下沉深度（世界单位）
## 退场播完 → main 把它从 _tops 摘掉并 queue_free
var despawn_done: bool = false
var _dead_t: float = 0.0


static func create(arch: StringName, p_id: int) -> TopTop:
	var t := TopTop.new()
	var p: Dictionary = TopBody.ARCHETYPES.get(arch, TopBody.ARCHETYPES[&"BALANCED"])
	t.top_id = p_id
	t.archetype = arch
	t.name = "Top%d" % p_id
	t.mass = float(p["mass"])
	t.top_radius = float(p["radius"])
	t.move_speed = float(p["max_speed"])
	t.accel = float(p["accel"])
	t.turn_rate = float(p["turn_rate"])
	# 起手转速由发射能量 × 转动惯量推出来（等能量假定），不是手写常量
	t.spin_max = TopBody.derived_spin_max(arch)
	t.decay_mult = float(p["decay_mult"])
	t.spin = t.spin_max
	t.spin_cap = t.spin_max
	t.drift_phase = randf() * TAU
	t.drift_rate = 0.42 + randf() * 0.36

	# ── 物理量：转速损耗全部由 m / r / I 推出来 ──
	t.mass_kg = t.mass * TopsSpin.MASS_UNIT_KG
	t.radius_m = t.top_radius * TopsSpin.WU_TO_M
	t.shape_k = float(p.get("shape_k", 0.55))
	t.tip_mu = float(p.get("tip_mu", 0.15))
	t.axial_inertia = TopsSpin.axial_inertia(t.mass_kg, t.radius_m, t.shape_k)
	t.tip_r_eff = TopsSpin.tip_effective_radius(t.radius_m)
	t.omega_crit = TopsSpin.critical_omega(t.mass_kg, t.radius_m, t.axial_inertia,
			t.shape_k)
	t._precess_phase = randf() * TAU   # 每颗陀螺的初始倾倒方位随机，别整整齐齐一起歪

	# ── 物理：真实碰撞判断交给引擎（3D）──
	t.gravity_scale = 0.0                       # ⚠ 水平竞技场没有重力，默认会让陀螺往下掉
	t.can_sleep = false                         # ⚠ 睡着了 apply_force 不生效，操控/漂移会失灵
	t.lock_rotation = true                      # 朝向自管，不让碰撞把本体打转
	# 平动阻尼。⚠ 2026-09-28 改：AI 撤掉主动推进后，全场只剩发射动能 + 漂移，
	#   0.80 会把发射初速在几秒内吃光（300 → 88 wu/s），陀螺飘到一半就停死，
	#   再也够不到边缘（实测撞墙 0 次）、对局拖成「比谁自然寿命长」。
	#   物理上真陀螺的平动衰减本来就慢 —— 轴尖摩擦磨的是**自转**（走 TopsSpin），
	#   不是平动。所以降到 0.22：发射动能能撑满一局，撞墙弹开才重新玩得起来。
	t.linear_damp = LINEAR_DAMP
	t.angular_velocity = Vector3.ZERO
	t.continuous_cd = true                      # 防高速穿透（Godot 4：布尔属性）
	t.contact_monitor = true
	t.max_contacts_reported = 8
	# 恢复系数 = 对撞弹性的**主来源**（规则层只兜「死顶」，不制造正常对撞的弹开）。
	# 2026-09-29：0.70 → 0.85，配合墙的 0.90，让对撞与撞墙都有明确的冲击反弹。
	# ⚠ 别碰 friction：0.15 是轮缘互磨的手感，调高会让两颗陀螺黏住互相刮。
	var pm := PhysicsMaterial.new()
	pm.bounce = 0.85
	pm.friction = 0.15
	t.physics_material_override = pm

	var cs := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = t.top_radius
	cs.shape = sphere
	t.add_child(cs)

	t.body_entered.connect(t._on_body_entered)
	return t


## 逻辑平面位置 Vector2(x, z)（供规则层与 main 使用）
func plane_pos() -> Vector2:
	return Vector2(global_position.x, global_position.z)


## 把逻辑平面位置写回（保持 y = TOP_Y 不变）
func set_plane_pos(p: Vector2) -> void:
	global_position = Vector3(p.x, TOP_Y, p.y)


## 逻辑平面速度 Vector2(vx, vz)
func plane_vel() -> Vector2:
	return Vector2(linear_velocity.x, linear_velocity.z)


## 当前自转角速度（rad/s）—— 物理层一律用它算损耗，spin 只是它的显示刻度
func omega() -> float:
	return TopsSpin.omega_of(spin)


## 发射阶段：陀螺在场地边缘待命，先不参与碰撞（免得还没发射就互相挤）
func set_collides(on: bool) -> void:
	collision_mask = 1 if on else 0


## 视觉tick：活着就按转速比例自转，**并在低转速下摆头 / 进动 / 章动**；
## 出局则顺着当时倾斜的方位倒地。用 _process 而非 _physics_process ——
## 这是渲染表现，跟着显示帧率走。
##
## 姿态是三层四元数合成（右乘先作用，从内到外）：
##   q = Q(竖直轴, 进动方位 φ) · Q(水平轴, 摆角 θ) · Q(自身轴, 自转角 ψ)
## 模型容器的原点就是**轴尖**（TopsModel 从 y=0 往上叠），所以整串旋转的支点
## 天然落在触地点上 —— 摆头时尖头钉在原地，身子歪出去，和真陀螺一样。
func _process(delta: float) -> void:
	if model == null:
		return
	if alive:
		var ratio: float = clampf(spin / maxf(spin_max, 1.0), 0.0, 1.0)
		_spin_angle += VISUAL_SPIN_RATE * ratio * delta
		var w: Dictionary = TopsSpin.wobble_state(mass_kg, radius_m, axial_inertia,
				shape_k, omega())
		_precess_phase += float(w["precess"]) * delta
		_nut_phase += float(w["nut_rate"]) * delta
		# 章动是叠在摆角上的小点头（θ 上下各 nut 幅度）
		_tilt_now = float(w["tilt"]) + float(w["nut"]) * sin(_nut_phase)
		model.quaternion = Quaternion(Vector3.UP, _precess_phase) \
				* Quaternion(Vector3.RIGHT, _tilt_now) \
				* Quaternion(Vector3.UP, _spin_angle)
		return
	# 出局：朝当时倾斜的方位倒下去，再退场清出场景
	# （只动视觉模型，刚体的 transform 交给物理服务器）
	_fall_angle = move_toward(_fall_angle, PI * 0.5, FALL_RATE * delta)
	model.quaternion = Quaternion(Vector3.UP, _precess_phase) \
			* Quaternion(Vector3.RIGHT, _fall_angle)
	_dead_t += delta
	if _dead_t < DESPAWN_HOLD:
		return
	var k: float = clampf((_dead_t - DESPAWN_HOLD) / DESPAWN_FADE, 0.0, 1.0)
	model.position.y = -DESPAWN_SINK * k
	model.scale = Vector3.ONE * (1.0 - k)
	if k >= 1.0:
		despawn_done = true


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not alive:
		state.linear_velocity = Vector3.ZERO
		return
	var dt: float = state.step
	# ⚠ 取「碰撞求解前」的速度：_integrate_forces 在求解之后才被调用，这里的
	#   state.linear_velocity 已经是弹开后的值；而**上一步的末速度**正是本步求解前
	#   的速度（中间没人动它），用 vel_prev = vel_post 拿回来。
	vel_prev = vel_post
	vel_post = Vector2(state.linear_velocity.x, state.linear_velocity.z)
	# 水平面速度（忽略可能出现的 y 分量）
	var vxz := Vector2(state.linear_velocity.x, state.linear_velocity.z)
	var speed: float = vxz.length()

	# §5 硬速度上限：削平超出上限的速度（陀螺始终在水平面运动，y 分量归零）
	var max_v := move_speed * MAX_SPEED_MULT
	if speed > max_v:
		var scaled := vxz * (max_v / speed)
		state.linear_velocity = Vector3(scaled.x, 0.0, scaled.y)
		vxz = scaled
		speed = max_v

	# ── 场地碗坡：越靠外，往中心推得越狠（「周围高、中间低」的物理后果）──
	# ⚠ 刻意**不**写进 drive_accel：那是「主动机动」的挤压力，坡度是场地给的
	#   恒定偏置，混进去会整体抬高碰撞挤压项，动摇刚修好的「贴靠弹开」。
	var slope: Vector2 = TopsRules.slope_accel(
			Vector2(state.transform.origin.x, state.transform.origin.z),
			TopsRules.ARENA_CENTER, TopsRules.ARENA_RADIUS)
	if slope.length_squared() > 0.0:
		state.apply_central_force(Vector3(slope.x, 0.0, slope.y) * mass)

	if thrusting and input_dir.length_squared() > 0.0:
		# 主动推进（仅 AI 使用）：转向 + 施力
		var ratio: float = clampf(speed / move_speed, 0.0, 1.0)
		var max_turn: float = turn_rate * (1.0 - 0.6 * ratio) * dt
		var diff: float = wrapf(input_dir.angle() - facing, -PI, PI)
		facing += clampf(diff, -max_turn, max_turn)

		var boost_mult: float = 1.70 if boosting else 1.0
		var fv := Vector2.from_angle(facing)
		if speed < move_speed * boost_mult or vxz.dot(fv) < 0.0:
			# 力作用在水平面（y=0 分量），质心在原点 → 纯平移
			state.apply_central_force(Vector3(fv.x, 0.0, fv.y) * (accel * boost_mult) * mass)
			drive_accel = fv * accel * boost_mult
		else:
			drive_accel = Vector2.ZERO
		return

	# 无主动推进 → 自转进动漂移：方向缓慢旋转的小推力，保证陀螺不会完全静止
	# （这个推力同时是「把两颗陀螺压在一起对磨」的法向力来源，要如实上报给物理层）
	drift_phase += dt * drift_rate
	facing = drift_phase
	if speed < move_speed * DRIFT_SPEED_CAP:
		var dv := Vector2.from_angle(drift_phase)
		state.apply_central_force(Vector3(dv.x, 0.0, dv.y) * (accel * DRIFT_ACCEL_RATIO) * mass)
		drive_accel = dv * accel * DRIFT_ACCEL_RATIO
	else:
		drive_accel = Vector2.ZERO


func _on_body_entered(other: Node) -> void:
	if other is TopTop:
		TopsRules.resolve_contact(self, other as TopTop)
	elif other.is_in_group(&"wall"):
		TopsRules.apply_wall(self)


## 出局：停住物理，交给绘制层画「倒下」
func kill() -> void:
	if not alive:
		return
	alive = false
	spin = 0.0
	thrusting = false
	boosting = false
	_fall_angle = _tilt_now   # 从当时歪着的角度接着倒，不弹回直立
	freeze = true
	linear_velocity = Vector3.ZERO
	died.emit(self)
