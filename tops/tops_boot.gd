extends SceneTree
##
## 陀螺对战 · 独立启动入口（真 3D 项目）。
##
## 用法（带窗口）：
##   "Godot_..._win64.exe" --path "D:/Tops3D" --script res://tops/tops_boot.gd
##
## 也可以直接在编辑器里打开 res://tops/tops_main.tscn 按 F6 单独跑。
##

func _initialize() -> void:
	await process_frame
	var scene := load("res://tops/tops_main.tscn")
	if scene == null:
		push_error("tops_boot: 无法加载 tops_main.tscn")
		quit(1)
		return
	root.add_child(scene.instantiate())
