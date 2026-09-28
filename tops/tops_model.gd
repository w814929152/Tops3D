class_name TopsModel
extends RefCounted
##
## 陀螺本体模型工厂（真 3D 组合件）。
##
## 把原来「一根圆柱」换成有模有样的战斗陀螺，自上而下七层：
##   顶部旋钮 → 天盖 → 攻击环（带 8 颗齿）→ 配重盘 → 裙摆 → 尖头
## 全部挂在一个容器 Node3D 下，容器由 TopTop 驱动绕 Y 轴自转（本体 RigidBody3D 仍
## lock_rotation，自转纯视觉，不参与任何规则判定）。
##
## 尺寸一律以 TopTop.top_radius 为单位比例缩放 —— DART / BALANCED / RAM 三种体型
## 自动等比放大缩小，碰撞球半径不用改。
##

## 攻击环齿数（转起来全靠它看得见）
const TEETH := 8

# ── 各层相对 top_radius 的比例与层高（改这里就能调整造型）──
const K_TIP_R := 0.22
const K_TIP_H := 0.34
const K_SKIRT_TOP := 0.85
const K_SKIRT_H := 0.30
const K_DISK_R := 0.94
const K_DISK_H := 0.14
const K_RING_R := 1.00
const K_RING_H := 0.34
const K_TOOTH_OUT := 0.18   # 齿沿径向探出的长度
const K_CAP_TOP := 0.55
const K_CAP_H := 0.22
const K_KNOB_R := 0.30


## 搭一个陀螺模型，返回容器节点（调用方负责 add_child 并交给 TopTop.model 驱动自转）
static func build(t: TopTop) -> Node3D:
	var r: float = t.top_radius
	var base: Color = TopsArt.top_color(t.top_id)
	var root := Node3D.new()
	root.name = &"Model"

	# y 从 0（尖头触地）往上叠：tip → skirt → disk → ring → teeth → cap → knob
	var y: float = 0.0

	# 1) 尖头：上宽下尖的锥，尖端正好落在地面 y=0
	root.add_child(_cone(r * K_TIP_R, r * K_TIP_H, y + r * K_TIP_H * 0.5,
			_mat(base.darkened(0.55), 0.55, 0.40)))
	y += r * K_TIP_H

	# 2) 裙摆：下窄上宽的倒锥，把重量感压到下半身
	root.add_child(_cyl(r * K_SKIRT_TOP, r * K_TIP_R, r * K_SKIRT_H, y + r * K_SKIRT_H * 0.5,
			_mat(base, 0.35, 0.45)))
	y += r * K_SKIRT_H

	# 3) 配重盘：扁扁一圈金属盘，分出层次
	root.add_child(_cyl(r * K_DISK_R, r * K_DISK_R, r * K_DISK_H, y + r * K_DISK_H * 0.5,
			_mat(base.darkened(0.25), 0.70, 0.30)))
	y += r * K_DISK_H

	# 4) + 5) 攻击环（最宽一圈）+ 环上齿：齿是唯一能看出「在自转」的部件
	var ring_y: float = y + r * K_RING_H * 0.5
	root.add_child(_cyl(r * K_RING_R, r * K_RING_R, r * K_RING_H, ring_y,
			_mat(base, 0.35, 0.45)))
	for i in TEETH:
		var a: float = TAU * float(i) / float(TEETH)
		var tooth := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(r * K_TOOTH_OUT, r * K_RING_H * 0.78, r * 0.30)
		tooth.mesh = box
		tooth.position = Vector3(cos(a) * (r * K_RING_R + r * K_TOOTH_OUT * 0.5), ring_y,
				sin(a) * (r * K_RING_R + r * K_TOOTH_OUT * 0.5))
		tooth.rotation_degrees = Vector3(0.0, rad_to_deg(-a), 0.0)   # 盒子 x 轴指向径向外侧
		tooth.material_override = _mat(base.lightened(0.35), 0.75, 0.28)
		root.add_child(tooth)
	y += r * K_RING_H

	# 6) 天盖：上窄下宽，把攻击环压住
	root.add_child(_cyl(r * K_CAP_TOP, r * K_RING_R, r * K_CAP_H, y + r * K_CAP_H * 0.5,
			_mat(base.darkened(0.35), 0.45, 0.40)))
	y += r * K_CAP_H

	# 7) 顶部旋钮：一颗小圆球收顶
	root.add_child(_sphere(r * K_KNOB_R, y + r * K_KNOB_R * 0.7,
			_mat(base.lightened(0.50), 0.60, 0.25)))

	return root


# ── 小工具：造带材质的网格件 ──
static func _cyl(top_r: float, bottom_r: float, h: float, y: float,
		mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = top_r
	m.bottom_radius = bottom_r
	m.height = h
	mi.mesh = m
	mi.position = Vector3(0.0, y, 0.0)
	mi.material_override = mat
	return mi


## 圆锥：尖朝下（上底 r、下底 0），尖头正好戳在地面上
static func _cone(top_r: float, h: float, y: float, mat: StandardMaterial3D) -> MeshInstance3D:
	return _cyl(top_r, 0.0, h, y, mat)


static func _sphere(radius: float, y: float, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	mi.mesh = m
	mi.position = Vector3(0.0, y, 0.0)
	mi.material_override = mat
	return mi


static func _mat(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = roughness
	return m
