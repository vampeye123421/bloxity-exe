extends Control
## SettingsView — client-side preferences panel for the Bloxity menu overlay.
##
## Expected parent path inside MenuOverlay.tscn:
##   MenuPanel/VBox/Content/SettingsView
##
## Persists preferences to Godot's user:// config file so they survive
## restarts. Theme toggling is applied immediately at runtime via
## BloxityTheme and propagated up to the MenuOverlay panel.
##
## Preference back-end: GameSettingsManager.current holds SERVER-authoritative
## world settings (gravity, camera mode, starter character). Client UI
## preferences (volume, mouse sensitivity, theme mode) are SEPARATE concerns
## stored locally in "user://client_prefs.cfg" — this script owns that file.
##
## Sections & controls:
##   [Audio]    Master Volume  (HSlider 0–100, default 80)
##              Music Volume   (HSlider 0–100, default 60)
##              SFX Volume     (HSlider 0–100, default 80)
##   [Video]    Fullscreen     (CheckButton toggle)
##              VSync          (CheckButton toggle)
##   [Controls] Mouse Sensitivity (HSlider 1–10, default 5)
##   [Theme]    Dark / Light   (CheckButton: ON = dark, OFF = light)

# ── Persistence ──────────────────────────────────────────────────────────────

const PREFS_PATH := "user://client_prefs.cfg"

const DEFAULTS := {
	"audio/master_volume":    80,
	"audio/music_volume":     60,
	"audio/sfx_volume":       80,
	"video/fullscreen":       false,
	"video/vsync":            true,
	"controls/mouse_sens":    5,
	"theme/dark_mode":        true,
}

# ── Widget references (built in _build_layout) ───────────────────────────────

var _slider_master:    HSlider
var _slider_music:     HSlider
var _slider_sfx:       HSlider
var _check_fullscreen: CheckButton
var _check_vsync:      CheckButton
var _slider_sens:      HSlider
var _check_dark:       CheckButton

# ── Live config ──────────────────────────────────────────────────────────────

var _cfg := ConfigFile.new()

# ── Signals ───────────────────────────────────────────────────────────────────

## Emitted when mouse sensitivity changes so player.gd can react without polling.
signal sensitivity_changed(value: float)

## Emitted after a theme switch so menu_overlay.gd can re-style itself.
signal theme_mode_changed(dark: bool)


func _ready() -> void:
	add_to_group("settings_view")
	_load_prefs()
	_build_layout()
	_populate_widgets()
	_connect_widget_signals()


# ── Persistence helpers ───────────────────────────────────────────────────────

func _load_prefs() -> void:
	if _cfg.load(PREFS_PATH) != OK:
		_cfg = ConfigFile.new()


func _save_prefs() -> void:
	_cfg.save(PREFS_PATH)


## Read a preference by "section/key" dot-style string.
func _get_pref(key: String) -> Variant:
	var parts := key.split("/")
	if parts.size() != 2:
		return DEFAULTS.get(key)
	return _cfg.get_value(parts[0], parts[1], DEFAULTS.get(key))


## Write a preference and persist immediately.
func _set_pref(key: String, value: Variant) -> void:
	var parts := key.split("/")
	if parts.size() != 2:
		return
	_cfg.set_value(parts[0], parts[1], value)
	_save_prefs()


# ── Layout ────────────────────────────────────────────────────────────────────

func _build_layout() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = SIZE_EXPAND_FILL
	add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.size_flags_horizontal = SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 12)
	scroll.add_child(vbox)

	# ── Audio ──────────────────────────────────────────────────────────────
	vbox.add_child(_section_label("🔊  Audio"))
	_slider_master = _make_slider("Master Volume", 0, 100, vbox)
	_slider_music  = _make_slider("Music Volume",  0, 100, vbox)
	_slider_sfx    = _make_slider("SFX Volume",    0, 100, vbox)
	vbox.add_child(_spacer())

	# ── Video ──────────────────────────────────────────────────────────────
	vbox.add_child(_section_label("🖥  Video"))
	_check_fullscreen = _make_check("Fullscreen",            vbox)
	_check_vsync      = _make_check("Vertical Sync (VSync)", vbox)
	vbox.add_child(_spacer())

	# ── Controls ───────────────────────────────────────────────────────────
	vbox.add_child(_section_label("🖱  Controls"))
	_slider_sens      = _make_slider("Mouse Sensitivity", 1, 10, vbox)
	_slider_sens.step = 0.5
	vbox.add_child(_spacer())

	# ── Theme ──────────────────────────────────────────────────────────────
	vbox.add_child(_section_label("🎨  Theme"))
	_check_dark = _make_check("Dark Mode", vbox)


# ── Populate widgets from saved prefs ─────────────────────────────────────────

func _populate_widgets() -> void:
	_slider_master.value            = float(_get_pref("audio/master_volume"))
	_slider_music.value             = float(_get_pref("audio/music_volume"))
	_slider_sfx.value               = float(_get_pref("audio/sfx_volume"))
	_check_fullscreen.button_pressed = bool(_get_pref("video/fullscreen"))
	_check_vsync.button_pressed      = bool(_get_pref("video/vsync"))
	_slider_sens.value              = float(_get_pref("controls/mouse_sens"))
	_check_dark.button_pressed       = bool(_get_pref("theme/dark_mode"))

	# Apply persisted values on mount so the game state matches last session.
	_apply_master_volume(float(_get_pref("audio/master_volume")))
	_apply_music_volume(float(_get_pref("audio/music_volume")))
	_apply_sfx_volume(float(_get_pref("audio/sfx_volume")))
	_apply_fullscreen(bool(_get_pref("video/fullscreen")))
	_apply_vsync(bool(_get_pref("video/vsync")))
	_apply_theme(bool(_get_pref("theme/dark_mode")))


# ── Signal wiring ─────────────────────────────────────────────────────────────

func _connect_widget_signals() -> void:
	_slider_master.value_changed.connect(_on_master_volume_changed)
	_slider_music.value_changed.connect(_on_music_volume_changed)
	_slider_sfx.value_changed.connect(_on_sfx_volume_changed)
	_check_fullscreen.toggled.connect(_on_fullscreen_toggled)
	_check_vsync.toggled.connect(_on_vsync_toggled)
	_slider_sens.value_changed.connect(_on_mouse_sens_changed)
	_check_dark.toggled.connect(_on_dark_mode_toggled)


# ── Change handlers ───────────────────────────────────────────────────────────

func _on_master_volume_changed(value: float) -> void:
	_set_pref("audio/master_volume", int(value))
	_apply_master_volume(value)


func _on_music_volume_changed(value: float) -> void:
	_set_pref("audio/music_volume", int(value))
	_apply_music_volume(value)


func _on_sfx_volume_changed(value: float) -> void:
	_set_pref("audio/sfx_volume", int(value))
	_apply_sfx_volume(value)


func _on_fullscreen_toggled(pressed: bool) -> void:
	_set_pref("video/fullscreen", pressed)
	_apply_fullscreen(pressed)


func _on_vsync_toggled(pressed: bool) -> void:
	_set_pref("video/vsync", pressed)
	_apply_vsync(pressed)


func _on_mouse_sens_changed(value: float) -> void:
	_set_pref("controls/mouse_sens", value)
	sensitivity_changed.emit(value)


func _on_dark_mode_toggled(pressed: bool) -> void:
	_set_pref("theme/dark_mode", pressed)
	_apply_theme(pressed)


# ── Engine apply helpers ──────────────────────────────────────────────────────

func _apply_master_volume(value: float) -> void:
	var db := linear_to_db(clampf(value / 100.0, 0.0001, 1.0))
	var bus_idx := AudioServer.get_bus_index("Master")
	if bus_idx >= 0:
		AudioServer.set_bus_volume_db(bus_idx, db)


func _apply_music_volume(value: float) -> void:
	var db := linear_to_db(clampf(value / 100.0, 0.0001, 1.0))
	var bus_idx := AudioServer.get_bus_index("Music")
	if bus_idx >= 0:
		AudioServer.set_bus_volume_db(bus_idx, db)


func _apply_sfx_volume(value: float) -> void:
	var db := linear_to_db(clampf(value / 100.0, 0.0001, 1.0))
	var bus_idx := AudioServer.get_bus_index("SFX")
	if bus_idx >= 0:
		AudioServer.set_bus_volume_db(bus_idx, db)


func _apply_fullscreen(enabled: bool) -> void:
	if enabled:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


func _apply_vsync(enabled: bool) -> void:
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if enabled else DisplayServer.VSYNC_DISABLED
	)


func _apply_theme(dark: bool) -> void:
	if not get_node_or_null("/root/BloxityTheme"):
		return
	var mode := BloxityTheme.Mode.DARK if dark else BloxityTheme.Mode.LIGHT
	var new_theme := BloxityTheme.get_theme(mode)

	# SettingsView is at:  MenuPanel/VBox/Content/SettingsView
	# MenuPanel is 3 levels up via Content → VBox → MenuPanel.
	var menu_panel: Node = get_node_or_null("../../..")
	if menu_panel and menu_panel is PanelContainer:
		menu_panel.theme = new_theme

	# MenuButton is a sibling of MenuPanel under CanvasLayer root.
	var menu_btn: Node = get_node_or_null("../../../..").get_node_or_null("MenuButton") \
		if get_node_or_null("../../../..") != null else null
	if menu_btn and menu_btn is Button:
		menu_btn.theme = new_theme

	theme_mode_changed.emit(dark)


# ── Widget factory helpers ────────────────────────────────────────────────────

func _section_label(title: String) -> Label:
	var lbl := Label.new()
	lbl.text = title
	if get_node_or_null("/root/BloxityTheme"):
		lbl.add_theme_color_override("font_color", BloxityTheme.DARK_TEXT_MUTED)
		lbl.add_theme_font_size_override("font_size", BloxityTheme.FONT_SIZE_SM)
	return lbl


func _make_slider(label_text: String, min_val: float, max_val: float, parent: Node) -> HSlider:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(140, 0)
	lbl.vertical_alignment  = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = 1.0
	slider.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(slider)

	var val_lbl := Label.new()
	val_lbl.custom_minimum_size = Vector2(32, 0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	row.add_child(val_lbl)

	# Keep the value label in sync.
	slider.value_changed.connect(func(v: float) -> void:
		val_lbl.text = str(int(v)) if slider.step >= 1.0 else ("%.1f" % v)
	)
	val_lbl.text = str(int(min_val))

	parent.add_child(row)
	return slider


func _make_check(label_text: String, parent: Node) -> CheckButton:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = SIZE_EXPAND_FILL
	lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)

	var check := CheckButton.new()
	row.add_child(check)

	parent.add_child(row)
	return check


func _spacer() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, 4)
	return c


# ── Public API ────────────────────────────────────────────────────────────────

## Returns the current mouse sensitivity (1.0–10.0).
func get_mouse_sensitivity() -> float:
	return float(_get_pref("controls/mouse_sens"))


## Returns true if dark mode is currently active.
func is_dark_mode() -> bool:
	return bool(_get_pref("theme/dark_mode"))
