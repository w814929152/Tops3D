class_name TopsUi
extends CanvasLayer
##
## 陀螺对战 · 界面层（CanvasLayer + Control，全代码搭建，零 .tscn 依赖）
##
## 三步骤流程（玩法节奏被显式做成 UI 步骤，不再只是「按住松手」的黑箱）：
##   ① 开始游戏 —— 标题卡片上的主按钮（或 Enter / 空格）
##   ② 蓄力     —— 底部蓄力槽，按住 空格 / Shift / 鼠标左键 充能（来回摆动 → 考验松手时机）
##   ③ 放陀螺   —— 松手即发射，屏幕中上弹「放陀螺！」横幅；踩中金色完美区间额外加成
##
## 设计令牌全部来自 src/ui_theme.gd，本文件不写魔法颜色。
##
## 结构
##   Root(Control · 满屏 · 不拦截输入)
##     ├ TopBar      左上：存活 / 时间 / 场地   右上：玩家转速条
##     ├ BottomDock  底部居中：三步流程条 + 蓄力槽 + 操作提示
##     ├ Toast       屏幕中上：瞬时横幅
##     ├ TitleScreen 全屏居中卡片：标题 + 规则 + 「开始游戏」
##     └ ResultScreen全屏居中卡片：名次 + 用时 + 「再来一局」
##

signal start_requested()
signal restart_requested()

## 步骤名（索引即步骤序号：0 开始游戏 / 1 蓄力 / 2 放陀螺 / 3 = 全部完成·对战中）
const STEP_TITLES: Array[String] = ["开始游戏", "蓄力", "放陀螺"]

var _root: Control
var _top_bar: Control
var _bottom_dock: Control

var _chip_alive: PanelContainer
var _chip_time: PanelContainer
var _chip_field: PanelContainer

var _spin_gauge: Gauge
var _spin_value: Label

var _steps: Array[PanelContainer] = []
var _power_box: VBoxContainer
var _power_gauge: Gauge
var _power_value: Label
var _power_tag: Label
var _hint: Label

var _toast: Label
var _toast_tween: Tween

var _title_wrap: Control
var _result_wrap: Control
var _start_btn: Button
var _restart_btn: Button
var _result_title: Label
var _result_sub: Label
var _result_stats: Label

var _step_cur: int = -1


# ── 蓄力 / 转速槽：自绘控件（背景 + 完美区间 + 填充 + 居中文字）──
class Gauge extends Control:
	var value := 0.0
	var zone_lo := 0.85
	var zone_hi := 1.0
	var zone_visible := true
	var fill_color := UiTheme.C_PRIMARY
	var caption := ""

	var _bg: StyleBoxFlat
	var _fill: StyleBoxFlat
	var _zone: StyleBoxFlat

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_bg = UiTheme.sb(UiTheme.C_SURFACE_2, 6, UiTheme.C_BORDER, 1)
		_fill = UiTheme.sb(UiTheme.C_PRIMARY, 6)
		_zone = UiTheme.sb(UiTheme.tinted(UiTheme.C_GOLD, 0.28), 4)

	func set_value(v: float) -> void:
		value = clampf(v, 0.0, 1.0)
		queue_redraw()

	func set_fill(c: Color) -> void:
		fill_color = c
		_fill = UiTheme.sb(c, 6)
		queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		_bg.draw(get_canvas_item(), r)
		var pad := 2.0
		var w: float = maxf(r.size.x - pad * 2.0, 0.0)
		var h: float = maxf(r.size.y - pad * 2.0, 0.0)
		if zone_visible:
			var zx: float = pad + w * zone_lo
			var zw: float = w * (zone_hi - zone_lo)
			_zone.draw(get_canvas_item(), Rect2(zx, pad + 1.0, zw, h - 2.0))
		var fw: float = w * value
		if fw > 0.5:
			_fill.draw(get_canvas_item(), Rect2(pad, pad, fw, h))
		if caption != "":
			draw_string(UiFont.get_font(), Vector2(0.0, r.size.y * 0.5 + 4.0), caption,
					HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 12, UiTheme.C_TEXT)


func _ready() -> void:
	name = "TopsUi"
	layer = 8
	_build()
	show_title()


# ── 搭建 ──────────────────────────────────────────────
func _build() -> void:
	_root = Control.new()
	_root.name = "UiRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = UiTheme.make_theme()
	add_child(_root)

	_build_top_bar()
	_build_bottom_dock()
	_build_toast()
	_build_screens()


func _build_top_bar() -> void:
	_top_bar = MarginContainer.new()
	# ⚠ 用 anchors+offsets 一体化 preset：只 set_anchors_preset 会把 offsets 留成 0，
	#   贴底/贴边容器会被压成 0 高（min size 只能沿 grow 方向撑开）。
	_top_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_top_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_top_bar.grow_vertical = Control.GROW_DIRECTION_END
	_top_bar.offset_left = UiTheme.S5
	_top_bar.offset_right = -UiTheme.S5
	_top_bar.offset_top = UiTheme.S4
	_top_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_top_bar)

	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", UiTheme.S2)
	_top_bar.add_child(hb)

	_chip_alive = _stat_chip("存活")
	_chip_time = _stat_chip("时间")
	_chip_field = _stat_chip("场地")
	hb.add_child(_chip_alive)
	hb.add_child(_chip_time)
	hb.add_child(_chip_field)

	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(spacer)

	# 右上：玩家转速（= 血量）
	var sv := VBoxContainer.new()
	sv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sv.add_theme_constant_override("separation", 3)
	hb.add_child(sv)

	var sh := HBoxContainer.new()
	sh.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sh.alignment = BoxContainer.ALIGNMENT_END
	sh.add_theme_constant_override("separation", UiTheme.S2)
	sv.add_child(sh)
	sh.add_child(_label("转速", UiTheme.FS_XS, UiTheme.C_TEXT_DIM))
	_spin_value = _label("100 / 100", UiTheme.FS_SM, UiTheme.C_TEXT)
	sh.add_child(_spin_value)

	_spin_gauge = Gauge.new()
	_spin_gauge.custom_minimum_size = Vector2(220, 12)
	_spin_gauge.zone_visible = false
	sv.add_child(_spin_gauge)


func _build_bottom_dock() -> void:
	_bottom_dock = MarginContainer.new()
	_bottom_dock.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_bottom_dock.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_bottom_dock.grow_vertical = Control.GROW_DIRECTION_BEGIN   # min size 变化时向上撑
	_bottom_dock.offset_left = UiTheme.S5
	_bottom_dock.offset_right = -UiTheme.S5
	_bottom_dock.offset_bottom = -UiTheme.S5 + 2
	_bottom_dock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_bottom_dock)

	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	_bottom_dock.add_child(hb)

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", UiTheme.S3)
	hb.add_child(col)

	# ① 三步流程条
	var step_hb := HBoxContainer.new()
	step_hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	step_hb.alignment = BoxContainer.ALIGNMENT_CENTER
	step_hb.add_theme_constant_override("separation", UiTheme.S2)
	col.add_child(step_hb)
	for i in STEP_TITLES.size():
		if i > 0:
			var arrow := _label("›", UiTheme.FS_MD, UiTheme.C_TEXT_MUTE)
			arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
			step_hb.add_child(arrow)
		var chip := _step_chip(STEP_TITLES[i])
		_steps.append(chip)
		step_hb.add_child(chip)

	# ② 蓄力槽
	_power_box = VBoxContainer.new()
	_power_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_power_box.add_theme_constant_override("separation", 4)
	col.add_child(_power_box)

	var ph := HBoxContainer.new()
	ph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ph.alignment = BoxContainer.ALIGNMENT_CENTER
	ph.add_theme_constant_override("separation", UiTheme.S2)
	_power_box.add_child(ph)
	ph.add_child(_label("蓄力", UiTheme.FS_XS, UiTheme.C_TEXT_DIM))
	_power_value = _label("0%", UiTheme.FS_SM, UiTheme.C_TEXT)
	ph.add_child(_power_value)
	_power_tag = _label("", UiTheme.FS_XS, UiTheme.C_GOLD)
	ph.add_child(_power_tag)

	_power_gauge = Gauge.new()
	_power_gauge.custom_minimum_size = Vector2(380, 26)
	_power_gauge.zone_lo = 0.85
	_power_gauge.zone_hi = 1.0
	_power_box.add_child(_power_gauge)

	# 操作提示
	_hint = _label("", UiTheme.FS_SM, UiTheme.C_TEXT_DIM)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size = Vector2(560, 0)
	col.add_child(_hint)


func _build_toast() -> void:
	_toast = Label.new()
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toast.add_theme_font_size_override("font_size", UiTheme.FS_XL)
	_toast.add_theme_color_override("font_color", UiTheme.C_GOLD)
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.offset_left = -280.0
	_toast.offset_right = 280.0
	_toast.offset_top = 110.0
	_toast.offset_bottom = 156.0
	_toast.modulate.a = 0.0
	_toast.hide()
	_root.add_child(_toast)


func _build_screens() -> void:
	_title_wrap = _screen_shell()
	_root.add_child(_title_wrap)
	var t_center: CenterContainer = _title_wrap.get_meta("center")
	t_center.add_child(_build_title_card())

	_result_wrap = _screen_shell()
	_root.add_child(_result_wrap)
	var r_center: CenterContainer = _result_wrap.get_meta("center")
	r_center.add_child(_build_result_card())


## 全屏遮罩壳：半透明底 + 居中容器（返回 Control，居中容器存在 meta["center"]）
func _screen_shell() -> Control:
	var wrap := Control.new()
	wrap.set_anchors_preset(Control.PRESET_FULL_RECT)
	wrap.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.color = Color(UiTheme.C_BG.r, UiTheme.C_BG.g, UiTheme.C_BG.b, 0.72)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(dim)
	wrap.add_child(center)
	wrap.set_meta("center", center)
	return wrap


func _build_title_card() -> PanelContainer:
	var card := PanelContainer.new()
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.custom_minimum_size = Vector2(580, 0)
	card.add_theme_stylebox_override("panel",
			UiTheme.sb(UiTheme.C_SURFACE, 16, UiTheme.C_BORDER_HI, 1, true))

	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", UiTheme.S7)
	m.add_theme_constant_override("margin_right", UiTheme.S7)
	m.add_theme_constant_override("margin_top", UiTheme.S6)
	m.add_theme_constant_override("margin_bottom", UiTheme.S5)
	card.add_child(m)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", UiTheme.S3)
	m.add_child(v)

	var title := _label("陀螺对战", UiTheme.FS_2XL, UiTheme.C_TEXT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)

	var sub := _label("TOPS ARENA 3D · 发射制陀螺混战", UiTheme.FS_XS, UiTheme.C_TEXT_MUTE)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sub)

	v.add_child(_divider())

	var rules := _label(
			"5 人混战，最后一个还在转的赢。发射进场后完全无法操控 —— "
			+ "陀螺只靠发射初速、自转进动漂移与物理碰撞运动，"
			+ "全部策略压缩进「蓄力 × 角度」这一次决策。60 秒起场地收缩。",
			UiTheme.FS_SM, UiTheme.C_TEXT_DIM)
	rules.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rules.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rules.custom_minimum_size = Vector2(480, 0)
	v.add_child(rules)

	# 流程预览（只读三步）
	var prev := HBoxContainer.new()
	prev.alignment = BoxContainer.ALIGNMENT_CENTER
	prev.add_theme_constant_override("separation", UiTheme.S2)
	v.add_child(prev)
	for i in STEP_TITLES.size():
		if i > 0:
			prev.add_child(_label("›", UiTheme.FS_MD, UiTheme.C_TEXT_MUTE))
		var chip := _step_chip(STEP_TITLES[i])
		_apply_chip(chip, STEP_TITLES[i], 2)   # 2 = 待办态
		prev.add_child(chip)

	var btn := Button.new()
	btn.text = "开始游戏"
	btn.custom_minimum_size = Vector2(300, UiTheme.BTN_H)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	UiTheme.style_button_primary(btn)
	btn.pressed.connect(func() -> void: start_requested.emit())
	v.add_child(btn)
	_start_btn = btn   # 焦点在入树后授予（见 show_title）

	var tip := _label("点击按钮 或 按 Enter / 空格 开始", UiTheme.FS_XS, UiTheme.C_TEXT_MUTE)
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(tip)
	return card


func _build_result_card() -> PanelContainer:
	var card := PanelContainer.new()
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.custom_minimum_size = Vector2(520, 0)
	card.add_theme_stylebox_override("panel",
			UiTheme.sb(UiTheme.C_SURFACE, 16, UiTheme.C_BORDER_HI, 1, true))

	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", UiTheme.S7)
	m.add_theme_constant_override("margin_right", UiTheme.S7)
	m.add_theme_constant_override("margin_top", UiTheme.S6)
	m.add_theme_constant_override("margin_bottom", UiTheme.S5)
	card.add_child(m)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", UiTheme.S3)
	m.add_child(v)

	_result_title = _label("最后还在转的是你", UiTheme.FS_XL, UiTheme.C_PRIMARY)
	_result_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_result_title)

	_result_sub = _label("第 1 名 · 用时 0.0 s", UiTheme.FS_MD, UiTheme.C_TEXT)
	_result_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_result_sub)

	v.add_child(_divider())

	_result_stats = _label("击败 0 个对手", UiTheme.FS_SM, UiTheme.C_TEXT_DIM)
	_result_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_result_stats)

	var btn := Button.new()
	btn.text = "再来一局"
	btn.custom_minimum_size = Vector2(260, UiTheme.BTN_H)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	UiTheme.style_button_primary(btn)
	btn.pressed.connect(func() -> void: restart_requested.emit())
	v.add_child(btn)
	_restart_btn = btn

	var tip := _label("点击按钮 或 按 R / Enter 再来一局", UiTheme.FS_XS, UiTheme.C_TEXT_MUTE)
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(tip)
	return card


# ── 控件工厂 ──────────────────────────────────────────
func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _divider() -> Control:
	var d := PanelContainer.new()
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.custom_minimum_size = Vector2(0, 2)
	d.add_theme_stylebox_override("panel", UiTheme.sb(UiTheme.C_BORDER, 0))
	return d


func _stat_chip(title: String) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", UiTheme.chip_sb(UiTheme.C_SURFACE, UiTheme.C_BORDER))
	var m := MarginContainer.new()
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_theme_constant_override("margin_left", UiTheme.S3)
	m.add_theme_constant_override("margin_right", UiTheme.S3)
	m.add_theme_constant_override("margin_top", 6)
	m.add_theme_constant_override("margin_bottom", 6)
	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", UiTheme.S2)
	var t := _label(title, UiTheme.FS_XS, UiTheme.C_TEXT_DIM)
	var val := _label("—", UiTheme.FS_SM, UiTheme.C_TEXT)
	hb.add_child(t)
	hb.add_child(val)
	m.add_child(hb)
	p.add_child(m)
	p.set_meta("value", val)
	return p


func _chip_value(p: PanelContainer) -> Label:
	return p.get_meta("value") as Label


func _step_chip(text: String) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := MarginContainer.new()
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_theme_constant_override("margin_left", UiTheme.S4)
	m.add_theme_constant_override("margin_right", UiTheme.S4)
	m.add_theme_constant_override("margin_top", 7)
	m.add_theme_constant_override("margin_bottom", 7)
	var l := _label(text, UiTheme.FS_SM, UiTheme.C_TEXT_MUTE)
	m.add_child(l)
	p.add_child(m)
	p.set_meta("label", l)
	_apply_chip(p, text, 2)
	return p


## state：0 = 已完成 / 1 = 进行中 / 2 = 待办
func _apply_chip(p: PanelContainer, text: String, state: int) -> void:
	var l := p.get_meta("label") as Label
	match state:
		0:
			p.add_theme_stylebox_override("panel",
					UiTheme.chip_sb(UiTheme.tinted(UiTheme.C_PRIMARY, 0.16), UiTheme.C_PRIMARY))
			l.add_theme_color_override("font_color", UiTheme.C_PRIMARY)
			l.text = "✓ " + text
		1:
			p.add_theme_stylebox_override("panel",
					UiTheme.chip_sb(UiTheme.tinted(UiTheme.C_GOLD, 0.18), UiTheme.C_GOLD))
			l.add_theme_color_override("font_color", UiTheme.C_GOLD)
			l.text = text
		_:
			p.add_theme_stylebox_override("panel",
					UiTheme.chip_sb(UiTheme.C_SURFACE_2, UiTheme.C_BORDER))
			l.add_theme_color_override("font_color", UiTheme.C_TEXT_MUTE)
			l.text = text


# ── 对外 API（由 TopsMain 驱动）────────────────────────
func show_title() -> void:
	_title_wrap.show()
	_result_wrap.hide()
	_top_bar.hide()
	_bottom_dock.hide()
	if _start_btn != null and _start_btn.is_inside_tree():
		_start_btn.grab_focus()   # 键盘可达：Enter / 空格 直接开


func show_launch() -> void:
	_title_wrap.hide()
	_result_wrap.hide()
	_top_bar.show()
	_bottom_dock.show()
	_power_box.show()
	set_step(1)


func show_battle() -> void:
	_title_wrap.hide()
	_result_wrap.hide()
	_top_bar.show()
	_bottom_dock.show()
	_power_box.hide()
	set_step(3)


func show_result(won: bool, place: int, seconds: float, kills: int) -> void:
	_title_wrap.hide()
	_result_wrap.show()
	_top_bar.hide()
	_bottom_dock.hide()
	_result_title.text = "最后还在转的是你" if won else "你的陀螺停了"
	_result_title.add_theme_color_override("font_color",
			UiTheme.C_PRIMARY if won else UiTheme.C_DANGER)
	_result_sub.text = "第 %d 名 · 用时 %.1f s" % [1 if won else place, seconds]
	_result_stats.text = "击败 %d 个对手" % kills
	if _restart_btn != null and _restart_btn.is_inside_tree():
		_restart_btn.grab_focus()


func is_title_shown() -> bool:
	return _title_wrap.visible


func is_result_shown() -> bool:
	return _result_wrap.visible


## 当前进行到第几步（0 开始游戏 / 1 蓄力 / 2 放陀螺 / 3 全部完成）
func set_step(i: int) -> void:
	if i == _step_cur:
		return
	_step_cur = i
	for idx in _steps.size():
		var state: int = 0 if idx < i else (1 if idx == i else 2)
		_apply_chip(_steps[idx], STEP_TITLES[idx], state)


func set_stats(alive: int, total: int, seconds: float, shrinking: bool) -> void:
	_chip_value(_chip_alive).text = "%d / %d" % [alive, total]
	_chip_value(_chip_time).text = "%.1f s" % seconds
	var field := _chip_value(_chip_field)
	if shrinking:
		field.text = "收缩中"
		field.add_theme_color_override("font_color", UiTheme.C_DANGER)
		_chip_field.add_theme_stylebox_override("panel",
				UiTheme.chip_sb(UiTheme.tinted(UiTheme.C_DANGER, 0.16), UiTheme.C_DANGER))
	else:
		field.text = "稳定"
		field.add_theme_color_override("font_color", UiTheme.C_TEXT)
		_chip_field.add_theme_stylebox_override("panel",
				UiTheme.chip_sb(UiTheme.C_SURFACE, UiTheme.C_BORDER))


func set_spin(spin: float, spin_max: float) -> void:
	var ratio: float = clampf(spin / maxf(spin_max, 1.0), 0.0, 1.0)
	_spin_gauge.set_value(ratio)
	_spin_gauge.set_fill(TopsArt.spin_color(ratio))
	_spin_value.text = "%d / %d" % [int(maxf(spin, 0.0)), int(spin_max)]


func set_power(p: float, charging: bool, perfect: bool) -> void:
	_power_gauge.set_value(p)
	_power_gauge.set_fill(UiTheme.C_GOLD if perfect else UiTheme.C_PRIMARY)
	_power_value.text = "%d%%" % int(roundf(p * 100.0))
	_power_tag.text = "完美区间" if perfect else ("蓄力中" if charging else "")
	_power_tag.add_theme_color_override("font_color",
			UiTheme.C_GOLD if perfect else UiTheme.C_TEXT_DIM)


func set_hint(text: String) -> void:
	if _hint.text != text:
		_hint.text = text


## 屏幕中上的瞬时横幅（放陀螺！/ 你的陀螺倒了 / 完美发射！）
func toast(text: String, color: Color = UiTheme.C_GOLD, hold := 0.9) -> void:
	_toast.text = text
	_toast.add_theme_color_override("font_color", color)
	_toast.show()
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_property(_toast, "modulate:a", 1.0, 0.10)
	_toast_tween.tween_interval(hold)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.45)
	_toast_tween.tween_callback(_toast.hide)
