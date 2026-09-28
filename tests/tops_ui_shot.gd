extends SceneTree
##
## 陀螺对战 · UI 实机截图（真窗口渲染，验证界面观感）
##
## 跑法（**不要**加 --headless，需要真实渲染）：
##   "Godot_..._win64.exe" --path "D:/Tops3D" --script res://tests/tops_ui_shot.gd
##
## 产物：docs/ui_01_title.png（开始界面）· ui_02_charge.png（蓄力）
##       ui_03_battle.png（战斗 HUD）· ui_05_roster.png（对战中的转速表）
##       ui_04_result.png（结算）
##

const WARMUP_FRAMES := 6


func _initialize() -> void:
	await process_frame
	var scene := load("res://tops/tops_main.tscn")
	var main: TopsMain = scene.instantiate()
	root.add_child(main)
	for _i in WARMUP_FRAMES:
		await process_frame

	_shot("ui_01_title.png")

	# ① 开始游戏 → ② 蓄力（按 physics 帧等待：高帧率下 process 帧可能不含物理 tick）
	# 注意：start_game 后输入锁要求「开始那一下的按键」先松开，故先空跑几帧再蓄力
	main.start_game()
	for _i in 3:
		await physics_frame
	Input.action_press("tops_boost")
	for _i in 26:
		await physics_frame
	_shot("ui_02_charge.png")

	# ③ 放陀螺 → 战斗 HUD
	Input.action_release("tops_boost")
	for _i in 30:
		await physics_frame
	_shot("ui_03_battle.png")

	# 对战中 → 转速表（各行 rpm 已经拉开，可能有出局的被压暗）
	# ⚠ time_scale=16 下每物理帧推进 16×dt，一局 ~50 s 只要 ~190 帧，帧数写死会跑过头
	Engine.time_scale = 16.0
	var guard := 0
	while guard < 9600 and main._elapsed < 22.0 and main._phase != TopsMain.Phase.RESULT:
		await physics_frame
		guard += 1
	Engine.time_scale = 1.0
	await process_frame
	print("[UISHOT] roster shot at elapsed = ", "%.1f" % main._elapsed, " s, phase = ", main._phase)
	_shot("ui_05_roster.png")

	# 加速跑到分出胜负 → 结算
	Engine.time_scale = 16.0
	var guard2 := 0
	while guard2 < 9600 and main._phase != TopsMain.Phase.RESULT:
		await physics_frame
		guard2 += 1
	Engine.time_scale = 1.0
	await physics_frame
	await physics_frame
	_shot("ui_04_result.png")
	print("[UISHOT] done, phase = ", main._phase)
	quit(0)


func _shot(file_name: String) -> void:
	var img := root.get_texture().get_image()
	var path := ProjectSettings.globalize_path("res://docs/" + file_name)
	var err := img.save_png(path)
	print("[UISHOT] ", path, " -> ", error_string(err))
