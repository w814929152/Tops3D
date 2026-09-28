class_name TopsArena
extends RefCounted
##
## 竞技场碗体模型工厂（真 3D 程序化网格）——「周围高、中间低」的浅碗。
##
## 造型是一条母线绕 Y 轴旋转出来的旋转体（lathe）：
##   · 归一化半径 ≤ 1.0 的部分**恒为平底 y=0** —— 陀螺中心永远在 y=0，地面一抬就会陷进去
##   · 1.0 之外才是按 SLOPE_DEG 匀速抬升的碗坡、碗沿与外壁，纯视觉，不参与任何规则判定
##
## 返回的是**单位碗**（平底半径 = 1.0），调用方用 scale = 当前硬边界 / BASE_BOUND 缩放：
## 缩圈时整只碗等比跟着收（**含 y**），倾角恒为 SLOPE_DEG —— 圈越小碗越浅越小，
## 不会退化成「越缩越深的桶」。
##
## 碗坡的坡度同时被 TopsRules.slope_accel() 读走，作为把陀螺往中心赶的向心力，
## 所以「周围高中间低」在玩法上是真的起作用，不只是一张贴图。
##

const SEGMENTS := 64

## 碗坡倾角（度）—— 这是「倾斜角度」的唯一来源，几何与物理共用。
## 14° 是肉眼舒服的浅碟；再陡就变成深桶，陀螺看起来像掉进井里。
const SLOPE_DEG := 14.0
## 碗沿相对平底的高度 = BASE_BOUND × RIM_HEIGHT_RATIO（**必须等比**，不能写死世界单位）。
## 反例：写死 26 wu 时把场地从 250 缩到 150，碗坡的绝对宽/高（104/26）却不变，
## 相对就变成「深桶」——视觉外沿从玩法半径的 1.45 倍涨到 1.67 倍，
## 取景被碗壁撑开，镜头推不近，陀螺反而显得更小，正好和「缩小场地」的意图相反。
## 基准值：BASE_BOUND=270 时碗沿高 26 wu（= 270 × 0.0963）。
const RIM_HEIGHT_RATIO := 26.0 / 270.0
static var WALL_TOP := 26.0   # = BASE_BOUND × RIM_HEIGHT_RATIO，build() 时按硬边界重算
## 碗沿顶面宽度 / 外壁厚度（归一化）
const LIP_W := 0.025
const SHELL_W := 0.035
## 平底半径（归一化）：1.0 = 硬边界（arena_radius + WALL_INNER_OFFSET）
const FLOOR_R := 1.0

## 建碗时的基准硬边界（main 传入）。碗坡的归一化跨度必须按它换算，
## 缩放之后世界空间里的倾角才仍然等于 SLOPE_DEG。
static var BASE_BOUND := 270.0

const C_FLOOR := Color("#1E2632")
const C_LIP := Color("#4E8FB8")

## 碗坡的归一化水平跨度：让世界空间里的坡度恰好是 SLOPE_DEG
static func _slope_span() -> float:
	var run: float = WALL_TOP / tan(deg_to_rad(SLOPE_DEG))   # 世界单位的水平跨度
	return run / BASE_BOUND


## 外沿半径（归一化）—— 相机取景要靠它算，否则碗坡会被切在画面外
static func outer_scale() -> float:
	return FLOOR_R + _slope_span() + LIP_W + SHELL_W


## 母线：(归一化半径, 世界高度)
static func _profile() -> Array[Vector2]:
	var span: float = _slope_span()
	return [
		Vector2(0.00, 0.0),
		Vector2(0.70, 0.0),
		Vector2(FLOOR_R, 0.0),                          # ← 平底到此为止，之后再抬升
		Vector2(FLOOR_R + span * 0.06, WALL_TOP * 0.012),  # 坡底小圆角，避免硬折角
		Vector2(FLOOR_R + span * 0.30, WALL_TOP * 0.30),
		Vector2(FLOOR_R + span * 0.60, WALL_TOP * 0.60),
		Vector2(FLOOR_R + span * 0.85, WALL_TOP * 0.85),
		Vector2(FLOOR_R + span, WALL_TOP),              # 坡顶（碗沿内缘）
		Vector2(FLOOR_R + span + LIP_W, WALL_TOP),      # 碗沿顶面
		Vector2(outer_scale(), 0.0),                    # 外壁落回地面，给碗沿做出厚度
	] as Array[Vector2]

const LIP_SEG := 8            # 只有「碗沿顶面」这一段上亮色，形成一圈高亮边界环


## 搭一个单位碗，返回容器节点（调用方负责 add_child + 设 scale）
static func build(base_bound: float) -> Node3D:
	BASE_BOUND = maxf(base_bound, 1.0)
	WALL_TOP = BASE_BOUND * RIM_HEIGHT_RATIO   # 碗沿随场地等比，形状自相似
	var pts: Array[Vector2] = _profile()
	var nrm: Array[Vector2] = _point_normals(pts)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in SEGMENTS:
		var a0: float = TAU * float(i) / float(SEGMENTS)
		var a1: float = TAU * float(i + 1) / float(SEGMENTS)
		var d0 := Vector2(cos(a0), sin(a0))
		var d1 := Vector2(cos(a1), sin(a1))
		var u0: float = float(i) / float(SEGMENTS)
		var u1: float = float(i + 1) / float(SEGMENTS)
		for j in pts.size() - 1:
			var col: Color = C_LIP if j == LIP_SEG else C_FLOOR
			var v0: float = float(j) / float(pts.size() - 1)
			var v1: float = float(j + 1) / float(pts.size() - 1)
			# 四边形 (j,a0) - (j,a1) - (j+1,a1) - (j+1,a0) 拆两个三角形
			_vert(st, pts[j], nrm[j], d0, Vector2(u0, v0), col)
			_vert(st, pts[j + 1], nrm[j + 1], d0, Vector2(u0, v1), col)
			_vert(st, pts[j + 1], nrm[j + 1], d1, Vector2(u1, v1), col)

			_vert(st, pts[j], nrm[j], d0, Vector2(u0, v0), col)
			_vert(st, pts[j + 1], nrm[j + 1], d1, Vector2(u1, v1), col)
			_vert(st, pts[j], nrm[j], d1, Vector2(u1, v0), col)

	var mi := MeshInstance3D.new()
	mi.name = &"Bowl"
	mi.mesh = st.commit()
	mi.material_override = _mat()

	var root := Node3D.new()
	root.name = &"ArenaBowl"
	root.add_child(mi)
	return root


# ── 小工具 ──

## 旋转体顶点：母线上的 (r, y) + 平面法线 (nr, ny) 绕 Y 轴转到方位角方向 d
static func _vert(st: SurfaceTool, p: Vector2, n: Vector2, d: Vector2, uv: Vector2,
		col: Color) -> void:
	st.set_normal(Vector3(n.x * d.x, n.y, n.x * d.y).normalized())
	st.set_uv(uv)
	st.set_color(col)
	st.add_vertex(Vector3(p.x * d.x, p.y, p.x * d.y))


## 逐点法线：相邻两段法线的平均（平滑着色；SurfaceTool.generate_normals() 只给刻面法线）
static func _point_normals(pts: Array[Vector2]) -> Array[Vector2]:
	var seg_n: Array[Vector2] = []
	for i in pts.size() - 1:
		var d: Vector2 = pts[i + 1] - pts[i]
		seg_n.append(Vector2(-d.y, d.x).normalized())   # 平底段 → (0,1) 朝上；碗壁 → 朝内
	var out: Array[Vector2] = []
	for i in pts.size():
		var a: Vector2 = seg_n[maxi(i - 1, 0)]
		var b: Vector2 = seg_n[mini(i, seg_n.size() - 1)]
		out.append((a + b).normalized())
	return out


static func _mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true   # 碗沿那圈高亮靠顶点色，不用再叠一层网格
	m.albedo_color = Color.WHITE
	m.roughness = 0.92
	m.metallic = 0.10
	m.cull_mode = BaseMaterial3D.CULL_DISABLED   # 旋转体绕序难保证，双面省事
	return m
