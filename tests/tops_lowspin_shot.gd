extends SceneTree
##
## 低转速旋转状态 · 实机截图（真窗口渲染，**不要**加 --headless）。
##
## 两张图：
##   ① docs/tops_lowspin_states.png  —— 一排四颗，转速 100 / 22 / 12 / 5，
##      看摆角随转速一路长起来（前两颗基本直立，后两颗明显歪着）
##   ② docs/tops_lowspin_wobble.png  —— 同一颗（5 点转速）的四连拍 2×2，
##      四格差不多走完一个进动整圈，看「倾斜方位在绕圈」
##
## 跑法：
##   "Godot_..._win64.exe" --path "D:/Tops3D" --script res://tests/tops_lowspin_shot.gd
##

const WARMUP_FRAMES := 8
const GAP := 15          # 四连拍间隔（帧）≈ 0.25 s，四格走完一个进动整圈

var _world: Node3D
var _cam: Camera3D


func _initialize() -> void:
	await process_frame
	# ⚠ 必须 await：这两个函数里有 await process_frame，不等它就一路跑到 quit() 了
	await _states_shot()
	await _wobble_shot()
	print("[LOWSHOT] done")
	quit(0)


# ── ① 一排四颗：不同转速的摆角对比 ──
func _states_shot() -> void:
	_build_world(Vector3(0.0, 90.0, 220.0), Vector3(-22.0, 0.0, 0.0), 32.0)
	var spins: Array[float] = [100.0, 12.0, 7.0, 4.0]
	var xs: Array[float] = [-42.0, -14.0, 14.0, 42.0]
	for i in spins.size():
		var t := _make_top(&"BALANCED", i + 1, Vector2(xs[i], 0.0), spins[i])
		t._precess_phase = float(i) * TAU / 4.0   # 四颗的倾倒方位错开，别整整齐齐
	for _i in WARMUP_FRAMES:
		await process_frame
	_save(root.get_texture().get_image(), "tops_lowspin_states.png")
	_clear_world()


# ── ② 同一颗的四连拍：进动绕圈 ──
func _wobble_shot() -> void:
	_build_world(Vector3(0.0, 42.0, 115.0), Vector3(-20.0, 0.0, 0.0), 30.0)
	var t := _make_top(&"BALANCED", 1, Vector2(0.0, 0.0), 5.0)
	t._precess_phase = 0.0
	for _i in WARMUP_FRAMES:
		await process_frame

	var sheet := Image.create(1920, 1280, false, Image.FORMAT_RGBA8)
	for i in 4:
		var img: Image = root.get_texture().get_image()
		sheet.blit_rect(img, Rect2i(0, 0, img.get_width(), img.get_height()),
				Vector2i((i % 2) * img.get_width(), (i / 2) * img.get_height()))
		print("   第 %d 格: 摆角 %.1f°  进动方位 %.0f°"
				% [i + 1, rad_to_deg(_axis_tilt(t)), rad_to_deg(_azimuth(t))])
		for _k in GAP:
			await process_frame
	_save(sheet, "tops_lowspin_wobble.png")
	_clear_world()


# ── 场景搭建（照抄 tops_main 的环境/灯光/碗体，只为看姿态）──
func _build_world(cam_pos: Vector3, cam_rot_deg: Vector3, fov: float) -> void:
	_world = Node3D.new()
	root.add_child(_world)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#0E1117")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#2A3140")
	env.ambient_light_energy = 0.6
	we.environment = env
	_world.add_child(we)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0, -30.0, 0.0)
	light.light_energy = 1.05
	light.shadow_enabled = false   # gl_compatibility 下阴影会在地面采出暗斑
	_world.add_child(light)

	# 碗体：单位碗（平底半径 = 1.0），按 main 的规矩缩放。
	# 硬边界要跟随主场景常量，别用 TopsArena.BASE_BOUND 的静态默认值——
	# 场地改成 150 之后那是过期的 270，截图里的碗会和游戏里对不上。
	var bound := TopsMain.BASE_RADIUS + TopsRules.WALL_INNER_OFFSET
	var bowl := TopsArena.build(bound)
	bowl.scale = Vector3(bound, 1.0, bound)
	_world.add_child(bowl)

	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	_cam.fov = fov
	_cam.position = cam_pos
	_cam.rotation_degrees = cam_rot_deg
	_world.add_child(_cam)


func _make_top(arch: StringName, p_id: int, pos: Vector2, spin: float) -> TopTop:
	var t := TopTop.create(arch, p_id)
	t.model = TopsModel.build(t)
	t.add_child(t.model)
	t.freeze = true            # 只看姿态，不让它漂移/互撞
	t.set_collides(false)
	t.spin = spin
	t.spin_max = 100.0
	_world.add_child(t)        # 先入树：set_plane_pos 要读 global_position
	t.set_plane_pos(pos)
	return t


func _clear_world() -> void:
	if _world != null and is_instance_valid(_world):
		_world.free()
		_world = null
	_cam = null


func _save(img: Image, file_name: String) -> void:
	var path := ProjectSettings.globalize_path("res://docs/" + file_name)
	var err := img.save_png(path)
	print("[LOWSHOT] ", path, " -> ", error_string(err))


func _axis_tilt(t: TopTop) -> float:
	var up: Vector3 = t.model.global_transform.basis.y.normalized()
	return acos(clampf(up.dot(Vector3.UP), -1.0, 1.0))


func _azimuth(t: TopTop) -> float:
	var up: Vector3 = t.model.global_transform.basis.y.normalized()
	return Vector2(up.x, up.z).angle()
