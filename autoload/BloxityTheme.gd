extends Node
## BloxityTheme — runtime Theme builder for the Bloxity design system.
##
## Builds a Godot Theme resource programmatically so we don't depend on
## a pre-baked .tres that would go stale any time the palette changes.
## Drop Fredoka-Regular.ttf (and optionally Fredoka-SemiBold.ttf) into
## res://assets/fonts/ and this singleton will pick them up automatically.
##
## Usage:
##   var t := BloxityTheme.get_theme(BloxityTheme.Mode.DARK)
##   some_control.theme = t
##
## Color tokens are also exposed as static constants so UI scripts can
## reference them directly without importing this file.

## ─── Design tokens ────────────────────────────────────────────────────────────

# Light-mode palette
const LIGHT_BG          := Color("#F5F9F8")
const LIGHT_CARD        := Color("#FFFFFF")
const LIGHT_BORDER      := Color("#A7E399")   # mint green
const LIGHT_TEXT        := Color("#1A1A2E")
const LIGHT_TEXT_MUTED  := Color("#6B7280")
const LIGHT_PRIMARY     := Color("#48B3AF")   # teal
const LIGHT_PRIMARY_HOV := Color("#3A9E9A")
const LIGHT_PRIMARY_ACT := Color("#2D8B87")

# Dark-mode palette
const DARK_BG           := Color("#12121E")
const DARK_CARD         := Color("#1E1E2E")
const DARK_CARD_RAISED  := Color("#252535")
const DARK_BORDER       := Color("#2E2E3E")
const DARK_TEXT         := Color("#E8E8F0")
const DARK_TEXT_MUTED   := Color("#9090A8")
const DARK_PRIMARY      := Color("#00D2FF")   # bright cyan
const DARK_PRIMARY_HOV  := Color("#00B8E0")
const DARK_PRIMARY_ACT  := Color("#0099BB")

# Shared danger/success
const COLOR_DANGER      := Color("#FF6B6B")
const COLOR_SUCCESS     := Color("#4CAF7D")
const COLOR_WARNING     := Color("#FFB347")

# Corner radii (in pixels)
const RADIUS_SM  := 4
const RADIUS_MD  := 8    # "lg" in web token nomenclature
const RADIUS_LG  := 12   # "xl"
const RADIUS_XL  := 16   # "2xl"
const RADIUS_FULL := 999 # pill

# Font sizes
const FONT_SIZE_XS   := 11
const FONT_SIZE_SM   := 13
const FONT_SIZE_BASE := 15
const FONT_SIZE_LG   := 18
const FONT_SIZE_XL   := 22
const FONT_SIZE_2XL  := 28

enum Mode { LIGHT, DARK }

## ─── Internals ────────────────────────────────────────────────────────────────

var _themes: Dictionary = {}   # Mode -> Theme
var _font_regular: FontFile = null
var _font_semibold: FontFile = null

func _ready() -> void:
	_load_fonts()
	# Pre-build both themes eagerly so the first call to get_theme() is instant.
	_themes[Mode.LIGHT] = _build_theme(Mode.LIGHT)
	_themes[Mode.DARK]  = _build_theme(Mode.DARK)


## Returns the cached Theme for the requested mode. Always valid — falls
## back gracefully if fonts were not found.
func get_theme(mode: Mode = Mode.DARK) -> Theme:
	if not _themes.has(mode):
		_themes[mode] = _build_theme(mode)
	return _themes[mode]


## Returns font_regular (may be null if Fredoka TTF not imported yet).
func get_font_regular() -> FontFile:
	return _font_regular


## Returns font_semibold (falls back to regular if SemiBold not found).
func get_font_semibold() -> FontFile:
	return _font_semibold if _font_semibold != null else _font_regular


## ─── Font loading ─────────────────────────────────────────────────────────────

func _load_fonts() -> void:
	const REGULAR_PATH  := "res://assets/fonts/Fredoka-Regular.ttf"
	const SEMIBOLD_PATH := "res://assets/fonts/Fredoka-SemiBold.ttf"

	if ResourceLoader.exists(REGULAR_PATH):
		_font_regular = load(REGULAR_PATH) as FontFile
	else:
		push_warning("[BloxityTheme] Fredoka-Regular.ttf not found at %s — UI will use Godot's default font. Drop the TTF there to enable Fredoka." % REGULAR_PATH)

	if ResourceLoader.exists(SEMIBOLD_PATH):
		_font_semibold = load(SEMIBOLD_PATH) as FontFile


## ─── Theme builder ────────────────────────────────────────────────────────────

func _build_theme(mode: Mode) -> Theme:
	var t := Theme.new()
	var is_dark := (mode == Mode.DARK)

	var bg_col        := DARK_BG          if is_dark else LIGHT_BG
	var card_col      := DARK_CARD        if is_dark else LIGHT_CARD
	var raised_col    := DARK_CARD_RAISED if is_dark else Color("#F0F5F4")
	var border_col    := DARK_BORDER      if is_dark else LIGHT_BORDER
	var text_col      := DARK_TEXT        if is_dark else LIGHT_TEXT
	var muted_col     := DARK_TEXT_MUTED  if is_dark else LIGHT_TEXT_MUTED
	var primary_col   := DARK_PRIMARY     if is_dark else LIGHT_PRIMARY
	var primary_hov   := DARK_PRIMARY_HOV if is_dark else LIGHT_PRIMARY_HOV
	var primary_act   := DARK_PRIMARY_ACT if is_dark else LIGHT_PRIMARY_ACT

	# ── StyleBoxes ────────────────────────────────────────────────────────────

	# Panel / card body
	var sb_panel := _make_flat(card_col, border_col, RADIUS_LG, 1)
	# Raised card (slightly elevated row)
	var sb_raised := _make_flat(raised_col, border_col, RADIUS_MD, 1)
	# Transparent / no-border inner container
	var sb_transparent := StyleBoxEmpty.new()
	# Overlay backdrop (semi-opaque bg)
	var sb_overlay := _make_flat(
		Color(bg_col.r, bg_col.g, bg_col.b, 0.97), border_col, RADIUS_XL, 1
	)

	# Button — normal
	var sb_btn_normal := _make_flat(primary_col, Color(0, 0, 0, 0), RADIUS_MD, 0)
	sb_btn_normal.content_margin_left   = 16
	sb_btn_normal.content_margin_right  = 16
	sb_btn_normal.content_margin_top    = 8
	sb_btn_normal.content_margin_bottom = 8
	# Button — hover
	var sb_btn_hover := _make_flat(primary_hov, Color(0, 0, 0, 0), RADIUS_MD, 0)
	sb_btn_hover.content_margin_left   = 16
	sb_btn_hover.content_margin_right  = 16
	sb_btn_hover.content_margin_top    = 8
	sb_btn_hover.content_margin_bottom = 8
	# Button — pressed
	var sb_btn_pressed := _make_flat(primary_act, Color(0, 0, 0, 0), RADIUS_MD, 0)
	sb_btn_pressed.content_margin_left   = 16
	sb_btn_pressed.content_margin_right  = 16
	sb_btn_pressed.content_margin_top    = 8
	sb_btn_pressed.content_margin_bottom = 8
	# Button — disabled
	var sb_btn_disabled := _make_flat(
		Color(primary_col.r, primary_col.g, primary_col.b, 0.35),
		Color(0, 0, 0, 0), RADIUS_MD, 0
	)
	sb_btn_disabled.content_margin_left   = 16
	sb_btn_disabled.content_margin_right  = 16
	sb_btn_disabled.content_margin_top    = 8
	sb_btn_disabled.content_margin_bottom = 8

	# Ghost / secondary button
	var sb_ghost_normal := _make_flat(Color(0, 0, 0, 0), border_col, RADIUS_MD, 1)
	sb_ghost_normal.content_margin_left   = 14
	sb_ghost_normal.content_margin_right  = 14
	sb_ghost_normal.content_margin_top    = 6
	sb_ghost_normal.content_margin_bottom = 6
	var sb_ghost_hover := _make_flat(
		Color(primary_col.r, primary_col.g, primary_col.b, 0.12),
		primary_col, RADIUS_MD, 1
	)
	sb_ghost_hover.content_margin_left   = 14
	sb_ghost_hover.content_margin_right  = 14
	sb_ghost_hover.content_margin_top    = 6
	sb_ghost_hover.content_margin_bottom = 6

	# LineEdit / input field
	var sb_input_normal := _make_flat(raised_col, border_col, RADIUS_MD, 1)
	sb_input_normal.content_margin_left   = 12
	sb_input_normal.content_margin_right  = 12
	sb_input_normal.content_margin_top    = 8
	sb_input_normal.content_margin_bottom = 8
	var sb_input_focus := _make_flat(raised_col, primary_col, RADIUS_MD, 2)
	sb_input_focus.content_margin_left   = 12
	sb_input_focus.content_margin_right  = 12
	sb_input_focus.content_margin_top    = 8
	sb_input_focus.content_margin_bottom = 8

	# Scrollbar track
	var sb_scroll_track := _make_flat(
		Color(raised_col.r, raised_col.g, raised_col.b, 0.4),
		Color(0, 0, 0, 0), RADIUS_FULL, 0
	)
	# Scrollbar grabber
	var sb_scroll_grab := _make_flat(border_col, Color(0, 0, 0, 0), RADIUS_FULL, 0)
	var sb_scroll_grab_hover := _make_flat(primary_col, Color(0, 0, 0, 0), RADIUS_FULL, 0)

	# ── Apply to theme types ──────────────────────────────────────────────────

	# Panel
	t.set_stylebox("panel", "Panel", sb_panel)

	# PanelContainer
	t.set_stylebox("panel", "PanelContainer", sb_panel)

	# Button (primary)
	t.set_stylebox("normal",   "Button", sb_btn_normal)
	t.set_stylebox("hover",    "Button", sb_btn_hover)
	t.set_stylebox("pressed",  "Button", sb_btn_pressed)
	t.set_stylebox("disabled", "Button", sb_btn_disabled)
	t.set_stylebox("focus",    "Button", sb_transparent)
	t.set_color("font_color",          "Button", Color("#FFFFFF"))
	t.set_color("font_hover_color",    "Button", Color("#FFFFFF"))
	t.set_color("font_pressed_color",  "Button", Color("#FFFFFF"))
	t.set_color("font_disabled_color", "Button", Color(1, 1, 1, 0.4))
	t.set_font_size("font_size", "Button", FONT_SIZE_BASE)
	if _font_semibold:
		t.set_font("font", "Button", _font_semibold)

	# Label
	t.set_color("font_color",        "Label", text_col)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0))
	t.set_font_size("font_size", "Label", FONT_SIZE_BASE)
	if _font_regular:
		t.set_font("font", "Label", _font_regular)

	# RichTextLabel
	t.set_color("default_color", "RichTextLabel", text_col)
	t.set_font_size("normal_font_size", "RichTextLabel", FONT_SIZE_BASE)
	if _font_regular:
		t.set_font("normal_font", "RichTextLabel", _font_regular)
	t.set_stylebox("normal", "RichTextLabel", sb_transparent)

	# LineEdit
	t.set_stylebox("normal",   "LineEdit", sb_input_normal)
	t.set_stylebox("focus",    "LineEdit", sb_input_focus)
	t.set_stylebox("read_only","LineEdit", sb_input_normal)
	t.set_color("font_color",            "LineEdit", text_col)
	t.set_color("font_placeholder_color","LineEdit", muted_col)
	t.set_color("caret_color",           "LineEdit", primary_col)
	t.set_color("selection_color",       "LineEdit", Color(primary_col.r, primary_col.g, primary_col.b, 0.3))
	t.set_font_size("font_size", "LineEdit", FONT_SIZE_BASE)
	if _font_regular:
		t.set_font("font", "LineEdit", _font_regular)

	# ScrollContainer / VScrollBar / HScrollBar
	t.set_stylebox("panel", "ScrollContainer", sb_transparent)
	t.set_stylebox("scroll",       "VScrollBar", sb_scroll_track)
	t.set_stylebox("grabber",      "VScrollBar", sb_scroll_grab)
	t.set_stylebox("grabber_highlight", "VScrollBar", sb_scroll_grab_hover)
	t.set_stylebox("grabber_pressed",   "VScrollBar", sb_scroll_grab_hover)
	t.set_constant("width", "VScrollBar", 6)

	# Separator
	var sb_sep := StyleBoxLine.new()
	sb_sep.color = border_col
	sb_sep.thickness = 1
	t.set_stylebox("separator", "HSeparator", sb_sep)
	t.set_stylebox("separator", "VSeparator", sb_sep)
	t.set_constant("separation", "HSeparator", 8)

	# CheckBox / OptionButton — minimal theming, uses primary accent
	t.set_color("font_color",       "OptionButton", text_col)
	t.set_color("font_hover_color", "OptionButton", text_col)
	t.set_stylebox("normal",   "OptionButton", sb_input_normal)
	t.set_stylebox("hover",    "OptionButton", sb_input_focus)
	t.set_stylebox("pressed",  "OptionButton", sb_input_focus)
	t.set_stylebox("focus",    "OptionButton", sb_transparent)
	t.set_font_size("font_size", "OptionButton", FONT_SIZE_BASE)
	if _font_regular:
		t.set_font("font", "OptionButton", _font_regular)

	# Slider (for Settings volume etc.)
	var sb_slider_bg := _make_flat(raised_col, border_col, RADIUS_FULL, 1)
	var sb_slider_fill := _make_flat(primary_col, Color(0,0,0,0), RADIUS_FULL, 0)
	var sb_slider_grab := _make_flat(primary_col, Color(0,0,0,0), RADIUS_FULL, 0)
	t.set_stylebox("slider",    "HSlider", sb_slider_bg)
	t.set_stylebox("grabber_area", "HSlider", sb_slider_fill)
	t.set_icon("grabber", "HSlider", _make_circle_icon(primary_col, 14))
	t.set_icon("grabber_highlight", "HSlider", _make_circle_icon(primary_hov, 16))
	t.set_constant("center_grabber", "HSlider", 1)

	return t


## ─── Helpers ─────────────────────────────────────────────────────────────────

static func _make_flat(bg: Color, border: Color, radius: int, border_width: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.border_width_left   = border_width
	s.border_width_right  = border_width
	s.border_width_top    = border_width
	s.border_width_bottom = border_width
	s.corner_radius_top_left     = radius
	s.corner_radius_top_right    = radius
	s.corner_radius_bottom_left  = radius
	s.corner_radius_bottom_right = radius
	s.anti_aliasing = true
	return s


## Makes a tiny circular ImageTexture for slider grabbers (avoids needing
## an external icon asset for a single 14px dot).
static func _make_circle_icon(color: Color, size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(size * 0.5, size * 0.5)
	var r := size * 0.5
	for y in size:
		for x in size:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(center)
			var alpha := clampf(r - d + 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(color.r, color.g, color.b, alpha))
	return ImageTexture.create_from_image(img)
