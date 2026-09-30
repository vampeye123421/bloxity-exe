extends CanvasLayer
## MenuOverlay — top-left Roblox-style menu button that reveals a
## dropdown containing Leaderboard and Settings tabs.
##
## Mount point: add as a child of Main.tscn's root (or any Node3D scene)
## AFTER the existing HUD CanvasLayer. It auto-registers its layer so it
## sits on top of HUD (layer 2 vs HUD's default 1).
##
## Theme: pulled from BloxityTheme autoload. Respects DARK / LIGHT mode
## as stored in UserPrefs (defaults to DARK if not set).

const TAB_LEADERBOARD := 0
const TAB_SETTINGS    := 1

@onready var _btn_menu: Button              = $MenuButton
@onready var _panel: PanelContainer         = $MenuPanel
@onready var _tab_bar: HBoxContainer        = $MenuPanel/VBox/TabBar
@onready var _btn_lb: Button                = $MenuPanel/VBox/TabBar/BtnLeaderboard
@onready var _btn_set: Button               = $MenuPanel/VBox/TabBar/BtnSettings
@onready var _lb_container: Control         = $MenuPanel/VBox/Content/LeaderboardView
@onready var _set_container: Control        = $MenuPanel/VBox/Content/SettingsView

var _open := false
var _active_tab := TAB_LEADERBOARD


func _ready() -> void:
	layer = 2   # above HUD's default layer 1

	# Apply Bloxity theme
	if get_node_or_null("/root/BloxityTheme"):
		var mode := BloxityTheme.Mode.DARK
		_panel.theme = BloxityTheme.get_theme(mode)
		_btn_menu.theme = BloxityTheme.get_theme(mode)

	_panel.visible = false

	_btn_menu.pressed.connect(_toggle_panel)
	_btn_lb.pressed.connect(func(): _switch_tab(TAB_LEADERBOARD))
	_btn_set.pressed.connect(func(): _switch_tab(TAB_SETTINGS))

	_switch_tab(TAB_LEADERBOARD)


func _toggle_panel() -> void:
	_open = not _open
	_panel.visible = _open
	if _open and _active_tab == TAB_LEADERBOARD:
		# Refresh leaderboard data whenever the panel is opened
		if _lb_container.has_method("refresh"):
			_lb_container.refresh()


func _switch_tab(tab: int) -> void:
	_active_tab = tab
	_lb_container.visible  = (tab == TAB_LEADERBOARD)
	_set_container.visible = (tab == TAB_SETTINGS)
	# Visual active-state on tab buttons
	var theme_node = get_node_or_null("/root/BloxityTheme")
	if theme_node:
		var primary  := BloxityTheme.DARK_PRIMARY
		var inactive := Color(BloxityTheme.DARK_CARD_RAISED)
		_style_tab_btn(_btn_lb,  tab == TAB_LEADERBOARD, primary, inactive)
		_style_tab_btn(_btn_set, tab == TAB_SETTINGS,    primary, inactive)


static func _style_tab_btn(btn: Button, active: bool, primary: Color, inactive: Color) -> void:
	var sb := BloxityTheme._make_flat(
		primary if active else inactive,
		Color(0, 0, 0, 0), BloxityTheme.RADIUS_MD, 0
	)
	sb.content_margin_left   = 14
	sb.content_margin_right  = 14
	sb.content_margin_top    = 6
	sb.content_margin_bottom = 6
	btn.add_theme_stylebox_override("normal",  sb)
	btn.add_theme_stylebox_override("hover",   sb)
	btn.add_theme_stylebox_override("pressed", sb)


func _unhandled_input(event: InputEvent) -> void:
	# Close panel on Escape (won't steal from chat — ChatManager guards that)
	var chat_manager := get_node_or_null("/root/ChatManager")
	if chat_manager and chat_manager.is_chat_active():
		return
	if _open and event is InputEventKey and event.pressed \
			and event.keycode == KEY_ESCAPE and not event.echo:
		_open = false
		_panel.visible = false
		get_viewport().set_input_as_handled()
