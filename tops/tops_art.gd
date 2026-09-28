class_name TopsArt
extends RefCounted
##
## 陀螺对战 · 绘制辅助（真 3D 版）。
##
## 3D 化后，本体/场地/灯光/相机都由真 3D 节点渲染（见 tops_main.gd），
## 不再需要 2D 手搓椭圆投影。本文件只保留**纯函数**的颜色/工具方法，
## 供 TopTop 网格材质与 headless 断言使用（零渲染依赖、可测）。
##

const C_PLAYER := Color("#5DCAA5")
const C_FOE := Color("#E9A23B")
const C_FOE2 := Color("#D4537E")

const C_SPIN_HI := Color("#5DCAA5")
const C_SPIN_MID := Color("#EF9F27")
const C_SPIN_LO := Color("#E24B4A")


static func top_color(top_id: int) -> Color:
	if top_id == 1:
		return C_PLAYER
	return C_FOE if top_id % 2 == 0 else C_FOE2


static func spin_color(ratio: float) -> Color:
	if ratio > 0.55:
		return C_SPIN_HI
	if ratio > 0.28:
		return C_SPIN_MID
	return C_SPIN_LO
