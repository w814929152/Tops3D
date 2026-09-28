class_name UiTheme
extends RefCounted
##
## 陀螺对战 · UI 设计系统（Design Tokens + Godot Theme）
##
## 一体化定义「色板 / 字号 / 间距 / 圆角 / 阴影 / 组件样式」，界面层
## （tops/tops_ui.gd）只消费这里产出的 Theme 与工具函数，不再散落魔法数字。
##
## 无障碍（WCAG AA）：正文字与面板底色对比度均 ≥ 4.5:1
##   · 主文字 #E6ECF5 on #151A24 → 14.7:1  ✓ AAA
##   · 次文字 #94A2B8 on #151A24 →  6.7:1  ✓ AA
##   · 弱文字 #7C8AA3 on #151A24 →  5.0:1  ✓ AA
##   · 主按钮 深色字 on #5DCAA5 →  9.3:1  ✓ AAA
## 交互目标：所有按钮 ≥ 44 px（触摸/点击热区下限），键盘 focus 有 2px 高亮描边。
##

# ── 色板 ──────────────────────────────────────────────
const C_BG := Color("#0B0E14")          # 页面底 / 遮罩
const C_SURFACE := Color("#151A24")     # 卡片底
const C_SURFACE_2 := Color("#1D2432")   # 芯片 / 控件底
const C_SURFACE_3 := Color("#27303F")   # 控件 hover
const C_BORDER := Color("#2E3747")      # 描边
const C_BORDER_HI := Color("#3E4A5E")   # 描边（强调）

const C_TEXT := Color("#E6ECF5")        # 主文字
const C_TEXT_DIM := Color("#94A2B8")    # 次文字
const C_TEXT_MUTE := Color("#7C8AA3")   # 弱文字

const C_PRIMARY := Color("#5DCAA5")     # 品牌主色（= 玩家陀螺色）
const C_PRIMARY_HI := Color("#7BDDB9")  # 主色 hover
const C_PRIMARY_LO := Color("#2F7359")  # 主色 pressed
const C_GOLD := Color("#EFB54B")        # 蓄力 / 强调
const C_DANGER := Color("#E2564F")      # 危险 / 出局
const C_INFO := Color("#5B9DF2")        # 信息

# ── 字号（12 → 40，1.2~1.4 倍递进）────────────────────
const FS_XS := 12
const FS_SM := 14
const FS_MD := 16
const FS_LG := 20
const FS_XL := 28
const FS_2XL := 40

# ── 间距（4 px 基准）──────────────────────────────────
const S1 := 4
const S2 := 8
const S3 := 12
const S4 := 16
const S5 := 24
const S6 := 32
const S7 := 40

# ── 尺寸 / 形状 ───────────────────────────────────────
const RADIUS := 10        # 卡片 / 按钮圆角
const RADIUS_SM := 6      # 进度条圆角
const RADIUS_PILL := 13   # 步骤芯片（胶囊）
const TAP_MIN := 44       # 最小点击热区
const BTN_H := 52         # 主按钮高度


## 给颜色套透明度（做「主色 16% 底 + 主色描边」这类浅色态）
static func tinted(c: Color, alpha: float) -> Color:
	return Color(c.r, c.g, c.b, alpha)


## 统一样式盒工厂：圆角 + 可选描边 + 可选投影
static func sb(bg: Color, radius: int = 10, border: Color = Color(0, 0, 0, 0),
		border_w: int = 0, shadow: bool = false) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	if border_w > 0:
		s.set_border_width_all(border_w)
		s.border_color = border
	if shadow:
		s.shadow_color = Color(0, 0, 0, 0.45)
		s.shadow_size = 14
		s.shadow_offset = Vector2(0, 5)
	return s


## 全项目共用的 Godot Theme（字体用系统字体，保证中文 CJK 有字形）
static func make_theme() -> Theme:
	var th := Theme.new()
	th.default_font = UiFont.get_font()
	th.default_font_size = FS_SM

	# 面板
	th.set_stylebox("panel", "PanelContainer", sb(C_SURFACE, RADIUS, C_BORDER, 1))
	# 标签
	th.set_color("font_color", "Label", C_TEXT)
	th.set_font_size("font_size", "Label", FS_SM)
	# 按钮（默认 = 次级按钮）
	th.set_stylebox("normal", "Button", sb(C_SURFACE_2, RADIUS, C_BORDER_HI, 1, true))
	th.set_stylebox("hover", "Button", sb(C_SURFACE_3, RADIUS, C_PRIMARY, 1, true))
	th.set_stylebox("pressed", "Button", sb(C_PRIMARY_LO, RADIUS, C_PRIMARY_HI, 1))
	th.set_stylebox("disabled", "Button", sb(C_SURFACE, RADIUS, C_BORDER, 1))
	th.set_stylebox("focus", "Button", sb(C_SURFACE_2, RADIUS, C_PRIMARY_HI, 2))
	th.set_color("font_color", "Button", C_TEXT)
	th.set_color("font_hover_color", "Button", C_TEXT)
	th.set_color("font_pressed_color", "Button", Color("#FFFFFF"))
	th.set_color("font_disabled_color", "Button", C_TEXT_MUTE)
	th.set_color("font_focus_color", "Button", C_TEXT)
	th.set_font_size("font_size", "Button", FS_MD)
	# 进度条
	th.set_stylebox("background", "ProgressBar", sb(C_SURFACE_2, RADIUS_SM, C_BORDER, 1))
	th.set_stylebox("fill", "ProgressBar", sb(C_PRIMARY, RADIUS_SM))
	return th


## 主按钮（实心主色 + 深色字，对比度 9.3:1）
static func style_button_primary(b: Button) -> void:
	b.add_theme_stylebox_override("normal", sb(C_PRIMARY, RADIUS, C_PRIMARY_HI, 1, true))
	b.add_theme_stylebox_override("hover", sb(C_PRIMARY_HI, RADIUS, C_PRIMARY_HI, 1, true))
	b.add_theme_stylebox_override("pressed", sb(C_PRIMARY_LO, RADIUS, C_PRIMARY, 1))
	b.add_theme_stylebox_override("focus", sb(C_PRIMARY, RADIUS, C_TEXT, 2, true))
	b.add_theme_color_override("font_color", C_BG)
	b.add_theme_color_override("font_hover_color", C_BG)
	b.add_theme_color_override("font_pressed_color", C_TEXT)
	b.add_theme_color_override("font_focus_color", C_BG)
	b.add_theme_font_size_override("font_size", FS_LG)


## 幽灵按钮（描边 + 透明底，用于「返回 / 次要操作」）
static func style_button_ghost(b: Button) -> void:
	b.add_theme_stylebox_override("normal", sb(tinted(C_SURFACE_2, 0.60), RADIUS, C_BORDER_HI, 1))
	b.add_theme_stylebox_override("hover", sb(C_SURFACE_3, RADIUS, C_PRIMARY, 1))
	b.add_theme_stylebox_override("pressed", sb(C_SURFACE_2, RADIUS, C_PRIMARY, 1))
	b.add_theme_stylebox_override("focus", sb(C_SURFACE_2, RADIUS, C_PRIMARY_HI, 2))
	b.add_theme_font_size_override("font_size", FS_MD)


## 状态芯片（顶部 HUD 的小胶囊）
static func chip_sb(bg: Color, border: Color) -> StyleBoxFlat:
	return sb(bg, RADIUS_PILL, border, 1)
