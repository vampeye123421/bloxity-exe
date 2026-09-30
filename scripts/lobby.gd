extends Control
# The client has no "quick join" / "join by code" UI of its own — picking a
# friend or a game happens on the Bloxity website, which launches the client
# with a join token (see launch_handler.gd + network_manager.gd). This
# screen builds its own UI in code (no external art assets) and just
# reflects connection status until the room join finishes, then hands off
# to Main.tscn.

const MAIN_SCENE := "res://scenes/Main.tscn"

const BG_COLOR := Color("15121f")
const ACCENT := Color("c3f53e")
const ACCENT_GLOW := Color(0.76, 0.96, 0.24, 0.16)
const TEXT_MUTED := Color(1, 1, 1, 0.55)
const TEXT_ERROR := Color("ff6b6b")

var _status_label: Label
var _spinner: Control
var _wordmark: Label

# GameJoinClient no longer starts its join attempt on its own -- it waits
# for _start_game_flow() to call start_join() explicitly, after the
# auto-updater (if any) has finished. This guard stays as a safety net:
# if that join already succeeded or failed by the time some other signal
# reaches us, we must NOT stomp the status label back to "Connecting..."
# -- there's nothing left to retry, and doing so would freeze the screen
# on a lie.
var _join_resolved := false


func _ready() -> void:
	_build_ui()

	if get_node_or_null("/root/GameJoinClient"):
		get_node("/root/GameJoinClient").joined_room.connect(_on_joined_room_join_client)
		get_node("/root/GameJoinClient").join_failed.connect(_on_join_failed)

	NetworkManager.connecting.connect(_on_connecting)
	NetworkManager.joined_room.connect(_on_joined_room)
	NetworkManager.join_failed.connect(_on_join_failed)

	if get_node_or_null("/root/AutoUpdater"):
		get_node("/root/AutoUpdater").update_completed.connect(_on_update_completed)
		_set_status("Checking for game updates...", TEXT_MUTED)
		get_node("/root/AutoUpdater").check_for_updates()
	else:
		_start_game_flow()


func _on_update_completed() -> void:
	var version_label = get_node_or_null("VersionLabel")
	if version_label and get_node_or_null("/root/AutoUpdater"):
		version_label.text = "v" + get_node("/root/AutoUpdater").current_version
	_start_game_flow()


func _start_game_flow() -> void:
	if _join_resolved:
		return
	if LaunchHandler.had_token:
		_spinner.set_state(LoadingSpinnerScript.State.SPINNING)
		_set_status("Connecting…", TEXT_MUTED)
		# Only now -- after the updater has fully finished (or was never
		# present) -- do we open the matchmaker socket and spend the
		# single-use join token. Starting this in parallel with a pck
		# download/install let a blocking main thread delay the token past
		# its server-side expiry. See JoinClient.gd:start_join().
		if get_node_or_null("/root/GameJoinClient"):
			get_node("/root/GameJoinClient").start_join()
	else:
		_spinner.set_state(LoadingSpinnerScript.State.SPINNING)
		_set_status("Open https://bloxity-9xk2.onrender.com/ and choose a game or friend to play with.", TEXT_MUTED)


func _on_connecting() -> void:
	_spinner.set_state(LoadingSpinnerScript.State.SPINNING)
	_set_status("Connecting…", TEXT_MUTED)


func _on_joined_room(room_id: String, _world_id: String) -> void:
	_join_resolved = true
	_spinner.set_state(LoadingSpinnerScript.State.SUCCESS)
	_set_status("Joined room: " + room_id, ACCENT)
	await get_tree().create_timer(0.45).timeout
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_joined_room_join_client(_world_id: String, room_id: String, display_name: String) -> void:
	_join_resolved = true
	_spinner.set_state(LoadingSpinnerScript.State.SUCCESS)
	_set_status("Joined as " + display_name + " (" + room_id + ")", ACCENT)
	await get_tree().create_timer(0.45).timeout
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_join_failed(reason: String) -> void:
	_join_resolved = true
	_spinner.set_state(LoadingSpinnerScript.State.ERROR)
	_set_status("Couldn't join: " + reason, TEXT_ERROR)


func _set_status(text: String, color: Color) -> void:
	_status_label.text = text
	_status_label.add_theme_color_override("font_color", color)


const LoadingSpinnerScript = preload("res://scripts/loading_spinner.gd")


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = BG_COLOR
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var glow := TextureRect.new()
	glow.texture = _make_glow_texture()
	glow.custom_minimum_size = Vector2(640, 640)
	glow.size = Vector2(640, 640)
	glow.set_anchors_preset(Control.PRESET_CENTER)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(glow)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.grow_horizontal = Control.GROW_DIRECTION_BOTH
	center.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 28)
	center.add_child(vbox)

	_wordmark = Label.new()
	_wordmark.text = "B L O X I T Y"
	_wordmark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wordmark.add_theme_font_size_override("font_size", 44)
	_wordmark.add_theme_color_override("font_color", Color.WHITE)
	vbox.add_child(_wordmark)

	var underline_wrap := CenterContainer.new()
	var underline := ColorRect.new()
	underline.color = ACCENT
	underline.custom_minimum_size = Vector2(72, 3)
	underline_wrap.add_child(underline)
	vbox.add_child(underline_wrap)

	var spinner_spacer := Control.new()
	spinner_spacer.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(spinner_spacer)

	var spinner_wrap := CenterContainer.new()
	vbox.add_child(spinner_wrap)
	_spinner = LoadingSpinnerScript.new()
	_spinner.spin_color = ACCENT
	_spinner.custom_minimum_size = Vector2(52, 52)
	spinner_wrap.add_child(_spinner)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 16)
	_status_label.add_theme_color_override("font_color", TEXT_MUTED)
	_status_label.custom_minimum_size = Vector2(380, 0)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_status_label)

	# Gentle breathing animation on the wordmark so the screen doesn't feel frozen.
	var tween := create_tween().set_loops()
	tween.tween_property(_wordmark, "modulate:a", 0.65, 1.4).set_trans(Tween.TRANS_SINE)
	tween.tween_property(_wordmark, "modulate:a", 1.0, 1.4).set_trans(Tween.TRANS_SINE)

	# Version Label at Bottom Right
	var version_label := Label.new()
	var ver_str: String = "v1.0.0"
	if get_node_or_null("/root/AutoUpdater"):
		ver_str = "v" + get_node("/root/AutoUpdater").current_version
	version_label.text = ver_str
	version_label.name = "VersionLabel"
	version_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	version_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	version_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	version_label.position = Vector2(-16, -16)
	version_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	version_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	version_label.add_theme_font_size_override("font_size", 13)
	version_label.add_theme_color_override("font_color", Color(0.76, 0.96, 0.24, 0.9))
	add_child(version_label)


func _make_glow_texture() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([ACCENT_GLOW, Color(ACCENT_GLOW.r, ACCENT_GLOW.g, ACCENT_GLOW.b, 0.0)])
	gradient.offsets = PackedFloat32Array([0.0, 1.0])
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 640
	tex.height = 640
	return tex
