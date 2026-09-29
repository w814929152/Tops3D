class_name TopsMain
extends Node3D
##
## 陀螺对战 · 主场景（真 3D 物理版）
##
## 玩法（发射制 · 进场后完全交给物理）：
##   · **① 开始游戏**：标题卡片上的主按钮（或 Enter / 空格）。
##   · **② 蓄力**：玩家在场地边缘待命，鼠标 / ←→ 调方向，按住 空格 / Shift / 左键 蓄力。
##     蓄力条来回摆动 → 松手时机就是玩法；踩中金色「完美区间」额外加成。
##   · **③ 放陀螺**：松手即发射进场，屏幕弹「放陀螺！」横幅。
##   · **战斗阶段**：进场后**无法操控**，你的陀螺只靠发射初速 + 自转进动漂移 + 物理碰撞运动；
##     AI 对手保留主动推进。全部策略压缩进「发射」这一次决策（角度 × 力度）。
##
## 界面层：tops/tops_ui.gd（TopsUi，CanvasLayer）+ src/ui_theme.gd（设计令牌）。
##
## 分工：平移碰撞交给 Godot 内置 RigidBody3D（水平 XZ 平面）；转速经济走零渲染依赖的
## TopsRules（可 headless 断言）。场地边界用 24 段 StaticBody3D 拼成圆环，缩圈靠内移墙段。
##
## 3D 化说明：
##   · 竞技场铺在 y=0 的水平面（XZ 平面），CENTER 是世界 XZ 原点 (0,0)。
##   · 一切逻辑位移/速度仍是 Vector2(x, z)，经 TopTop.plane_pos()/plane_vel() 与
##     RigidBody3D 互转；高度只用于相机与光照，不参与规则判定。
##   · 渲染：每个陀螺挂一个圆柱 MeshInstance3D 子节点随刚体移动；场地、墙、灯光、
##     相机都是真 3D 节点。HUD（中文文字/血条）放在 CanvasLayer + Control 上，保证
##     CJK 字形可靠渲染。
##   · 相机：**斜俯视** —— 仰角 CAM_ELEVATION_DEG 固定，距离随缩圈自动重算并按倾斜后的
##     梯形视野把瞄点归中，整块场地始终完整入画。屏幕上方 = 世界 -Z，屏幕右方 = 世界 +X，
##     玩家从屏幕下方（+Z）进场。
##

# 世界坐标：场地中心在 XZ 原点，半径 BASE_RADIUS。y 恒为 0。
const CENTER := Vector2(0.0, 0.0)
## 场地半径（1 wu = 1 mm）：250 → 150（直径 50cm → 30cm，2026-09-28 缩小）。
## 陀螺尺寸（13~19）不变，所以场地越小、陀螺在画面上越大、撞击越密、单局越短。
## 改这一个数即可，碗体 / 墙段 / 取景全部跟着走（碗沿按 BASE_BOUND 等比，见 TopsArena）。
const BASE_RADIUS := 150.0
const TOP_Y := 0.0               # 陀螺所在水平面高度
const TRAIL_STEP := 0.05
const TRAIL_MAX := 16

# 相机参数（斜俯视：悬在场地上方斜着往下看，整块场地始终完整入画）
const CAM_FOV := 55.0            # 纵向视野角（keep_aspect 默认 KEEP_HEIGHT）
const CAM_FIT_MARGIN := 1.06     # 取景按碗外沿算，留一点边缘余量即可
const CAM_ELEVATION_DEG := 70.0  # 仰角：90 = 纯俯视，70 = 带立体感的斜俯视，40 = 很平
const CAM_MIN_ELEVATION_DEG := 40.0  # 再平下去视锥下边缘会翻过天顶，打到相机背后
const CAM_MIN_DISTANCE := 75.0   # 缩到最小圈后不再继续压近，避免贴脸畸变（随 BASE_RADIUS 等比）

# 缩圈节奏（可写静态量，扫参时调它）
static var SHRINK_START := 30.0
static var SHRINK_RATIO_PER_SEC := 0.006
static var SHRINK_MIN_RATIO := 0.50

# 发射参数
const SPAWN_RADIUS_RATIO := 0.88   # 待命位置：场地边缘内侧

## 电脑陀螺的初始转速浮动区间（× 原型 spin_max）。
## 玩家仍是满转速（自己蓄力发射，不该被随机惩罚）；电脑在 ±12% 内浮动，
## 让每局的对手强弱有变化，而不是五颗一模一样的复制品。
## ⚠ 区间要以 1.0 为**中心**（0.88~1.12），否则会变成对某一方的系统性削弱/加强。
const AI_SPIN_LO := 0.88
const AI_SPIN_HI := 1.12
const POWER_MIN := 0.15
const POWER_MAX := 1.00
const POWER_RATE := 1.15           # 蓄力条每秒充能速度（往返）
const LAUNCH_SPEED_MIN := 0.35     # 发射初速 = (0.35 + 0.85×力度) × max_speed
const LAUNCH_SPEED_SPAN := 0.85
const AIM_TURN_RATE := 2.2         # 键盘调方向的角速度（rad/s）
const POWER_PERFECT := 0.85        # 蓄力「完美区间」下沿（金色段）
const PERFECT_SPEED_BONUS := 1.08  # 在完美区间松手 → 初速 +8%

enum Phase { TITLE, LAUNCH, BATTLE, RESULT }

# 边界：N 段 StaticBody3D 盒子拼成圆环（段数足够多 → 近似光滑圆，无逃逸缺口）。
# 缩圈靠**径向平移**墙段（改 position）而非缩放——缩放只压扁盒子、内表面几乎不动，
# 碰撞边界与玩法半径脱节，陀螺会从「没真正收进来」的缺口溜出去。平移让碰撞面精确跟随半径。
const WALL_SEGMENTS := 48
const WALL_THICKNESS := 20.0     # 墙盒径向厚度（不改：它在玩法边界之外，缩场地不受影响）
var _wall_segs: Array[StaticBody3D] = []
## 每段墙的基准方位角（弧度），缩圈时沿此方向重新定位到当前 _arena_radius。
var _wall_angles: Array[float] = []
var _tops: Array[TopTop] = []
var _player: TopTop = null
var _strategies: Dictionary = {}
## 转速表：**整局固定**的名单（倒下的陀螺也留在表里，UI 只压暗不移除）。
## 与 _tops 分开的原因：_tops 会在退场动画播完后把对象摘掉并 queue_free，
## 而转速表要的是「这一局有谁」，所以静态信息（名字/颜色/是否玩家）先快照下来，
## 实时数值每帧从对象读，读不到（已被释放）就按「已出局」画。
var _roster: Array[TopTop] = []
var _roster_data: Array[Dictionary] = []

var _camera: Camera3D
var _ui: TopsUi
## 竞技场碗体（TopsArena 造的单位碗，靠 scale.x/z 跟缩圈一起收）
var _bowl: Node3D

var _phase: int = Phase.TITLE
var _aim_dir := Vector2(0.0, -1.0)
var _power: float = POWER_MIN
var _charging := false
var _charge_up := true
## 开始游戏那一瞬的输入锁：点按钮 / 按空格的那一次按下不能顺手当成蓄力，
## 必须等所有相关键鼠都松开才解锁（否则「点一下开始游戏」会直接把陀螺发射出去）。
var _input_lock := true

var _arena_radius: float = BASE_RADIUS
var _elapsed: float = 0.0
var _trail_t: float = 0.0

var _finished: bool = false
var _won: bool = false
var _place: int = 0
var _flash: float = 0.0


func _ready() -> void:
	_build_world()
	_build_ui()
	_reset()


## 界面层（CanvasLayer）：三步骤流程由它承载，逻辑只发信号 / 调 API
func _build_ui() -> void:
	_ui = TopsUi.new()
	add_child(_ui)
	_ui.start_requested.connect(start_game)
	_ui.restart_requested.connect(_reset)


func _build_world() -> void:
	# 环境光
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#0E1117")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#2A3140")
	env.ambient_light_energy = 0.6
	we.environment = env
	add_child(we)

	# 平行光（斜上方打下来，给陀螺本体做明暗立体感）
	# ⚠ 阴影必须关：gl_compatibility 渲染器 + 高空正俯视相机，平行光阴影会在场地上
	#   采出一块无法收敛的暗斑（已逐一排除地板/陀螺/墙段投影物）。俯视图不需要投影。
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0, -30.0, 0.0)
	light.light_energy = 1.05
	light.shadow_enabled = false
	add_child(light)

	# 相机：斜俯视 —— 悬在场地上方往下看（-Z 为屏幕上方，+X 为屏幕右方）。
	# 不能用 look_at()：仰角接近垂直时视线与 up 向量几乎平行会退化出 NaN，直接写死旋转更稳。
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.fov = CAM_FOV
	add_child(_camera)
	_update_camera()   # 位置/朝向统一由它算；必须先进树，取景要读 viewport 尺寸

	# 竞技场碗体：程序化旋转体（平底 + 缓升的碗坡 + 高亮碗沿）。
	# 平底半径 = 当前硬边界，缩圈时整体等比缩放跟随，倾角恒为 TopsArena.SLOPE_DEG。
	# 陀螺到不了坡上，但坡度会以向心力的形式把它往中心赶（见 TopsRules.slope_accel）。
	_bowl = TopsArena.build(BASE_RADIUS + TopsRules.WALL_INNER_OFFSET)
	add_child(_bowl)
	_update_bowl(_arena_radius)

	# 边界圆环：WALL_SEGMENTS 段盒子拼成，切向重叠无缝。缩圈靠径向平移墙段（跟手、无缺口）。
	_build_wall()


func _build_wall() -> void:
	var seg_angle := TAU / float(WALL_SEGMENTS)
	var r := BASE_RADIUS
	var thickness := WALL_THICKNESS
	for i in WALL_SEGMENTS:
		var a := seg_angle * float(i) + seg_angle * 0.5
		var seg := StaticBody3D.new()
		seg.add_to_group(&"wall")
		# 盒子沿径向摆放，中心距 = _wall_offset()，内表面恰好落在硬边界上
		var off := _wall_offset(r)
		seg.position = Vector3(cos(a) * off, 30.0, sin(a) * off)
		seg.rotation_degrees = Vector3(0.0, rad_to_deg(-a), 0.0)
		var box := BoxShape3D.new()
		# 切向宽度做成 2× 弧长，拼接处大幅重叠，物理上杜绝任何缺口
		box.size = Vector3(thickness, 60.0, seg_angle * r * 2.0)
		var cs := CollisionShape3D.new()
		cs.shape = box
		seg.add_child(cs)
		# 碗壁是**又硬又滑**的：给墙自己一份物理材质，别让它用默认的
		# friction=1.0（那会把陀螺的切向速度磨掉，撞上去就贴着墙滑，看不出弹开）。
		var pm := PhysicsMaterial.new()
		pm.bounce = 0.90
		pm.friction = 0.02
		seg.physics_material_override = pm
		add_child(seg)
		_wall_segs.append(seg)
		_wall_angles.append(a)


func _reset() -> void:
	# 清掉上一局的陀螺（保留 world 静态节点：env/light/camera/floor/boundary）
	for c in get_children():
		if c is TopTop:
			c.queue_free()
	_tops.clear()
	_roster.clear()
	_roster_data.clear()
	_strategies.clear()
	_arena_radius = BASE_RADIUS
	_elapsed = 0.0
	_trail_t = 0.0
	_finished = false
	_won = false
	_place = 0
	_flash = 0.0
	_phase = Phase.TITLE
	_power = POWER_MIN
	_charging = false
	_charge_up = true
	_input_lock = true

	# 边界圆环半径复位到满半径（缩圈每局重来）——把墙段移回基准半径位置
	_place_wall(_arena_radius)

	# 属性归一：转速上限一律 100，性格只影响手感（决策 B3）
	var lineup: Array[StringName] = [&"BALANCED", &"DART", &"RAM", &"DART", &"BALANCED"]
	var strats: Array[String] = ["player", "chase", "slam", "chase", "slam"]
	for i in lineup.size():
		var t := TopTop.create(lineup[i], i + 1)
		# ⚠ 不要再写 t.spin_max = 100 把所有原型抹平（2026-09-28 撤掉）。
		#   那是个平衡 bug：碰撞损耗 Δω = J_t/(k·m·r) —— RAM 又重又大，
		#   挨一下掉的转速只有 DART 的 1/4，本就该用**更少的初始转速**（82）来换。
		#   抹平之后制衡没了，RAM 变成严格更优：实测胜率 **90%**，DART 两个都是 0%。
		#   恢复原型自带的 spin_max（DART 115 / BALANCED 100 / RAM 82）后三者重新互为代价。
		# 不再手写衰减倍率：转速寿命由质量 / 半径 / 形状系数 / 轴尖摩擦推出来（TopsSpin）
		# 电脑：初始转速在 AI_SPIN_LO~HI 间浮动（玩家保持满速，不受随机影响）。
		# spin_cap 同步跟上 —— 击杀回血按它封顶，否则高转速的那颗一击杀就被打回标称值。
		if strats[i] != "player":
			t.spin = t.spin_max * randf_range(AI_SPIN_LO, AI_SPIN_HI)
			t.spin_cap = t.spin
		var ang: float = _spawn_angle(i, lineup.size())
		var p := CENTER + Vector2.from_angle(ang) * BASE_RADIUS * SPAWN_RADIUS_RATIO
		t.facing = ang + PI
		t.drift_phase = t.facing
		t.linear_velocity = Vector3.ZERO
		t.thrusting = false
		t.set_collides(false)   # 发射前互不碰撞
		t.freeze = true         # 发射前连进动漂移也冻住，老老实实在边缘待命
		t.died.connect(_on_top_died)
		_add_top_mesh(t)
		add_child(t)
		t.set_plane_pos(p)      # 进树后再设位置（global_position 需要已在场景树中）
		_tops.append(t)
		_strategies[t.top_id] = strats[i]
		if strats[i] == "player":
			_player = t
		# 转速表行：静态字段一次快照，spin/omega 每帧刷新
		_roster.append(t)
		_roster_data.append({
			"name": "你" if strats[i] == "player" else "对手 %d" % (i + 1),
			"color": TopsArt.top_color(t.top_id),
			"is_player": strats[i] == "player",
			"spin": t.spin,
			# 分母用 spin_cap（本局实际初始转速）而不是标称 spin_max：
			# 电脑可能随机到高于标称值，用标称当分母会显示成「114/102」这种怪值。
			"spin_max": t.spin_cap,
			"omega": t.omega(),
			"alive": true,
			# 质量（克）：1 质量单位 = 50 g → DART 35 g / BALANCED 50 g / RAM 80 g。
			# 它是**静态字段**（整局不变），只在 _reset 里快照一次。
			# 界面显示克而不是游戏单位：真实战斗陀螺就是 30~80 g 这个量级，比「1.6」直观。
			"mass_g": t.mass_kg * 1000.0,
		})

	_aim_dir = (CENTER - _player.plane_pos()).normalized()
	_update_camera()
	if _ui != null:
		_ui.show_title()
		_ui.set_stats(_alive_count(), _tops.size(), 0.0, false)
		_ui.set_spin(_player.spin, _player.spin_cap)
		_ui.set_mass(_player.mass_kg * 1000.0)
		_ui.set_power(_power, false, false)
		_ui.set_hint("")
		_update_roster()
		_ui.set_roster(_roster_data)


## 玩家永远从场地正下方（屏幕近端）进场，AI 均匀分布在其余角度
func _spawn_angle(i: int, n: int) -> float:
	if i == 0:
		return PI * 0.5
	return PI * 0.5 + TAU * float(i) / float(n)


## 给陀螺挂上真正的 3D 陀螺模型（尖头→裙摆→配重盘→攻击环+齿→天盖→旋钮）。
## 模型容器交回 TopTop.model，由它驱动自转与出局倒地。
func _add_top_mesh(t: TopTop) -> void:
	t.model = TopsModel.build(t)
	t.add_child(t.model)


func _physics_process(delta: float) -> void:
	TopsRules.now = _elapsed
	# 本帧步长：接触的「运动学」部分（弹开 / 搓开）按帧折算冲量，不能按结算间隔折算
	TopsRules.step_dt = delta
	# 撞墙结算要用径向方向求「接近速度」，规则层不反向依赖主场景，这里直接喂给它
	TopsRules.ARENA_CENTER = CENTER
	TopsRules.ARENA_RADIUS = _arena_radius
	_update_input_lock()

	# ── ① 开始界面 ──
	if _phase == Phase.TITLE:
		if Input.is_action_just_pressed("ui_accept"):
			start_game()
		return

	# ── 结算界面 ──
	if _phase == Phase.RESULT:
		if Input.is_action_just_pressed("tops_restart") \
				or Input.is_action_just_pressed("ui_accept"):
			_reset()
		_flash = maxf(0.0, _flash - delta * 1.2)
		_reap_dead()   # 结算画面上也要把最后倒下的那几个清干净
		_update_hud()
		return

	if _phase == Phase.LAUNCH:
		_update_launch_input(delta)
		_update_camera()
		_update_hud()
		return

	# ── 战斗阶段 ──
	# ⚠ 进场之后**一律没人能操控**：AI 也不再有主动推进（2026-09-28 改）。
	# 原来只有玩家 thrusting=false、AI 每帧全力推进，看着是「AI 更聪明」，实际是
	# **AI 自带 debuff**：推进 → drive_accel 大 → 对磨时挤压压力 N_press = m_red·a_n
	# 也大 → 切向摩擦冲量更大 → AI 掉转速远快于躺平的玩家（玩家胜率因此畸高）。
	# 现在所有陀螺一视同仁：发射初速 + 进动漂移 + 碗坡向心力 + 碰撞，全交给物理。
	_elapsed += delta

	# 贴身对磨的持续结算（body_entered 只报跃变，粘住之后就哑了）
	TopsRules.resolve_ongoing_contacts(_tops)

	for t in _tops:
		TopsRules.decay(t, delta, CENTER, _arena_radius)
		_check_death(t)

	_update_shrink(delta)
	_reap_dead()
	_update_trails(delta)
	_update_camera()

	if _alive_count() <= 1:
		_end_game()
	_update_hud()


## ① 开始游戏：标题界面 → 蓄力阶段
func start_game() -> void:
	if _phase != Phase.TITLE:
		return
	_phase = Phase.LAUNCH
	_input_lock = true          # 开始那一下的按键/点击不当作蓄力
	_power = POWER_MIN
	_charging = false
	_charge_up = true
	if _ui != null:
		_ui.show_launch()


## 结算：战斗阶段 → 结算界面
func _end_game() -> void:
	if _phase == Phase.RESULT:
		return
	_phase = Phase.RESULT
	_finished = true
	_won = _player_ok() and _player.alive
	_flash = 1.0
	if _place == 0:
		_place = 1
	if _ui != null:
		var kills: int = _player.kills if _player_ok() else 0
		_ui.show_result(_won, _place, _elapsed, kills)


## 输入锁：开始游戏那一次的键鼠按下不算蓄力，全部松开后才解锁
func _update_input_lock() -> void:
	if not _input_lock:
		return
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
			or Input.is_action_pressed("tops_boost") \
			or Input.is_action_pressed("ui_accept"):
		return
	_input_lock = false


# ── ② 蓄力 / ③ 放陀螺：玩家唯一的决策点 ──
func _update_launch_input(delta: float) -> void:
	if not _player_ok():
		return
	# 鼠标：把屏幕点投射到 y=TOP_Y 的水平面，反算出世界 XZ 方向
	var mouse_target := _mouse_plane_target()
	if absf(mouse_target.x) < INF and absf(mouse_target.y) < INF:
		var to_mouse: Vector2 = mouse_target - _player.plane_pos()
		if to_mouse.length_squared() > 100.0:
			_aim_dir = to_mouse.normalized()

	var turn := 0.0
	if Input.is_action_pressed("tops_left"):
		turn -= 1.0
	if Input.is_action_pressed("tops_right"):
		turn += 1.0
	if turn != 0.0:
		_aim_dir = _aim_dir.rotated(turn * AIM_TURN_RATE * delta).normalized()

	var hold: bool = (not _input_lock) and (Input.is_action_pressed("tops_boost") \
		or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT))
	if hold:
		_charging = true
		_power += (POWER_RATE if _charge_up else -POWER_RATE) * delta
		if _power >= POWER_MAX:
			_power = POWER_MAX
			_charge_up = false
		elif _power <= POWER_MIN:
			_power = POWER_MIN
			_charge_up = true
	elif _charging:
		_launch(_power)


## 把当前鼠标位置投射到 y=TOP_Y 水平面，返回世界 XZ 命中点（射线平行于 y 轴）
func _mouse_plane_target() -> Vector2:
	var cam := _camera
	if cam == null:
		return Vector2.ZERO
	var mouse := get_viewport().get_mouse_position()
	var from := cam.project_ray_origin(mouse)
	var dirw := cam.project_ray_normal(mouse)
	if absf(dirw.y) < 0.0001:
		return Vector2(INF, INF)   # 射线近乎水平，无有效命中
	var t: float = (TOP_Y - from.y) / dirw.y
	if t < 0.0:
		return Vector2(INF, INF)
	var hit := from + dirw * t
	return Vector2(hit.x, hit.z)


func _launch(power: float) -> void:
	var perfect: bool = power >= POWER_PERFECT
	for t in _tops:
		var dir: Vector2
		var pw: float
		var bonus := 1.0
		if t == _player:
			dir = _aim_dir
			pw = power
			bonus = PERFECT_SPEED_BONUS if perfect else 1.0
		else:
			# ⚠ 发射是 AI 唯一的「决策」（进场后一律不可操控），方向必须撒开：
			#   全都瞄圆心的话五颗同时挤到中心、谁也够不到边缘，
			#   撞墙弹开那条机制就彻底死了（实测撞墙 0 次）。
			#   ±1.2 rad（±69°）里有的直插中心、有的贴着碗壁扫一整圈。
			var to_center: Vector2 = (CENTER - t.plane_pos()).normalized()
			dir = to_center.rotated(randf_range(-1.2, 1.2))
			pw = randf_range(0.55, 1.0)
		t.facing = dir.angle()
		t.drift_phase = t.facing
		t.freeze = false        # 解冻后速度才生效
		# 水平面初速 → Vector3(vx, 0, vz)
		t.linear_velocity = Vector3(dir.x, 0.0, dir.y) * (t.move_speed * (LAUNCH_SPEED_MIN + LAUNCH_SPEED_SPAN * pw) * bonus)
		t.thrusting = false      # 玩家的陀螺从此不再接受任何方向输入
		t.boosting = false
		t.set_collides(true)
	_phase = Phase.BATTLE
	_charging = false
	if _ui != null:
		_ui.show_battle()
		_ui.toast("完美发射！" if perfect else "放陀螺！",
				UiTheme.C_GOLD if perfect else UiTheme.C_PRIMARY, 0.8)


func _alive_count() -> int:
	var n := 0
	for t in _tops:
		if t.alive:
			n += 1
	return n


## 玩家陀螺可能已经出局、退场播完被 queue_free 了 —— 之后引用一律先过这道闸。
func _player_ok() -> bool:
	return _player != null and is_instance_valid(_player)


## 出局陀螺的退场动画播完 → 从 _tops 摘掉并真正移出场景。
## 倒地的陀螺不该一直堆在场上：既挡视线，也会让「还剩几个」在画面上读不出来。
func _reap_dead() -> void:
	for i in range(_tops.size() - 1, -1, -1):
		var t: TopTop = _tops[i]
		if t.alive or not t.despawn_done:
			continue
		_tops.remove_at(i)
		t.queue_free()


func _check_death(t: TopTop) -> void:
	if not t.alive or t.spin > 0.0:
		return
	if t == _player:
		_place = _alive_count()  # 玩家是第几名（其余存活者 + 自己）
	t.kill()


func _on_top_died(top: TopTop) -> void:
	var killer_id: int = top.last_hit_by
	for t in _tops:
		if t.top_id == killer_id and t.alive:
			t.kills += 1
			t.spin = minf(t.spin + TopsRules.KILL_HEAL, t.spin_cap)
	if _ui == null:
		return
	if top == _player:
		_ui.toast("你的陀螺停了", UiTheme.C_DANGER, 1.2)
	elif _player_ok() and killer_id == _player.top_id:
		_ui.toast("击倒对手！", UiTheme.C_PRIMARY, 0.7)


func _update_shrink(delta: float) -> void:
	if _elapsed <= SHRINK_START:
		return
	var floor_r: float = BASE_RADIUS * SHRINK_MIN_RATIO
	_arena_radius = maxf(_arena_radius - BASE_RADIUS * SHRINK_RATIO_PER_SEC * delta, floor_r)
	# 缩圈：把每段墙沿其方位角径向平移到当前半径处。碰撞面精确跟随玩法半径，
	# 杜绝「缩放盒子但内表面没真正收进来」导致的逃逸缺口。
	_place_wall(_arena_radius)


## 墙盒中心到场地中心的距离：让**内表面**恰好落在硬边界（arena_radius + WALL_INNER_OFFSET）。
## 别再写死 r+30 —— 那是「内偏移 20 + 半厚 10」在特定厚度下的巧合值，
## 一旦 WALL_INNER_OFFSET 随场地等比缩放，写死的 30 就会让碰撞面和玩法半径脱节
## （墙缩进来了 → 陀螺提前撞墙；或墙外扩了 → 从缺口溜出去）。
func _wall_offset(r: float) -> float:
	return r + TopsRules.WALL_INNER_OFFSET + WALL_THICKNESS * 0.5


## 把所有墙段定位到半径 r 处（保持各自方位角不变）。y 恒为 30、scale 恒为 1。
func _place_wall(r: float) -> void:
	var off := _wall_offset(r)
	for i in _wall_segs.size():
		var a: float = _wall_angles[i]
		_wall_segs[i].position = Vector3(cos(a) * off, 30.0, sin(a) * off)
		_wall_segs[i].scale = Vector3.ONE
	_update_bowl(r)   # 碗跟着一起收，视觉边界与碰撞边界始终对齐


## 碗体缩放：让平底半径恰好等于当前硬边界（arena_radius + 墙内偏移）。
## ⚠ 单位碗的**半径是归一化的（平底 = 1.0）**，而母线的高度是**世界单位**——
## 所以 x/z 必须乘 bound，y 只按 bound/BASE_BOUND 缩：
##   · 坡的世界水平跨度 = span·bound，坡高 = WALL_TOP·(bound/BASE_BOUND)
##   → 倾角 = atan(WALL_TOP / (span·BASE_BOUND)) = SLOPE_DEG，**恒定不随缩圈变**
## 若 y 也乘 bound，碗壁会高到 7000；若 y 恒为 1，圈越小坡越陡缩成深桶。
func _update_bowl(arena_radius: float) -> void:
	if _bowl == null:
		return
	var bound: float = arena_radius + TopsRules.WALL_INNER_OFFSET
	_bowl.scale = Vector3(bound, bound / TopsArena.BASE_BOUND, bound)


## 取景半径：按碗的外沿算，而不是按玩法半径 —— 否则碗坡会被切在画面外。
## 外沿随倾角走（坡越缓，外沿铺得越开），所以这里读的是算出来的 outer_scale()。
## 坡顶那点高度由 CAM_FIT_MARGIN 的余量吃下，不必再单独补偿。
func _arena_outer_radius() -> float:
	return (_arena_radius + TopsRules.WALL_INNER_OFFSET) * TopsArena.outer_scale()


func _update_trails(delta: float) -> void:
	_trail_t += delta
	if _trail_t < TRAIL_STEP:
		return
	_trail_t = 0.0
	for t in _tops:
		t.trail.append(t.plane_pos())
		while t.trail.size() > TRAIL_MAX:
			t.trail.remove_at(0)


## 斜俯视相机：仰角固定、距离随缩圈自动重算 —— 圈越小镜头越近、看得越清。
## 改 CAM_ELEVATION_DEG 一个常量即可在「纯俯视 ↔ 斜俯视」之间切换，取景自动跟上。
func _update_camera() -> void:
	if _camera == null:
		return
	var elev: float = clampf(CAM_ELEVATION_DEG, CAM_MIN_ELEVATION_DEG, 90.0)
	var e: float = deg_to_rad(elev)
	var d: float = _fit_distance(_arena_outer_radius())
	# 倾斜后视锥与地面的交线是个**梯形**：远端（屏幕上方）铺得比近端（屏幕下方）远。
	# 把瞄点沿 +Z 挪半个差值，场地中心才会落在画面正中，而不是偏上。
	var reach: Vector2 = _ground_reaches(e)
	var shift: float = (reach.x - reach.y) * 0.5 * d
	_camera.position = Vector3(CENTER.x, TOP_Y + d * sin(e),
			CENTER.y + shift + d * cos(e))
	_camera.rotation_degrees = Vector3(-elev, 0.0, 0.0)


## 视锥与地面的纵向覆盖（单位：相机距离 d）。x = 远端（屏幕上方 -Z），y = 近端（屏幕下方 +Z）
func _ground_reaches(e: float) -> Vector2:
	var a: float = deg_to_rad(CAM_FOV) * 0.5
	# 远端射线与地面夹角 e-a：夹角越小打得越远；e-a<=0 时射线朝上，覆盖无限远
	var far: float = INF if e - a <= 0.0 else sin(e) / tan(e - a) - cos(e)
	# 近端射线夹角 e+a；e+a>90 时 tan 为负，射线越过天顶落到相机后侧，覆盖量反而很小
	var near: float = cos(e) - sin(e) / tan(e + a)
	return Vector2(maxf(far, 0.1), maxf(near, 0.1))


## 相机到瞄点的距离：让半径 radius 的场地在视口里完整入画（纵向梯形 + 横向宽度都要满足）
func _fit_distance(radius: float) -> float:
	var e: float = deg_to_rad(clampf(CAM_ELEVATION_DEG, CAM_MIN_ELEVATION_DEG, 90.0))
	var a: float = deg_to_rad(CAM_FOV) * 0.5
	var need: float = radius * CAM_FIT_MARGIN
	var reach: Vector2 = _ground_reaches(e)
	var d_v: float = need / ((reach.x + reach.y) * 0.5)
	var vp: Vector2i = get_viewport().size
	var d_h: float = need / (tan(a) * (float(vp.x) / float(maxi(vp.y, 1))))
	return maxf(maxf(d_v, d_h), CAM_MIN_DISTANCE)


## 转速表：把每个陀螺的**真实自转角速度**刷新进界面层。
## 已被 queue_free 的对象（退场播完）读不到了，按「已出局」画成 0。
func _update_roster() -> void:
	for i in _roster_data.size():
		var t: TopTop = _roster[i]
		var row: Dictionary = _roster_data[i]
		if is_instance_valid(t):
			row["spin"] = t.spin
			row["spin_max"] = t.spin_cap
			row["omega"] = t.omega()
			row["alive"] = t.alive
		else:
			row["spin"] = 0.0
			row["omega"] = 0.0
			row["alive"] = false


# ── HUD：数据推给界面层（中文由系统字体渲染，见 src/ui_font.gd）──
func _update_hud() -> void:
	if _ui == null:
		return
	_ui.set_stats(_alive_count(), _tops.size(), _elapsed, _elapsed > SHRINK_START)
	_update_roster()
	_ui.set_roster(_roster_data)
	if _player_ok():
		_ui.set_spin(_player.spin, _player.spin_cap)
		_ui.set_mass(_player.mass_kg * 1000.0)
		_ui.set_power(_power, _charging, _power >= POWER_PERFECT)
	match _phase:
		Phase.TITLE:
			_ui.set_step(0)
			_ui.set_hint("")
		Phase.LAUNCH:
			_ui.set_step(1)
			_ui.set_hint("鼠标 或 ← → 调方向 · 按住 空格 / Shift / 左键 蓄力 · 松手放陀螺")
		Phase.BATTLE:
			_ui.set_step(3)
			_ui.set_hint("已进场 · 陀螺靠初速 + 进动漂移 + 碰撞运动，无法操控")
		Phase.RESULT:
			_ui.set_step(3)
			_ui.set_hint("")
