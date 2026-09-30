extends Control
## LeaderboardView — populates the in-session player roster and provides
## a server-validated "Add Friend" action.
##
## Expected parent path inside MenuOverlay.tscn:
##   MenuPanel/VBox/Content/LeaderboardView
##
## Data sources:
##   main.get_active_peer_ids()         → Array of connected peer int IDs
##   GameJoinClient.get_peer_name(id)   → display name for each ID
##   GameJoinClient.display_name        → our own display name (for "You" badge)
##   GameJoinClient.user_id             → our own user_id (kept local-only)
##
## Friend request flow (server-validated):
##   Client → send_relay("friend_request", { "to_user_id": target_user_id })
##   Server validates both users exist, not already friends, not blocked,
##   then forwards an "friend_request_received" relay to the target.
##   No friend data is ever authoritative on the client.

## How long to wait before allowing a repeat request to the same target
## (guard against accidental double-taps, not a security measure).
const FRIEND_REQUEST_COOLDOWN_SEC := 10.0

## Emitted so parent panels / HUD can show a brief toast.
signal friend_request_sent(peer_display_name: String)
signal friend_request_failed(reason: String)

# ── Node refs (resolved in _ready) ─────────────────────────────────────────
var _scroll: ScrollContainer
var _list: VBoxContainer
var _empty_label: Label

# ── State ───────────────────────────────────────────────────────────────────
## peer_id (int) → unix timestamp of last outbound friend request, used for
## per-target cooldown so the button can't be spam-tapped.
var _last_request_time: Dictionary = {}

## peer_id (int) → user_id string.  Populated from the "players" relay
## message forwarded by GameJoinClient when it receives that message type.
## We listen to relay_received for a "leaderboard_sync" channel that the
## server MAY send — see _on_relay_received.  If the server doesn't send
## user_ids at all (older protocol), friend buttons simply stay disabled
## with tooltip "User ID unavailable".
var _peer_user_ids: Dictionary = {}


func _ready() -> void:
	_build_layout()
	_connect_signals()
	# Populate immediately in case the overlay is shown after peers are
	# already in the room (the common case for mid-session open).
	refresh()


# ── Layout bootstrap ────────────────────────────────────────────────────────

func _build_layout() -> void:
	# Outer scroll so the list survives large lobbies.
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	_scroll.size_flags_vertical   = SIZE_EXPAND_FILL
	add_child(_scroll)

	_list = VBoxContainer.new()
	_list.name = "List"
	_list.size_flags_horizontal = SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	_scroll.add_child(_list)

	_empty_label = Label.new()
	_empty_label.name = "EmptyLabel"
	_empty_label.text = "No other players in this session."
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_empty_label.visible = false
	_empty_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_empty_label)  # sibling of _scroll so it shows when list is empty


func _connect_signals() -> void:
	# React to peers joining / leaving so the list stays live even when the
	# panel is already open.
	var client: Node = get_node_or_null("/root/GameJoinClient")
	if client:
		if not client.peer_joined.is_connected(_on_peer_joined):
			client.peer_joined.connect(_on_peer_joined)
		if not client.peer_left.is_connected(_on_peer_left):
			client.peer_left.connect(_on_peer_left)
		# Listen for server-pushed user_id map (optional protocol extension).
		if client.has_signal("relay_received"):
			if not client.relay_received.is_connected(_on_relay_received):
				client.relay_received.connect(_on_relay_received)


# ── Public API ──────────────────────────────────────────────────────────────

## Called by MenuOverlay whenever the panel is opened on the Leaderboard tab.
func refresh() -> void:
	_rebuild_list()


# ── List building ────────────────────────────────────────────────────────────

func _rebuild_list() -> void:
	# Clear existing rows.
	for child in _list.get_children():
		child.queue_free()

	var main_node: Node = get_tree().current_scene
	if main_node == null or not main_node.has_method("get_active_peer_ids"):
		_show_empty("Not in a multiplayer session.")
		return

	var client: Node = get_node_or_null("/root/GameJoinClient")
	var peer_ids: Array = main_node.get_active_peer_ids()

	if peer_ids.is_empty():
		_show_empty("No other players in this session.")
		return

	_empty_label.visible = false
	_scroll.visible      = true

	var my_peer_int: int = 0
	if get_node_or_null("/root/NetworkManager"):
		my_peer_int = int(NetworkManager.get("_self_peer_int"))

	# Sort so the local player always appears first.
	var sorted_ids: Array = peer_ids.duplicate()
	sorted_ids.sort_custom(func(a: int, b: int) -> bool:
		if a == my_peer_int: return true
		if b == my_peer_int: return false
		return a < b
	)

	for peer_id in sorted_ids:
		var display_name: String = ""
		if client:
			display_name = client.get_peer_name(peer_id)
		if display_name == "":
			display_name = "Player %d" % (peer_id % 1000)

		var is_self: bool = (peer_id == my_peer_int)
		var row := _make_row(peer_id, display_name, is_self, client)
		_list.add_child(row)


func _make_row(peer_id: int, display_name: String, is_self: bool, client: Node) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Row_%d" % peer_id
	row.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)

	# ── Avatar circle (colour-coded by peer_id) ────────────────────────────
	var avatar := ColorRect.new()
	avatar.name = "Avatar"
	avatar.custom_minimum_size = Vector2(32, 32)
	avatar.color = _peer_color(peer_id)
	# Rounded via code — no StyleBox needed for a plain ColorRect.
	row.add_child(avatar)

	# ── Name label ─────────────────────────────────────────────────────────
	var name_lbl := Label.new()
	name_lbl.name = "Name"
	name_lbl.text = display_name + (" (You)" if is_self else "")
	name_lbl.size_flags_horizontal = SIZE_EXPAND_FILL
	name_lbl.vertical_alignment    = VERTICAL_ALIGNMENT_CENTER
	if get_node_or_null("/root/BloxityTheme"):
		name_lbl.add_theme_color_override("font_color",
			BloxityTheme.DARK_TEXT if not is_self else BloxityTheme.DARK_PRIMARY)
	row.add_child(name_lbl)

	# ── "Add Friend" button (hidden for local player) ──────────────────────
	if not is_self:
		var btn := Button.new()
		btn.name = "BtnFriend"
		btn.text = "+ Friend"
		btn.size_flags_vertical = SIZE_SHRINK_CENTER

		# Check cooldown so we can start disabled if a request was just sent.
		var last_t: float = _last_request_time.get(peer_id, 0.0)
		var now: float = Time.get_unix_time_from_system()
		if now - last_t < FRIEND_REQUEST_COOLDOWN_SEC:
			btn.disabled = true
			btn.tooltip_text = "Request sent — please wait."
		else:
			btn.disabled = false

		# We need the target's user_id for the relay payload.
		var target_user_id: String = _peer_user_ids.get(peer_id, "")
		btn.pressed.connect(
			func() -> void: _send_friend_request(peer_id, display_name, target_user_id, btn)
		)
		row.add_child(btn)

	return row


# ── Friend request relay ────────────────────────────────────────────────────

## Sends a friend request via the server relay channel.
## The server is the SOLE authority: it validates that:
##   • both user_ids exist in the database
##   • they are not already friends
##   • neither has blocked the other
## The client never writes friendship state locally — it only reacts to
## the server's confirmation relay ("friend_request_received" on the target,
## "friend_request_confirmed" back to us, handled by a future notification layer).
func _send_friend_request(
		peer_id: int,
		display_name: String,
		target_user_id: String,
		btn: Button) -> void:

	var client: Node = get_node_or_null("/root/GameJoinClient")
	if client == null:
		friend_request_failed.emit("Not connected.")
		return

	if not client.has_method("send_relay"):
		friend_request_failed.emit("Relay not available.")
		return

	# If we don't have the target's user_id yet, the server can still match
	# by peer_id for same-session requests — include both fields so the server
	# can fall back gracefully.
	var payload: Dictionary = {
		"to_peer_id":  peer_id,
		"to_user_id":  target_user_id,   # "" if not yet received from server
		"from_display_name": client.display_name,
	}

	client.send_relay("friend_request", payload)

	# Record timestamp and disable button for cooldown window.
	_last_request_time[peer_id] = Time.get_unix_time_from_system()
	btn.disabled     = true
	btn.tooltip_text = "Request sent — please wait."

	friend_request_sent.emit(display_name)

	# Re-enable after cooldown (cosmetic only — server enforces the real rules).
	get_tree().create_timer(FRIEND_REQUEST_COOLDOWN_SEC).timeout.connect(
		func() -> void:
			if is_instance_valid(self):
				_rebuild_list()
	)


# ── Signal handlers ─────────────────────────────────────────────────────────

func _on_peer_joined(_peer_id: int, _peer_name: String) -> void:
	_rebuild_list()


func _on_peer_left(_peer_id: int) -> void:
	_last_request_time.erase(_peer_id)
	_rebuild_list()


## Listens for an optional "leaderboard_sync" relay that the server MAY send
## to share user_ids for the peers in the room (needed for cross-session
## friend requests).  Channel name and payload schema must match the server
## implementation — the client never generates this message itself.
func _on_relay_received(channel: String, data: Dictionary, _from_peer_id: int) -> void:
	if channel != "leaderboard_sync":
		return
	# Expected payload: { "peers": [ { "peer_id": int, "user_id": string }, … ] }
	var peers = data.get("peers", [])
	if not (peers is Array):
		return
	for entry in peers:
		if not (entry is Dictionary):
			continue
		var pid: int    = int(entry.get("peer_id", 0))
		var uid: String = str(entry.get("user_id", ""))
		if pid != 0 and uid != "":
			_peer_user_ids[pid] = uid
	# Refresh so newly-acquired user_ids enable the friend buttons.
	_rebuild_list()


# ── Helpers ─────────────────────────────────────────────────────────────────

func _show_empty(message: String) -> void:
	_scroll.visible       = false
	_empty_label.visible  = true
	_empty_label.text     = message


## Deterministic pastel colour per peer so avatars are visually distinct
## without needing a server-side avatar image.
static func _peer_color(peer_id: int) -> Color:
	var hue := fmod(float(peer_id) * 0.618033988749895, 1.0)  # golden ratio spread
	return Color.from_hsv(hue, 0.55, 0.85)
