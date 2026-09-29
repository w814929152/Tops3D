class_name TopsRules
extends RefCounted
##
## 陀螺规则层 —— 纯数据 + 纯函数，**零渲染依赖**（headless 可断言）。
##
## 分工（平移碰撞交给 Godot 内置 RigidBody3D）：
##   · 引擎负责：平移运动、碰撞检测与弹开（质量/恢复系数/摩擦/CCD）
##   · tops_spin.gd 负责：转速**该掉多少**（转动惯量、摩擦冲量、气动力矩 —— 纯物理）
##   · 本文件负责：转速**怎么结算** —— 结算节奏（冷却）、撞墙、击倒回血、AI 决策
##
## 3D 化说明：物理世界是水平面（XZ 平面）。本层一切位移/速度运算都在
## **二维水平面**上进行 —— 从 RigidBody3D 取出 (x, z) 与速度 (vx, vz) 后，
## 视作 Vector2 处理。这与 2D 版数学完全等价，只是把 y 轴换成了世界 Z 轴。
## 高度（y）不参与任何规则判定，只用于渲染。
##

# ── 结算节奏（玩法参数，不是物理）──
static var WALL_COOLDOWN := 1.00
static var CONTACT_COOLDOWN := 0.50
static var EDGE_RATIO := 0.75
static var KILL_HEAL := 20.0

## 场地（撞墙结算需要径向方向，由 main 每帧写入）
static var ARENA_CENTER := Vector2.ZERO
static var ARENA_RADIUS := 150.0   # 与 TopsMain.BASE_RADIUS 同值；main 每帧覆盖

## ── 碗坡：把陀螺往中心赶的向心加速度 ──
##
## 场地做成「周围高、中间低的浅碗」之后，坡度的物理后果必须由规则层显式补上：
## 引擎里 gravity_scale = 0（水平竞技场），不补这一项，碗就只是一张好看的皮，
## 陀螺飘到边上不会自己回来。
##
## 结构照搬真实斜面：分量 = g·sin(θ)，θ 直接取碗坡倾角 TopsArena.SLOPE_DEG
## （几何与物理共用一个角度，不会各说各话），方向沿 -径向。
## 幅度再乘 SLOPE_ACCEL_SCALE 做手感标定 —— 跟 CONTACT_LOSS_SCALE 一个道理：
## 缩幅度，不动结构。
##
## 0.80 是扫参挑出来的（tests/tops_arena_gather.gd，三局平均）：
##   无向心力 → 外圈占比 75%、平均 r/R 0.81、接触 87 次
##   scale=0.80 → 外圈占比 57%、平均 r/R 0.73、接触 94 次、对局 52 s
## 再往上加，陀螺被按在中心打转、碰撞反而变少（1.2 时对局拖到 72 s）。
static var SLOPE_ACCEL_SCALE := 0.80
## 归一化半径小于此值的中心区是**平的**：中心必须有块自由活动的地盘，
## 否则所有陀螺会被一路吸到圆心挤成一坨，也没法在外圈周旋。
##
## 0.45 是「聚集」与「边缘交战」的折中（三局平均）：
##   start=0.30 → 外圈占比 55%、接触 81 次、撞墙 54 次、对局 57 s
##   start=0.45 → 外圈占比 63%、接触 97 次、撞墙 59 次、对局 51 s
##   start=0.60 → 外圈占比 66%、接触 92 次、撞墙 60 次、对局 53 s
## 再往内收，陀螺早早被碗坡推回、够不到边缘，「撞墙弹开」就几乎看不到了。
static var SLOPE_START_RATIO := 0.45
## 回落方向的偏转（度）。真实陀螺受侧向力会**进动**而不是顺着力直走，
## 带一点偏转就走螺旋回落，不会直穿圆心撞到对面再弹回来来回振荡。
## ⚠ 别调大：偏转让所有陀螺形成同向环流，相对速度下降，碰撞会明显变少。
static var SLOPE_SWIRL_DEG := 10.0


## 场地在 p 处给出的向心加速度（wu/s²，世界 XZ 平面方向）
static func slope_accel(p: Vector2, center: Vector2, arena_radius: float) -> Vector2:
	var off: Vector2 = p - center
	var d: float = off.length()
	if d < 1e-4 or arena_radius <= 0.0:
		return Vector2.ZERO
	var u: float = d / arena_radius
	if u <= SLOPE_START_RATIO:
		return Vector2.ZERO
	# 越靠外越陡：0 → 1 平滑渐入，到硬边界满值（坡底不突然发力）
	var w: float = clampf((u - SLOPE_START_RATIO) / maxf(1.0 - SLOPE_START_RATIO, 1e-4), 0.0, 1.0)
	w = w * w * (3.0 - 2.0 * w)   # smoothstep
	# 真实斜面分量 → 游戏单位：a_game = g·sinθ / (WU_TO_M · VEL_GAIN)
	var a_real: float = TopsSpin.G * sin(deg_to_rad(TopsArena.SLOPE_DEG))
	var a: float = a_real / (TopsSpin.WU_TO_M * TopsSpin.VEL_GAIN) * w * SLOPE_ACCEL_SCALE
	return (-off / d).rotated(deg_to_rad(SLOPE_SWIRL_DEG)) * a

## ── 玩法标定：缩放「幅度」，不动「结构」──
## 真陀螺一局能打两三分钟、几百次轻碰；我们把 5 颗陀螺塞进 25 cm 的场子里、
## AI 全程全力推进，撞击密度远高于真实。直接照搬真实幅度，一局 20 秒就打完了。
## 这三个系数只整体缩放损耗大小，物理依赖关系（∝ 质量 / ∝ 接近速度 / ∝ 自转）
## 一条都没动。
static var CONTACT_LOSS_SCALE := 0.10
static var WALL_LOSS_SCALE := 0.25
static var NATURAL_LOSS_SCALE := 1.00

## ── 濒死惩罚：已经在摆 / 已经在倒的陀螺，挨一下掉得更多（可被补刀）──
## 按 TopsSpin.WobblePhase 索引：稳定 1.0 / 摆头 1.20 / 倾倒 1.50。
## 物理依据不是「摩擦变大」（那是 instability() 管的事），而是**抗冲击裕度没了**：
##   稳稳睡着时，一次横向冲击只是削掉一点角动量，轴还能自己立回来；
##   已经在倒的时候，同一次冲击直接把残余的角动量打散 → 立刻趴下。
## 玩法价值：把「血条还有 11 点但已经必倒」这件事变成**可被对手利用的信息** ——
##   濒死陀螺不再是「慢慢磨完最后一点血」，而是谁补一刀谁拿人头（击杀回血也归他）。
## ⚠ 别把它调成 3.0 之类的激进值：那等于把出局线直接抬到 ω_c，
##   对局会明显变短、缩圈阶段可能还没开始就打完了。
const WOBBLE_DAMAGE_MULT: Array[float] = [1.0, 1.20, 1.50]


## 按当前姿态取伤害倍率（互撞与撞墙两处都走它）
static func damage_mult(t: TopTop) -> float:
	var p: int = t.wobble_phase()
	if p < 0 or p >= WOBBLE_DAMAGE_MULT.size():
		return 1.0
	return WOBBLE_DAMAGE_MULT[p]
## 轮缘摩擦「搓开」效应的强度。这是运动学不是损耗，默认给足 1.0；
## 调小它会让陀螺更容易互相顶住不分开。
## 2026-09-29 调到 1.20：对撞后沿切向刮开得更狠，画面上更像「被弹飞」。
static var CONTACT_PUSH_SCALE := 1.20

## ── 陀螺互相弹开的**法向分离速度下限**（wu/s）──
##
## 为什么需要这一道（2026-09-28 二修，tests/tops_stick_probe.gd 实测）：
## 轮缘摩擦给的 dv 是**切向**的 —— 切向滑动只让两颗陀螺**绕着彼此转圈**，
## 中心距并不增大。贴死的那几段里切向速度 52～107 wu/s，法向速度却只有 −1.9 wu/s：
## 一直在绕圈，从没分开过。而引擎的接触约束只保证「不重叠」，不制造分离速度，
## 在两家 AI 全力对推（挤压 234～369 wu/s²）时还会被压穿（gap 最坏 −6.16 wu）。
##
## 所以这里给一道法向分离速度的**下限**，跟撞墙的 WALL_SEPARATE_SPEED 同一套路：
##   · 正在分开且够快 → 完全不干预（正常对撞实测分离速度 144 wu/s，远高于此值）
##   · 顶住不动 / 还在靠近 → 补到这个下限
## 即它只救「死顶」，不碰正常对撞的手感。
## 2026-09-29：70 → 115。当前 linear_damp 已是 0.22（不是注释里早期的 0.8），
## 70 wu/s 分离速度在场地缩到 150 之后显得「软」——调高后死顶段能被明显撞飞。
static var CONTACT_SEPARATE_SPEED := 115.0

## 撞完一次之后，AI 至少松开这么久（秒）才重新扑上去。
## 弹开的位移要靠这段时间才走得完：分离速度 70 wu/s 在阻尼 0.8 下要 ~0.5 s
## 才推开一个陀螺直径，AI 要是立刻回顶，玩家根本看不到「弹开」这一步。
static var AI_DISENGAGE_TIME := 0.55

## 几何接触判定的余量（wu）：中心距 < 半径和 + 此值 就算还在接触。
## 略大于 0 是为了盖住引擎「只在真重叠时才报」的空隙（见 resolve_ongoing_contacts），
## 让「挨着但没叠上」的那一段也能正常结算掉转速。
## ⚠ 别调大：它同时是**判定**范围，太大就变成排斥力场，陀螺再也贴不到一起磨。
static var CONTACT_MARGIN := 0.5

## 本物理帧的步长（秒），由 main 每帧写入。切向「搓开」要按帧折算成冲量，
## 不能再按结算间隔折算 —— 那样只在结算那一刻给一下，中间大半秒全靠引擎。
static var step_dt: float = 1.0 / 60.0

const DEFAULTS := {
	"wall_cd": 1.00, "contact_cd": 0.50, "edge_ratio": 0.75, "kill_heal": 20.0,
	"contact_scale": 0.10, "wall_scale": 0.25, "nat_scale": 1.00,
	"boost_mult": 2.0, "edge_mult": 2.0, "slope_scale": 0.80,
	"contact_sep": 115.0, "push_scale": 1.20, "wall_sep": 165.0,
}


## 扫参用：把一组键值套进规则层与物理层（缺失键保持当前值）
static func apply_tuning(d: Dictionary) -> void:
	if d.has("wall_cd"):
		WALL_COOLDOWN = float(d["wall_cd"])
	if d.has("contact_cd"):
		CONTACT_COOLDOWN = float(d["contact_cd"])
	if d.has("edge_ratio"):
		EDGE_RATIO = float(d["edge_ratio"])
	if d.has("kill_heal"):
		KILL_HEAL = float(d["kill_heal"])
	if d.has("nat_scale"):
		NATURAL_LOSS_SCALE = float(d["nat_scale"])
	if d.has("contact_scale"):
		CONTACT_LOSS_SCALE = float(d["contact_scale"])
	if d.has("wall_scale"):
		WALL_LOSS_SCALE = float(d["wall_scale"])
	if d.has("boost_mult"):
		TopsSpin.BOOST_TIP_MULT = float(d["boost_mult"])
	if d.has("edge_mult"):
		TopsSpin.EDGE_FRICTION_MULT = float(d["edge_mult"])
	if d.has("slope_scale"):
		SLOPE_ACCEL_SCALE = float(d["slope_scale"])
	if d.has("contact_sep"):
		CONTACT_SEPARATE_SPEED = float(d["contact_sep"])
	if d.has("push_scale"):
		CONTACT_PUSH_SCALE = float(d["push_scale"])
	if d.has("wall_sep"):
		WALL_SEPARATE_SPEED = float(d["wall_sep"])


static func reset_tuning() -> void:
	apply_tuning(DEFAULTS)
	TopsSpin.reset_tuning()

## 由 main 每帧写入，供碰撞回调做冷却判定。
static var now: float = 0.0


## 从 3D 刚体取水平面位置 Vector2(x, z)。
static func plane_pos(t: TopTop) -> Vector2:
	return Vector2(t.global_position.x, t.global_position.z)


## 从 3D 刚体取水平面速度 Vector2(vx, vz)。
static func plane_vel(t: TopTop) -> Vector2:
	return Vector2(t.linear_velocity.x, t.linear_velocity.z)


## 陀螺间接触结算 —— 全部交给物理层 TopsSpin.contact_resolve()。
##
## 两段式（跟撞墙 apply_wall 同一套路）：
##   ① **运动学**（每次调用都做，不受冷却限制）：法向弹开 + 切向搓开 + 去重叠
##   ② **掉转速**（带 CONTACT_COOLDOWN 冷却）
## 冷却管的是「扣转速的节奏」，不是「能不能分开」—— 把运动学关在冷却闸门后面，
## 等于每 0.5 s 才推一下、中间全靠引擎，而引擎的接触约束根本不制造分离速度。
##
## 关键：接近速度必须用 **vel_prev**（碰撞求解前的快照）。body_entered 送达时
## 求解器早就把两球弹开了，当场读到的相对速度**总是**「正在分离」，撞击损耗会被
## 整片吞掉（实测高速正面对撞 100% 不结算）。贴身对磨则由 press_dt 那一项补上：
## 驱动把两者压在一起的加速度折算成法向力，只要还在磨就一直在掉转速。
static func resolve_contact(a: TopTop, b: TopTop) -> void:
	if not a.alive or not b.alive:
		return
	var pa: Vector2 = plane_pos(a)
	var pb: Vector2 = plane_pos(b)
	var d: Vector2 = pb - pa
	if d.length_squared() <= 0.0001:
		return
	var n: Vector2 = d.normalized()
	var rel_now: Vector2 = plane_vel(b) - plane_vel(a)
	var dist: float = d.length()
	var gap: float = dist - (a.top_radius + b.top_radius)   # 负 = 已经嵌在一起

	# ── ① 法向弹开：分离速度下限 ──
	# 切向摩擦只让两颗陀螺绕着彼此转圈，不产生分离；引擎只保证不重叠、也不制造分离。
	# 两家 AI 全力对推时能顶 3 s 不分开（还把求解器压穿到 gap −6 wu），就靠这道兜底。
	# ⚠ 只有**真的叠在一起**（gap ≤ 0）才强制弹开。
	# 试过「按间隙平滑衰减」和「几何余量 1.5 wu 内就推」：结果陀螺在 1.5 wu 外
	# 就被推开，再也贴不到一起 —— 接触段从 65 掉到 8，对磨伤害基本消失，
	# 对局退化成纯比自然衰减。而**对磨正是掉转速的机制**，不能这么打掉。
	# 挨着但没叠上（gap > 0）交给引擎碰撞与切向摩擦自己处理。
	var floor_v: float = CONTACT_SEPARATE_SPEED if gap <= 0.0 else 0.0
	var vn: float = rel_now.dot(n)          # 正 = 正在分开
	if vn < floor_v:
		var half: float = (floor_v - vn) * 0.5
		a.linear_velocity -= Vector3(n.x, 0.0, n.y) * half
		b.linear_velocity += Vector3(n.x, 0.0, n.y) * half

	# ── ① 续：切向「搓开」—— 互相刮的两颗陀螺被沿切向推开。──
	# 这属于**运动学**不是**损耗**，所以不跟着 CONTACT_LOSS_SCALE 打折。
	# ⚠ 按**本帧时长**折算（原来按 CONTACT_COOLDOWN 折算，0.5 s 才给一下）。
	var kin: Dictionary = TopsSpin.contact_resolve(
			a.mass_kg, a.radius_m, a.axial_inertia, a.omega(),
			b.mass_kg, b.radius_m, b.axial_inertia, b.omega(),
			n, rel_now, a.drive_accel, b.drive_accel, step_dt)
	var kina: Vector2 = (kin["dv_a"] as Vector2) * CONTACT_PUSH_SCALE
	var kinb: Vector2 = (kin["dv_b"] as Vector2) * CONTACT_PUSH_SCALE
	a.linear_velocity += Vector3(kina.x, 0.0, kina.y)
	b.linear_velocity += Vector3(kinb.x, 0.0, kinb.y)

	# ── ① 续：去重叠 —— 持续对推会把求解器压穿，位置直接掰回刚好相切 ──
	if gap < 0.0:
		var push: float = -gap * 0.5 + 0.05
		a.set_plane_pos(pa - n * push)
		b.set_plane_pos(pb + n * push)

	# ── ② 掉转速（带冷却）──
	var key: String = "%d_%d" % [mini(a.top_id, b.top_id), maxi(a.top_id, b.top_id)]
	if now - float(a.last_contact.get(key, -1000.0)) < CONTACT_COOLDOWN:
		return
	a.last_contact[key] = now
	b.last_contact[key] = now
	a.contacts += 1
	b.contacts += 1
	# 撞完先松劲：两家 AI 撞完立刻回顶就会黏在一起，给它们一段绕行时间。
	a.disengage = AI_DISENGAGE_TIME
	b.disengage = AI_DISENGAGE_TIME

	var rel: Vector2 = b.vel_prev - a.vel_prev
	var res: Dictionary = TopsSpin.contact_resolve(
			a.mass_kg, a.radius_m, a.axial_inertia, a.omega(),
			b.mass_kg, b.radius_m, b.axial_inertia, b.omega(),
			n, rel, a.drive_accel, b.drive_accel, CONTACT_COOLDOWN)
	# 击倒归属：角速度高的一方是「攻方」（它的轮缘在磨对方）
	if a.omega() >= b.omega():
		b.last_hit_by = a.top_id
	else:
		a.last_hit_by = b.top_id
	apply_domega(a, float(res["domega_a"]) * CONTACT_LOSS_SCALE)
	apply_domega(b, float(res["domega_b"]) * CONTACT_LOSS_SCALE)


## 把物理层算出的 Δω（rad/s）写回转速刻度，钳在 [0, spin_max]。
## ⚠ 只用于**伤害**：击杀回血走的是 tops_main 里直接改 t.spin，不经过这里，
##   所以在这一层乘「濒死惩罚」不会把回血也一起放大。
static func apply_domega(t: TopTop, domega: float) -> void:
	if not t.alive or domega == 0.0:
		return
	var dw: float = domega * damage_mult(t)
	t.spin = clampf(t.spin + TopsSpin.spin_of(dw), 0.0, t.spin_max)


## 持续接触的轮询补结算。
## body_entered 只在「从无接触 → 有接触」的跃变时触发一次：两颗陀螺一旦粘在一起
## （混战里最常见的就是挤成一团对磨），之后就再也不会触发信号，转速只掉一次就停了。
## 这里改为每物理帧查询当前仍接触的对子，配合 CONTACT_COOLDOWN 形成稳定磨损节奏。
static func resolve_ongoing_contacts(tops: Array[TopTop]) -> void:
	for i in tops.size():
		var a: TopTop = tops[i]
		if not is_instance_valid(a) or not a.alive:
			continue
		for j in range(i + 1, tops.size()):
			var b: TopTop = tops[j]
			if not is_instance_valid(b) or not b.alive:
				continue
			if plane_pos(a).distance_to(plane_pos(b)) \
					> a.top_radius + b.top_radius + CONTACT_MARGIN:
				continue
			resolve_contact(a, b)


## 仍在用引擎信号吗？用 —— 但只作为「撞击瞬间」的补充。
## ⚠ 不能**只**信 get_colliding_bodies()：它只在真的**重叠**时才报告，
##   两颗陀螺挨到 gap ∈ (0, 1] 但没重叠时引擎完全不报，规则层就撒手不管了 ——
##   实测能并排贴着飘 0.32 s（撤掉 AI 推进后没有强挤压，这种情况变多了）。
##   所以持续结算改用**几何判定**（resolve_ongoing_contacts），
##   body_entered 那条路保留下来只管「撞击瞬间」的伤害。


## 「碰到边缘会弹开」—— 一道确定性的分离速度。
##
## 引擎其实是有弹的（实测恢复系数 0.65，给墙加了光滑硬壁材质后 0.79），
## 但 linear_damp = 0.80 太狠：陀螺从圆心以 300 wu/s 出发，飞到边缘只剩 ~90 wu/s，
## 反弹后只剩 ~70，转瞬就被阻尼抹平 —— 看上去就是「飘过去、轻轻蹭一下、贴在边上」。
## 所以这里不再指望引擎那点残余动能：每次**真**撞上墙，直接把向内速度补到
## WALL_SEPARATE_SPEED。幅度是玩法标定，不是物理推导（同 CONTACT_LOSS_SCALE）。
## 2026-09-29：110 → 165。场地缩到 150 之后撞墙变频繁（人均 1~10 次），
## 撞墙应该有「撞飞弹回来」的冲击感，而不是软软地蹭一下。
static var WALL_SEPARATE_SPEED := 165.0

## 撞墙：轮缘擦到碗壁，按真实摩擦冲量算（边缘是险地 · Pillar 2）。带冷却，避免贴墙被瞬间刷死。
## 同样用 vel_prev 取接近速度 —— 信号送达时已经被弹开了。
static func apply_wall(t: TopTop) -> void:
	if not t.alive:
		return
	var off: Vector2 = plane_pos(t) - ARENA_CENTER
	var n: Vector2 = off.normalized() if off.length_squared() > 1e-6 else Vector2(1.0, 0.0)

	# ① 弹开：每次碰撞都给，**不受冷却限制**（冷却管的是扣转速的节奏）
	var v: Vector2 = plane_vel(t)
	var vin: float = -v.dot(n)          # 正 = 正在离开边缘
	if vin < WALL_SEPARATE_SPEED:
		v -= n * (WALL_SEPARATE_SPEED - vin)
		t.linear_velocity = Vector3(v.x, 0.0, v.y)

	# ② 扣转速（带冷却）
	if t.wall_cooldown > 0.0:
		return
	var vp: Vector2 = t.vel_prev
	if vp.length_squared() < 1e-6:      # 还没跑过物理步（刚解冻）→ 退回当前速度
		vp = plane_vel(t)
	var u_n: float = maxf(0.0, vp.dot(n))
	var dw: float = TopsSpin.wall_domega(t.mass_kg, t.radius_m, t.axial_inertia, t.omega(), u_n)
	t.spin = maxf(0.0, t.spin + TopsSpin.spin_of(dw * WALL_LOSS_SCALE * damage_mult(t)))
	t.wall_cooldown = WALL_COOLDOWN
	t.wall_hits += 1


## 自然衰减（物理层：轴尖干摩擦 + 空气阻力 + 低转速失稳）+ 边缘/推进加权 + 硬边界钳制。
##
## 硬边界（防逃逸）：引擎的 RigidBody3D 弹开在多方堆叠 + 高恢复系数下会把陀螺
## 反复加速并挤出墙外（单发发射能被墙挡住，混战却穿墙）。规则层既然知道场地半径，
## 就在这里做一道确定性的兜底：任何陀螺中心探出「墙内表面」即被反射推回场内，速度
## 沿法线衰减。不依赖引擎是否穿透，headless 可断言。
## 墙内表面相对玩法半径的外扩量 —— 随场地等比（250 场地时是 20，150 场地时是 12）。
## 它是「玩法半径之外还留多少余量」，写成定值会让小场地的有效活动区相对更大。
const WALL_INNER_OFFSET := 12.0
static var ARENA_BOUNDS_ENABLED := true


static func decay(t: TopTop, dt: float, arena_center: Vector2, arena_radius: float) -> void:
	if not t.alive:
		return
	t.wall_cooldown = maxf(0.0, t.wall_cooldown - dt)
	t.disengage = maxf(0.0, t.disengage - dt)
	var p: Vector2 = plane_pos(t)
	# 骑上碗壁坡面 → 轴尖接触面变大，摩擦加倍
	var tip_mult: float = TopsSpin.EDGE_FRICTION_MULT if p.distance_to(arena_center) \
			> arena_radius * EDGE_RATIO else 1.0
	if t.boosting:
		tip_mult *= TopsSpin.BOOST_TIP_MULT   # 开推进 → 晃动加剧 → 轴尖刮得更狠
	var domega: float = TopsSpin.natural_domega(t.mass_kg, t.radius_m, t.axial_inertia,
			t.tip_mu, t.tip_r_eff, t.omega(), tip_mult, t.decay_mult)
	t.spin = maxf(0.0, t.spin + TopsSpin.spin_of(domega * NATURAL_LOSS_SCALE) * dt)

	# ── 硬边界：超出墙内表面的陀螺被反射推回 ──
	if ARENA_BOUNDS_ENABLED:
		_clamp_to_arena(t, arena_center, arena_radius + WALL_INNER_OFFSET)


## 把探出场地的陀螺沿径向反射回场内，并削掉朝外的速度分量。
static func _clamp_to_arena(t: TopTop, center: Vector2, bound_r: float) -> void:
	var p: Vector2 = plane_pos(t)
	var off: Vector2 = p - center
	var d: float = off.length()
	if d <= bound_r or d < 0.0001:
		return
	var n: Vector2 = off / d
	var v: Vector2 = plane_vel(t)
	# 只处理仍在往外冲的情况（切向滑行贴墙不干预）
	if v.dot(n) > 0.0:
		var vn: float = v.dot(n)
		var vt: Vector2 = v - n * vn
		# 反射 + 恢复系数衰减朝外分量，避免原地抖动
		var bounced := vt - n * vn * 0.60
		t.linear_velocity = Vector3(bounced.x, 0.0, bounced.y)
	# 位置直接拉回到边界内（留一点余量，避免下一帧又贴出去）
	var safe := center + n * (bound_r - t.top_radius - 4.0)
	t.set_plane_pos(safe)


## AI：预判拦截（转向有上限 → 直线追永远追不上）
static func ai_drive(t: TopTop, tops: Array[TopTop], strategy: String,
		arena_center: Vector2) -> void:
	if not t.alive:
		t.thrusting = false
		return
	var best: TopTop = null
	var bd := INF
	for o in tops:
		if o == t or not o.alive:
			continue
		var d: float = plane_pos(t).distance_to(plane_pos(o))
		if d < bd:
			bd = d
			best = o
	if best == null:
		t.input_dir = (arena_center - plane_pos(t)).normalized()
		t.thrusting = true
		return
	# 刚撞过 → 先绕着对手走，别立刻又顶上去。
	# 弹开的位移需要时间才走得完（分离速度 70 wu/s、阻尼 0.8 → 约 0.5 s 推开一个直径），
	# AI 全程直冲的话，玩家看到的只有「两颗陀螺黏着抖」而不是「弹开」。
	if t.disengage > 0.0:
		var away: Vector2 = plane_pos(t) - plane_pos(best)
		if away.length_squared() < 1e-6:
			away = Vector2(1.0, 0.0)
		away = away.normalized()
		# 绕行方向按 id 定死，避免两颗陀螺左右试探着原地蹭
		var side: Vector2 = Vector2(away.y, -away.x) * (1.0 if t.top_id % 2 == 0 else -1.0)
		t.input_dir = (side * 0.85 + away * 0.40).normalized()
		t.thrusting = true
		return

	var lead: float = clampf(bd / maxf(t.move_speed, 1.0), 0.0, 1.2)
	var aim: Vector2 = plane_pos(best) + plane_vel(best) * lead
	if strategy == "slam":
		var outward: Vector2 = (aim - arena_center).normalized()
		if outward.length_squared() <= 0.0:
			outward = Vector2(1.0, 0.0)
		aim = aim - outward * (t.top_radius + best.top_radius + 55.0)
	t.input_dir = (aim - plane_pos(t)).normalized()
	t.thrusting = true
