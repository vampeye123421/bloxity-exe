extends Node3D

## Renders a comic-style speech bubble (white rounded rect + downward tail)
## above a player's head. A Label3D can't draw a background shape, so this
## draws the bubble as 2D UI (Label with a rounded StyleBox + a Polygon2D
## tail) inside a SubViewport, then projects that texture onto a billboarded
## Sprite3D. The viewport is resized to fit each message so the bubble hugs
## the text instead of showing a fixed-size box.

const MAX_WIDTH := 260.0
const TAIL_WIDTH := 22.0
const TAIL_HEIGHT := 16.0
const TAIL_OVERLAP := 4.0 # pixels the tail pokes up into the box so the seam doesn't show
const PIXEL_SIZE := 0.0032 # world units per viewport pixel -- tune bubble's on-screen size here
const BG_COLOR := Color(1, 1, 1, 0.97)
const FONT_COLOR := Color(0.11, 0.11, 0.13, 1)

@onready var _viewport: SubViewport = $Viewport
@onready var _label: Label = $Viewport/Root/Text
@onready var _tail: Polygon2D = $Viewport/Root/Tail
@onready var _sprite: Sprite3D = $Sprite


func _ready() -> void:
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	var box := StyleBoxFlat.new()
	box.bg_color = BG_COLOR
	box.corner_radius_top_left = 14
	box.corner_radius_top_right = 14
	box.corner_radius_bottom_left = 14
	box.corner_radius_bottom_right = 14
	box.content_margin_left = 16
	box.content_margin_right = 16
	box.content_margin_top = 10
	box.content_margin_bottom = 10
	box.shadow_color = Color(0, 0, 0, 0.18)
	box.shadow_size = 6
	_label.add_theme_stylebox_override("normal", box)
	_label.add_theme_color_override("font_color", FONT_COLOR)
	_label.add_theme_font_size_override("font_size", 27)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	_tail.color = BG_COLOR
	_tail.polygon = PackedVector2Array([
		Vector2(0, 0),
		Vector2(TAIL_WIDTH, 0),
		Vector2(TAIL_WIDTH * 0.5, TAIL_HEIGHT),
	])

	var vp_tex := ViewportTexture.new()
	vp_tex.viewport_path = _sprite.get_path_to(_viewport)
	_sprite.texture = vp_tex
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.pixel_size = PIXEL_SIZE
	_sprite.transparent = true
	_sprite.no_depth_test = true
	_sprite.centered = true

## Lays out the bubble for `text` and resizes the viewport/sprite so the
## bubble hugs the message instead of showing a fixed-size box. Call
## show_chat_bubble/hide_chat_bubble (below) to control visibility + timing.
func set_message(text: String) -> void:
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.custom_minimum_size = Vector2.ZERO
	_label.size = Vector2.ZERO
	_label.text = text
	_label.reset_size()

	var natural_width: float = _label.get_minimum_size().x
	if natural_width > MAX_WIDTH:
		_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_label.custom_minimum_size.x = MAX_WIDTH
	else:
		_label.custom_minimum_size.x = natural_width
	_label.reset_size()

	# Autowrap needs a layout pass before get_minimum_size() reflects the
	# wrapped height, so defer the final sizing to the next frame.
	await get_tree().process_frame
	_finish_layout()


func _finish_layout() -> void:
	var min_size: Vector2 = _label.get_combined_minimum_size()
	var box_w: float = max(min_size.x, TAIL_WIDTH + 24.0)
	var box_h: float = min_size.y

	_label.position = Vector2.ZERO
	_label.size = Vector2(box_w, box_h)

	_tail.position = Vector2(box_w * 0.5 - TAIL_WIDTH * 0.5, box_h - TAIL_OVERLAP)

	var total_h := box_h - TAIL_OVERLAP + TAIL_HEIGHT
	_viewport.size = Vector2i(ceili(box_w), ceili(total_h))

	# Sprite3D offset (in viewport pixels, pre-pixel_size scaling) so the
	# tail tip -- not the texture's geometric center -- sits at this node's
	# local origin, matching where the old Label3D's baseline used to sit.
	_sprite.offset = Vector2(0, -total_h * 0.5)


func show_chat_bubble(text: String) -> void:
	set_message(text)
	visible = true


func hide_chat_bubble() -> void:
	visible = false
