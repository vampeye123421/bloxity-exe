extends Node
# Autoload singleton. Talks to the Bloxity matchmaking/signaling server using
# a one-time join token issued by the website, then routes ALL game traffic
# through that same WebSocket -- no WebRTC, no TURN, no VPS.
#
# The client never decides which room/world to join -- that choice lives on
# the website ("Join Friend" / "Join Game"). The website mints a short-lived,
# single-use join token and hands it to the client via a
# bloxity://join?token=... link (see launch_handler.gd for how that arrives).
#
# --- Why relay instead of WebRTC/TURN ---
# Direct P2P either exposes both players' real IPs to each other (plain
# STUN) or needs a dedicated TURN relay to hide them, which costs a VPS.
# Instead, ALL game traffic is relayed through the existing Render
# signaling server as "relay" WebSocket messages, wrapped by
# WebSocketRelayPeer (a MultiplayerPeerExtension) so the rest of the game
# (RPCs, MultiplayerSynchronizer, etc.) doesn't know the difference.
#
# Tradeoffs, on purpose, not overlooked:
# - This is TCP under the hood, so Godot's "unreliable" transfer mode no
#   longer actually drops stale packets -- it queues them like everything
#   else does. Fine for a couple of friends on a decent connection; will
#   feel worse than real P2P under packet loss.
# - Every packet round-trips through wherever Render happens to run that
#   free instance, not the shortest path between the two players.
# - JSON + base64 over WS has real per-packet overhead vs binary WebRTC
#   data channels. Not a problem at this scale; would be at a bigger one.

signal joined_room(room_id: String, world_id: String)
signal join_failed(reason: String)
signal connecting()

const SIGNALING_URL = "wss://bloxity.onrender.com"

const JOIN_TIMEOUT_SEC := 20.0 # A cron job now pings the matchmaker every minute to keep it warm, so we no longer budget for a 50+s Render cold start -- this just covers normal connect + join round-trip time with some margin.
const MAX_RECONNECT_ATTEMPTS := 3
const RECONNECT_BASE_DELAY := 1.0 # seconds; doubles each attempt

enum State { IDLE, CONNECTING, WAITING_FOR_JOIN, IN_ROOM }

var current_room_id := ""

var _ws := WebSocketPeer.new()
var _state := State.IDLE
var _self_peer_str := ""
var _self_peer_int := 0
var _pending_token := ""
var _relay_peer: WebSocketRelayPeer = null
var _str_to_int: Dictionary = {}    # peer_str -> int id used by Godot's multiplayer API

var _join_timeout_timer := 0.0
var _reconnect_attempts := 0
var _reconnect_delay := 0.0


func _process(delta: float) -> void:
	_poll_socket()
	_tick_join_timeout(delta)
	_tick_reconnect(delta)

var _socket_driven_externally := false  # true once JoinClient hands us an
		# already-open socket it connected and joined itself (see JoinClient's
		# "joined_room" handler). In that case JoinClient keeps polling and
		# fully parsing every message on it (it understands message types,
		# like "players", that we never learned to handle) -- so we must NOT
		# also poll/drain the same WebSocketPeer here. Two readers popping
		# packets off the same incoming queue each frame is a race: whichever
		# _process ran first that frame would silently steal messages the
		# other was waiting for (e.g. an existing player's real display name,
		# which only ever arrives via a "players" message we don't parse).
const RELAY_DEBUG := false

func _poll_socket() -> void:
	if _socket_driven_externally:
		return
	var ready_state = _ws.get_ready_state()
	if ready_state == WebSocketPeer.STATE_OPEN or ready_state == WebSocketPeer.STATE_CONNECTING:
		_ws.poll()
	ready_state = _ws.get_ready_state()
	if ready_state == WebSocketPeer.STATE_OPEN:
		while _ws.get_available_packet_count() > 0:
			_handle_message(_ws.get_packet().get_string_from_utf8())
	elif ready_state == WebSocketPeer.STATE_CLOSED and _state != State.IDLE and _state != State.IN_ROOM:
		_fail_or_retry("Lost connection to the matchmaking server.")



## Called once, on launch, with the token the website embedded in the
## bloxity://join link. This is the ONLY way to join a room from the client.
func join_with_token(token: String) -> void:
	if token == "":
		join_failed.emit("No join token provided.")
		return
	_pending_token = token
	_reconnect_attempts = 0
	_reconnect_delay = 0.0
	_start_connect()


var _connecting_with_session := false


func join_with_session_or_token(value: String, is_direct_token: bool = false) -> void:
	if value.is_empty():
		join_failed.emit("No join session provided.")
		return
	_pending_token = value
	_connecting_with_session = not is_direct_token
	_reconnect_attempts = 0
	_reconnect_delay = 0.0
	var join_client := get_node_or_null("/root/GameJoinClient")
	if join_client and join_client.has_method("close_for_forwarded_join"):
		join_client.close_for_forwarded_join()
	if _relay_peer:
		_relay_peer.close()
		_relay_peer = null
	_str_to_int.clear()
	current_room_id = ""
	multiplayer.multiplayer_peer = null
	_socket_driven_externally = false
	_start_connect()


func _start_connect() -> void:
	if _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_ws = WebSocketPeer.new()
	_state = State.CONNECTING
	connecting.emit()
	_join_timeout_timer = JOIN_TIMEOUT_SEC
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send_join_request()
		return
	var err := _ws.connect_to_url(SIGNALING_URL)
	if err != OK:
		_fail_or_retry("Could not reach the matchmaking server.")


func _send_join_request() -> void:
	_state = State.WAITING_FOR_JOIN
	_ws.send_text(JSON.stringify({ "type": "join", "token": _pending_token }))


func _tick_join_timeout(delta: float) -> void:
	if _state != State.CONNECTING and _state != State.WAITING_FOR_JOIN:
		return
	_join_timeout_timer -= delta
	if _join_timeout_timer <= 0.0:
		_fail_or_retry("Timed out waiting for the matchmaking server.")


## Transport-level failures (unreachable server, dropped mid-handshake,
## timeout) get a few automatic retries with backoff. Explicit rejections
## from the server (bad/expired token, room full, etc.) do NOT retry here --
## see the "error" case in _handle_message.
func _fail_or_retry(reason: String) -> void:
	_state = State.IDLE
	if _reconnect_attempts < MAX_RECONNECT_ATTEMPTS:
		_reconnect_attempts += 1
		_reconnect_delay = RECONNECT_BASE_DELAY * pow(2, _reconnect_attempts - 1)
		return
	join_failed.emit(reason)


func _tick_reconnect(delta: float) -> void:
	if _reconnect_delay <= 0.0:
		return
	_reconnect_delay -= delta
	if _reconnect_delay <= 0.0:
		_reconnect_delay = 0.0
		_start_connect()


func _handle_message(raw: String) -> void:
	var data = JSON.parse_string(raw)
	if typeof(data) != TYPE_DICTIONARY:
		return

	match data.get("type", ""):
		"welcome":
			_self_peer_str = str(data.get("peerId", ""))
			_self_peer_int = _string_id_to_int(_self_peer_str)
			if _connecting_with_session:
				_ws.send_text(JSON.stringify({"type": "claim", "sessionId": _pending_token}))
			else:
				_send_join_request()

		"token":
			var claimed_token := str(data.get("token", ""))
			if claimed_token.is_empty():
				_state = State.IDLE
				_reconnect_delay = 0.0
				join_failed.emit("Session expired. Please launch again from the website.")
			else:
				_pending_token = claimed_token
				_connecting_with_session = false
				_send_join_request()

		"joined_room":
			_state = State.IN_ROOM
			_reconnect_attempts = 0
			current_room_id = data.get("roomId", "")
			_setup_relay_peer()
			for other_id in data.get("existingPeerIds", []):
				_add_peer(other_id)
			joined_room.emit(current_room_id, data.get("worldId", ""))

		"peer_joined":
			var peer_str := str(data.get("peerId", ""))
			_add_peer(peer_str)
			var peer_int := _string_id_to_int(peer_str)
			var join_client := get_node_or_null("/root/GameJoinClient")
			if join_client:
				var peer_name := str(data.get("displayName", "Player %d" % (peer_int % 1000)))
				join_client._set_known_peer_name(peer_int, peer_name)
				join_client.on_peer_joined(peer_int, peer_name)

		"players":
			var join_client := get_node_or_null("/root/GameJoinClient")
			for peer in data.get("players", []):
				if peer is Dictionary:
					var peer_str := str(peer.get("id", ""))
					if peer_str.is_empty():
						continue
					_add_peer(peer_str)
					var peer_int := _string_id_to_int(peer_str)
					if join_client:
						var peer_name := str(peer.get("displayName", "Player %d" % (peer_int % 1000)))
						join_client._set_known_peer_name(peer_int, peer_name)
						join_client.on_peer_joined(peer_int, peer_name)

		"peer_left":
			var other_str := str(data.get("peerId", ""))
			if _str_to_int.has(other_str):
				var other_int = _str_to_int[other_str]
				if _relay_peer:
					_relay_peer.remove_remote_peer(other_int)
				_str_to_int.erase(other_str)
				var join_client := get_node_or_null("/root/GameJoinClient")
				if join_client and join_client.has_method("on_peer_left"):
					join_client.on_peer_left(other_int)
					join_client._known_peer_names.erase(other_int)

		"relay":
			var channel = data.get("channel", null)
			if typeof(channel) == TYPE_STRING:
				var join_client := get_node_or_null("/root/GameJoinClient")
				if join_client:
					var from_str := str(data.get("fromPeerId", ""))
					var from_id := _string_id_to_int(from_str)
					if channel == "position":
						join_client._apply_remote_position(data)
					else:
						var payload = data.get("data", {})
						if payload is Dictionary:
							join_client.relay_received.emit(channel, payload, from_id)
			else:
				_handle_relay(data)

		"error":
			# Server actively rejected the request (expired/invalid/used
			# token, room full, etc.) -- retrying with the same token won't
			# help, so surface it immediately instead of auto-retrying.
			_state = State.IDLE
			_reconnect_delay = 0.0
			join_failed.emit(data.get("message", "Unknown error."))


func _string_id_to_int(s: String) -> int:
	# Godot's multiplayer API needs small positive integer peer ids.
	# We turn the server's string id into one deterministically, so both
	# sides of a connection compute the same int for the same peer.
	var h := hash(s)
	if h < 0:
		h = -h
	h = (h % 2147483000) + 1
	return h


func _setup_relay_peer() -> void:
	if _relay_peer != null:
		return
	_relay_peer = WebSocketRelayPeer.new()
	_relay_peer.setup(_self_peer_int)
	_relay_peer.send_callback = _send_relay_packet
	multiplayer.multiplayer_peer = _relay_peer


func _add_peer(other_id) -> void:
	var other_str: String = str(other_id)
	if other_str == "" or _str_to_int.has(other_str):
		return
	var other_int := _string_id_to_int(other_str)
	_str_to_int[other_str] = other_int
	if RELAY_DEBUG:
		print("[Bloxity][relay] registered peer '%s' -> int %d (relay_peer ready=%s)" % [other_str, other_int, str(_relay_peer != null)])
	if _relay_peer:
		_relay_peer.add_remote_peer(other_int, other_str)


func _send_relay_packet(target_str: String, channel: int, mode: int, data: PackedByteArray) -> void:
	_ws.send_text(JSON.stringify({
		"type": "relay",
		"targetPeerId": target_str, # "" means broadcast to the room
		"channel": channel,
		"mode": mode,
		"data": Marshalls.raw_to_base64(data),
	}))


func _handle_relay(data: Dictionary) -> void:
	if _relay_peer == null:
		if RELAY_DEBUG:
			print("[Bloxity][relay] dropped: _relay_peer not set up yet")
		return
	var from_str: String = str(data.get("fromPeerId", ""))
	if from_str == "" or not _str_to_int.has(from_str):
		if RELAY_DEBUG:
			print("[Bloxity][relay] dropped packet from unregistered peer '%s' -- known peers: %s" % [from_str, str(_str_to_int.keys())])
		return # packet from a peer we never got joined_room/peer_joined for -- drop it
	if RELAY_DEBUG:
		print("[Bloxity][relay] accepted packet from peer '%s' (int=%d), channel=%s" % [from_str, _str_to_int[from_str], str(data.get("channel", 0))])
	var bytes := Marshalls.base64_to_raw(data.get("data", ""))
	_relay_peer.push_incoming_packet(
		_str_to_int[from_str],
		int(data.get("channel", 0)),
		int(data.get("mode", MultiplayerPeer.TRANSFER_MODE_RELIABLE)),
		bytes
	)


## Bypasses the WebSocketRelayPeer/@rpc pipeline entirely for position
## updates: sends a raw "relay" message straight over the same WebSocket
## JoinClient owns (NetworkManager._ws is the same live socket reference --
## JoinClient assigns it in its "joined_room" handler). channel is the
## string "position" here (NOT the int channel the @rpc/relay-peer chain
## uses for its own "relay" messages) so JoinClient can special-case it
## before it ever reaches _handle_relay() above, which expects an int
## channel and base64 "data".
func send_raw_position(pos: Vector3, rot_y: float) -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var msg := {
		"type": "relay",
		"targetPeerId": "", # "" means broadcast to the room, same convention as _send_relay_packet
		"channel": "position",
		"data": { "x": pos.x, "y": pos.y, "z": pos.z, "ry": rot_y },
	}
	_ws.send_text(JSON.stringify(msg))


func send_custom_relay(channel: String, data: Dictionary) -> void:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN or channel.is_empty():
		return
	_ws.send_text(JSON.stringify({"type": "relay", "channel": channel, "data": data}))
