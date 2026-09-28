class_name UiFont
extends RefCounted
##
## UI 字体：用系统字体（SystemFont）渲染中文，避免内置字体缺 CJK 字形。
## 这不是外部美术资源 —— 用的是操作系统自带字体，零文件依赖。
##
## 从《物候》工程 src/ui/ui_font.gd 迁移而来。
##

static var _font: SystemFont = null


static func get_font() -> Font:
	if _font == null:
		_font = SystemFont.new()
	return _font


static func apply(c: Control, size: int = 16) -> void:
	c.add_theme_font_override("font", get_font())
	c.add_theme_font_size_override("font_size", size)


static func make_label(text: String, size: int = 16) -> Label:
	var l := Label.new()
	l.text = text
	apply(l, size)
	return l
