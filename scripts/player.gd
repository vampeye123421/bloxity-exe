extends CharacterBody3D

# ---- Tunable values ----
# SPEED/JUMP_VELOCITY are the built-in fallbacks. Actual runtime values live
# in _speed / _jump_velocity below, applied from GameSettingsManager (the
# world's authored "starter character" physics) at _ready() -- see
# _apply_game_settings(). A world with no game_settings.json (older packs,
# local test scenes) just keeps these defaults.
const SPEED = 5.0
const JUMP_VELOCITY = 4.5
const DEFAULT_MOUSE_SENSITIVITY = 0.003
const NETWORK_SEND_RATE = 0.05 # seconds between position updates sent to other players

# Third-person camera framing -- only used when GameSettingsManager says
# camera_mode == "third_person". Kept as consts rather than authored
# fields for now: Studio's Game Settings panel only exposes first/third
# person as a mode choice, not a custom rig.
const THIRD_PERSON_CAMERA_OFFSET := Vector3(0, 1.6, 3.2)
const THIRD_PERSON_CAMERA_PITCH_DEG := -12.0

# Remote-capsule smoothing: updates arrive at ~20Hz (NETWORK_SEND_RATE) but we
# render every frame, so a remote player's capsule chases a target position
# instead of snapping to it. Frame-rate independent exponential smoothing --
# NOT a plain lerp(pos, target, k*delta), which drifts with framerate (see
# https://www.rorydriscoll.com/2016/03/07/frame-rate-independent-damping-using-lerp/).
# SMOOTHING_RATE is a decay rate, not a 0-1 blend factor: at rate 12, roughly
# 1-exp(-12*delta) of the remaining distance closes each second, i.e. the gap
# to target is ~e^-12 (~99.9994%) closed after 1s. 10-18 reads as responsive
# without visible popping at a 20Hz update rate; lower it if updates get
# sparser (worse connections), raise it if capsules feel laggy/rubber-banded.
const SMOOTHING_RATE = 12.0

@onready var camera: Camera3D = $Camera3D
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _send_timer := 0.0
var _target_position: Vector3
var _target_rotation_y: float
var _has_remote_target := false # avoids popping in from Vector3.ZERO before the first packet arrives

# ---- Runtime physics/camera, overridden by GameSettingsManager ----
var _speed: float = SPEED
var _jump_velocity: float = JUMP_VELOCITY
var _allow_double_jump := false
var _has_double_jumped := false
var _camera_mode := "first_person"
var _mouse_sensitivity := DEFAULT_MOUSE_SENSITIVITY
var _first_person_camera_local_pos: Vector3 # captured before any override, so third-person can be reversed if ever needed


func _ready() -> void:
	_first_person_camera_local_pos = camera.position

	if not is_multiplayer_authority():
		# This capsule belongs to another player over the network —
		# don't let it grab the mouse or take over the screen.
		camera.current = false
		# Seed the smoothing target at the spawn position so _process() has
		# somewhere sane to lerp from/to before the first position packet
		# arrives, instead of chasing a stale Vector3.ZERO.
		_target_position = global_position
		_target_rotation_y = rotation.y
		return

	# Gravity/camera-mode/speed/jump/double-jump authored in Blubox Studio's
	# Game Settings panel, only meaningful for the local player (remote
	# capsules are purely visual, smoothed toward network packets -- see
	# _process() below). Only applies once GameSettingsManager exists (it's
	# an autoload, so always true in the real client, but stays defensive
	# for isolated test scenes).
	_apply_game_settings()
	var settings_view := get_tree().get_first_node_in_group("settings_view")
	if settings_view and settings_view.has_signal("sensitivity_changed"):
		settings_view.sensitivity_changed.connect(_on_sensitivity_changed)
		if settings_view.has_method("get_mouse_sensitivity"):
			_on_sensitivity_changed(float(settings_view.get_mouse_sensitivity()))

	# Locks the mouse to the window and hides the cursor, like a real game.
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	camera.current = true


## Chiamato SOLO da componenti sicuri forniti dal client (es.
## res://scripts/components/kill_brick.gd o teleporter.gd), mai da script
## dei creator (che comunque non possono esistere -- vedi WorldLoader).
## Agisce solo se questo capsule appartiene al giocatore locale: un
## componente in un mondo caricato non deve mai poter spostare l'avatar di
## un ALTRO peer -- ogni client resta autoritativo solo sul proprio
## personaggio, stesso modello del resto del movimento.
func respawn_at(pos: Vector3) -> void:
	if not is_multiplayer_authority():
		return
	global_position = pos
	velocity = Vector3.ZERO


func set_player_name(display_name: String) -> void:
	var label := get_node_or_null("NameLabel") as Label3D
	if label:
		if display_name != "":
			label.text = display_name
		else:
			label.text = "Player"


## Called by ChatManager whenever this player (local or remote) sends a
## chat message, so it floats above whoever actually said it. Re-showing
## while already visible (fast consecutive messages) just restarts the
## hide timer via _chat_bubble_generation, rather than the new timer
## racing an old one and hiding the bubble early.
var _chat_bubble_generation := 0
const CHAT_BUBBLE_DURATION_SEC := 4.0

func show_chat_bubble(text: String) -> void:
	var bubble := get_node_or_null("ChatBubble")
	if bubble == null or text == "" or not bubble.has_method("show_chat_bubble"):
		return
	bubble.show_chat_bubble(text)
	_chat_bubble_generation += 1
	var my_gen := _chat_bubble_generation
	var tree := get_tree()
	if tree == null:
		return
	var timer := tree.create_timer(CHAT_BUBBLE_DURATION_SEC)
	timer.timeout.connect(func():
		if my_gen == _chat_bubble_generation and is_instance_valid(bubble):
			bubble.hide_chat_bubble()
	)


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	# While the chat input box is open, ChatManager owns the mouse mode and
	# keyboard focus -- don't fight it with mouselook/re-capture here.
	if ChatManager and ChatManager.is_chat_active():
		return
	# Mouse look — only while the cursor is captured.
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * _mouse_sensitivity)
		camera.rotate_x(-event.relative.y * _mouse_sensitivity)
		camera.rotation.x = clamp(camera.rotation.x, deg_to_rad(-80), deg_to_rad(80))

	# Press Escape to free the mouse (so you can close the window, alt-tab, etc).
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Click back into the window to re-capture the mouse.
	if event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return # remote players are smoothed toward apply_remote_position()'s target in _process(), not physics

	var chat_active := ChatManager != null and ChatManager.is_chat_active()

	# Gravity
	var on_floor := is_on_floor()
	if not on_floor:
		velocity.y -= gravity * delta
	else:
		_has_double_jumped = false # touching ground always refills the double jump

	# Jump -- suppressed while typing so Space doesn't launch you mid-message.
	# Kept as is_key_pressed (not an edge check) to match the original
	# ground-jump behavior exactly; that's safe for the double jump too
	# because _has_double_jumped latches after the first air-jump and
	# only clears again once on_floor is true above.
	if not chat_active and Input.is_key_pressed(KEY_SPACE) and on_floor:
		velocity.y = _jump_velocity
	elif not chat_active and Input.is_key_pressed(KEY_SPACE) and not on_floor and _allow_double_jump and not _has_double_jumped:
		velocity.y = _jump_velocity
		_has_double_jumped = true

	# WASD movement, relative to the direction you're facing. Suppressed
	# while chat is open for the same reason -- typing "sad" shouldn't also
	# walk you into a wall.
	var input_dir := Vector2.ZERO
	if not chat_active:
		if Input.is_key_pressed(KEY_W):
			input_dir.y -= 1
		if Input.is_key_pressed(KEY_S):
			input_dir.y += 1
		if Input.is_key_pressed(KEY_A):
			input_dir.x -= 1
		if Input.is_key_pressed(KEY_D):
			input_dir.x += 1
	input_dir = input_dir.normalized()

	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction.length() > 0.01:
		velocity.x = direction.x * _speed
		velocity.z = direction.z * _speed
	else:
		velocity.x = move_toward(velocity.x, 0, _speed)
		velocity.z = move_toward(velocity.z, 0, _speed)

	move_and_slide()

	if multiplayer.multiplayer_peer != null:
		_send_timer += delta
		if _send_timer >= NETWORK_SEND_RATE:
			_send_timer = 0.0
			NetworkManager.send_raw_position(global_position, rotation.y)
	else:
		# If this ever fires for the local authoritative player, position
		# updates are silently never sent at all -- the multiplayer_peer
		# should be set by NetworkManager._setup_relay_peer() well before
		# any player spawns. Loud once-per-occurrence signal instead of a
		# silent no-op, since remote clients seeing you "frozen" would
		# otherwise have zero diagnostic trail pointing back here.
		if not Engine.has_meta("_warned_no_multiplayer_peer"):
			Engine.set_meta("_warned_no_multiplayer_peer", true)
			push_warning("[Bloxity] player.gd: multiplayer.multiplayer_peer is null on authoritative player -- position updates are NOT being sent")


# Called by JoinClient._apply_remote_position() when a raw "position" relay
# message arrives for this capsule -- this is a plain method call now, NOT
# an @rpc, since position sync bypasses the WebSocketRelayPeer/@rpc pipeline
# entirely (see JoinClient.gd's "relay" handler and
# NetworkManager.send_raw_position()). is_multiplayer_authority() is still
# meaningful here: multiplayer.multiplayer_peer / node authority setup in
# main.gd is untouched, only the position transport changed.
func apply_remote_position(pos: Vector3, rot_y: float) -> void:
	if is_multiplayer_authority():
		return
	# Store the target only -- _process() below does the actual smoothing
	# every rendered frame, decoupled from the ~20Hz rate these packets
	# arrive at. Setting global_position directly here is what caused the
	# teleport-to-each-update choppiness.
	_target_position = pos
	_target_rotation_y = rot_y
	_has_remote_target = true


# Smooths this remote capsule toward the latest position/rotation reported
# by apply_remote_position(). Lives in _process (every rendered frame), not
# _physics_process (fixed 60Hz tick) -- this is purely visual and shouldn't
# be coupled to the physics step. Uses frame-rate independent exponential
# decay (1 - exp(-rate*delta)) rather than a plain lerp(pos, target,
# rate*delta), which would make the capsule glide faster on high-refresh
# displays and slower on low ones for the same SMOOTHING_RATE.
func _process(delta: float) -> void:
	if is_multiplayer_authority() or not _has_remote_target:
		return
	var t := 1.0 - exp(-SMOOTHING_RATE * delta)
	global_position = global_position.lerp(_target_position, t)
	rotation.y = lerp_angle(rotation.y, _target_rotation_y, t)


## Pulls gravity / camera mode / starter-character physics from
## GameSettingsManager (populated by WorldLoader from the current world's
## game_settings.json, see world_loader.gd's _load_game_settings()) and
## applies them to this local player. Called once from _ready(), only for
## the multiplayer-authoritative capsule -- remote capsules never run
## gameplay physics locally, so authored physics wouldn't mean anything
## there anyway.
func _apply_game_settings() -> void:
	var mgr := get_node_or_null("/root/GameSettingsManager")
	if mgr == null:
		return

	gravity = mgr.get_gravity()
	_camera_mode = mgr.get_camera_mode()

	var sc: Dictionary = mgr.get_starter_character()
	_speed = float(sc.get("move_speed", SPEED))
	_jump_velocity = float(sc.get("jump_force", JUMP_VELOCITY))
	_allow_double_jump = bool(sc.get("allow_double_jump", false))
	# NOTE: "mass" from the authored starter-character is intentionally NOT
	# applied here -- CharacterBody3D (what this capsule is) has no mass
	# property; that field only becomes meaningful if/when player physics
	# moves to a RigidBody3D-based controller or the world adds pushable
	# RigidBody3D props for the player to interact with.

	_apply_camera_mode()


func _on_sensitivity_changed(value: float) -> void:
	_mouse_sensitivity = clampf(value, 1.0, 10.0) * DEFAULT_MOUSE_SENSITIVITY / 5.0


## Repositions the camera for the authored mode. First person keeps the
## original eye-level local position baked into Player.tscn; third person
## pulls it back and up behind the capsule. This is a simple child-camera
## offset (no SpringArm3D/collision avoidance yet), so it can clip into
## geometry when backed against a wall -- acceptable for a first pass,
## worth revisiting if third person becomes a heavily-used mode.
func _apply_camera_mode() -> void:
	if _camera_mode == "third_person":
		camera.position = THIRD_PERSON_CAMERA_OFFSET
		camera.rotation = Vector3(deg_to_rad(THIRD_PERSON_CAMERA_PITCH_DEG), 0, 0)
	else:
		camera.position = _first_person_camera_local_pos
		camera.rotation = Vector3.ZERO
