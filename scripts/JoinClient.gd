class_name JoinClient
extends Node

## The WebSocket URL of your matchmaking server.
@export var matchmaker_url: String = "wss://bloxity.onrender.com"

## A cron job now pings the matchmaker every minute to keep it warm, so we
## no longer budget for a 50+s Render cold start here.
## Matches NetworkManager's JOIN_TIMEOUT_SEC.
const JOIN_TIMEOUT_SEC := 20.0

## Filled by the server after the token is validated. NEVER set this yourself.
var display_name: String = ""
var user_id: String = ""
var room_id: String = ""
var world_id: String = ""

# peer int id -> last known display name. Populated any time we learn a
# name (existingPeerIds/"players"/"peer_joined"), independent of whether
# on_peer_joined()'s signal had a listener at the time -- the signal can
# fire before main.tscn has loaded (see "joined_room" below, where
# on_peer_joined() for existingPeerIds runs before on_joined()), so
# main.gd's fallback spawn loop reads names back out of here instead of
# relying solely on catching the signal live.
var _known_peer_names: Dictionary = {}

## Looks up the last known display name for a peer int id, or "" if we
## haven't heard one yet. Used by main.gd's fallback spawn loop to backfill
## nametags for peers spawned outside the peer_joined signal path.
func get_peer_name(peer_id: int) -> String:
	return _known_peer_names.get(peer_id, "")

## Records a peer's display name AND, if that peer's capsule is already
## spawned, applies it immediately -- rather than only writing the cache
## and hoping something reads it later. There's no fixed ordering
## guarantee between "the name-bearing message ('players'/'peer_joined')
## arrives" and "main.tscn finishes loading and runs its one-shot fallback
## spawn loop": if the name arrives after that loop already ran (and the
## peer_joined signal had no listener yet either -- same root cause as the
## existingPeerIds case), a cache-only write would silently go unread and
## the capsule would keep showing "Player".
func _set_known_peer_name(peer_id: int, name: String) -> void:
	_known_peer_names[peer_id] = name
	var scene := get_tree().current_scene
	if scene == null or not scene.has_method("get_player_node"):
		return # main.tscn hasn't loaded yet -- the fallback spawn loop will read the cache once it does
	var player_node = scene.get_player_node(peer_id)
	if player_node and player_node.has_method("set_player_name"):
		player_node.set_player_name(name)

var _socket := WebSocketPeer.new()
var _session_id: String = "" # from bloxity://join?sessionId=... -- exchanged for a real token via a "claim" message
var _token: String = "" # the actual, single-use join token; only ever set directly via --token= (dev override) or after the server's "token" reply to our "claim"
var _connection_failed: bool = false
var _joined: bool = false
var _timeout_remaining: float = 0.0

const MAX_RECONNECT_ATTEMPTS := 3
const RECONNECT_BASE_DELAY := 1.0 # seconds; doubles each attempt -- mirrors NetworkManager's backoff for the forwarded-token path
var _reconnect_attempts := 0
var _reconnect_delay := 0.0

## Emesso quando un relay message arriva su un canale custom (non "position").
## Qualunque script (anche dentro un .pck) puo' connettersi per ricevere
## messaggi di gioco sincronizzati tra tutti i client.
##   channel:     nome del canale (es. "tag_game", "my_custom_channel")
##   data:        dizionario con i dati del messaggio
##   from_peer_id: ID del peer che ha inviato il messaggio
signal relay_received(channel: String, data: Dictionary, from_peer_id: int)

func _ready() -> void:
	pass  # Connecting is deferred to start_join(), called explicitly once
	# the caller (GameJoinClient) confirms AutoUpdater has finished. Starting
	# the socket here unconditionally used to race the pck download/install:
	# load_resource_pack() blocks the main thread, so this socket's poll()
	# calls stall too, and the single-use join token can sit unsent/unread
	# on the wire until the block ends -- often past the token's server-side
	# expiry. See lobby.gd:_start_game_flow() for the call site.

func start_join() -> void:
	_session_id = _extract_deep_link_value("sessionId")
	if _session_id.is_empty():
		# Try LaunchHandler first: it already extracted the sessionId from
		# clipboard/cmdline during its _ready(). This avoids re-reading the
		# clipboard, which the user may have overwritten between launch and
		# this start_join() call -- the root cause of the "missing token"
		# issue on macOS (the clipboard was cleared or overwritten between
		# the two reads).
		var lh := get_node_or_null("/root/LaunchHandler")
		if lh != null and lh.session_id != "":
			_session_id = lh.session_id
		else:
			# Fallback: macOS never delivers bloxity:// links via cmdline args
			# (Apple Events only), so the website writes "BLOXITY_<sessionId>"
			# to the clipboard right before launching the link as a side
			# channel. Checked on every platform for simplicity -- harmless
			# on Windows since cmdline extraction above already succeeds.
			_session_id = _extract_session_id_from_clipboard()
	if _token.is_empty():
		_token = _extract_deep_link_value("token") # e.g. --token= dev override; direct URLs no longer carry a real token
	if _session_id.is_empty() and _token.is_empty():
		# Launched directly without a session/token — prompt user to launch via website instead of throwing an error
		return
	_reconnect_attempts = 0
	_reconnect_delay = 0.0
	_connect()

const CLIPBOARD_SESSION_PREFIX := "BLOXITY_"

## Reads the sessionId the website deposited on the clipboard as a macOS
## fallback, clearing it immediately after so it doesn't linger there (it's
## single-use server-side anyway, but no reason to leave it sitting around).
func _extract_session_id_from_clipboard() -> String:
	if not DisplayServer.clipboard_has():
		return ""
	var clip := DisplayServer.clipboard_get()
	if clip.begins_with(CLIPBOARD_SESSION_PREFIX):
		print("[Bloxity] Got sessionId from clipboard")
		DisplayServer.clipboard_set("")
		return clip.trim_prefix(CLIPBOARD_SESSION_PREFIX)
	return ""

func _connect() -> void:
	if _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_socket = WebSocketPeer.new()
	print("[Bloxity] Connecting to matchmaker: %s" % matchmaker_url)
	var err := _socket.connect_to_url(matchmaker_url)
	if err != OK:
		_fail_or_retry("Could not start matchmaker connection: %d" % err)
		return
	_timeout_remaining = JOIN_TIMEOUT_SEC


func close_for_forwarded_join() -> void:
	_connection_failed = true
	_joined = false
	_reconnect_delay = 0.0
	if _socket.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_socket.close()

func _process(delta: float) -> void:
	_socket.poll()
	_tick_reconnect(delta)

	var state := _socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		while _socket.get_available_packet_count() > 0:
			var packet := _socket.get_packet()
			var text := packet.get_string_from_utf8()
			_handle_message(text)
	elif state == WebSocketPeer.STATE_CLOSED and not _connection_failed and not _joined and _reconnect_delay <= 0.0:
		# _reconnect_delay > 0.0 means a retry is already scheduled from an
		# earlier tick this same closure -- without that guard this branch
		# would re-fire every frame the socket stays closed and burn through
		# all reconnect attempts instantly instead of waiting between them.
		_fail_or_retry("matchmaker connection closed")

	if not _joined and not _connection_failed and _timeout_remaining > 0.0:
		_timeout_remaining -= delta
		if _timeout_remaining <= 0.0:
			_timeout_remaining = 0.0
			_fail_or_retry("Timed out waiting for the matchmaking server to respond.")

## Transport-level failures (unreachable server, dropped mid-handshake,
## timeout) get a few automatic retries with backoff -- this is the join
## path a stray token forward doesn't take, and previously had zero
## resilience to a transient network blip. Explicit rejections from the
## server (bad/expired token, room full, etc.) do NOT retry here -- see
## the "error" case in _handle_message, which calls _report_error
## directly since retrying with the same token won't help.
func _fail_or_retry(reason: String) -> void:
	if _socket.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_socket.close()
	if _reconnect_attempts < MAX_RECONNECT_ATTEMPTS:
		_reconnect_attempts += 1
		_reconnect_delay = RECONNECT_BASE_DELAY * pow(2, _reconnect_attempts - 1)
		return
	_connection_failed = true
	_report_error(reason)

func _tick_reconnect(delta: float) -> void:
	if _reconnect_delay <= 0.0:
		return
	_reconnect_delay -= delta
	if _reconnect_delay <= 0.0:
		_reconnect_delay = 0.0
		_connect()

func _handle_message(text: String) -> void:
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_warning("[Bloxity] Ignoring malformed message: %s" % text)
		return

	var msg: Dictionary = json.get_data()
	var msg_type: String = msg.get("type", "")

	match msg_type:
		"welcome":
			if not _session_id.is_empty():
				var claim_payload := {
					"type": "claim",
					"sessionId": _session_id
				}
				_socket.send_text(JSON.stringify(claim_payload))
				print("[Bloxity] Sent claim for sessionId")
			else:
				_send_join()

		"token":
			var claimed_token: String = msg.get("token", "")
			if claimed_token.is_empty():
				push_error("[Bloxity] Claim succeeded but server sent no token")
				_report_error("Session expired, please try again from the website")
				return
			_token = claimed_token
			_send_join()

		"joined_room":
			_joined = true
			_reconnect_attempts = 0
			_reconnect_delay = 0.0
			user_id = msg.get("userId", "")
			display_name = msg.get("displayName", "")
			room_id = msg.get("roomId", "")
			world_id = msg.get("worldId", "")

			if NetworkManager:
				NetworkManager.current_room_id = room_id
				NetworkManager._ws = _socket
				NetworkManager._socket_driven_externally = true
				NetworkManager._state = NetworkManager.State.IN_ROOM
				NetworkManager._self_peer_str = str(msg.get("selfPeerId", ""))
				NetworkManager._self_peer_int = NetworkManager._string_id_to_int(NetworkManager._self_peer_str)
				NetworkManager._setup_relay_peer()
				for other_id in msg.get("existingPeerIds", []):
					var other_str := str(other_id)
					NetworkManager._add_peer(other_str)
					var p_id := NetworkManager._string_id_to_int(other_str)
					var fallback_name := "Player " + str(p_id % 1000)
					if not _known_peer_names.has(p_id):
						_known_peer_names[p_id] = fallback_name
					on_peer_joined(p_id, fallback_name)

			print("[Bloxity] Joined world=%s room=%s as '%s'" % [world_id, room_id, display_name])
			on_joined(world_id, room_id, display_name)

		"players":
			var peers: Array = msg.get("players", [])
			for peer in peers:
				if peer is Dictionary:
					var p_str := str(peer.get("id", ""))
					var peer_id: int = 0
					if NetworkManager and p_str != "":
						NetworkManager._add_peer(p_str)
						peer_id = NetworkManager._string_id_to_int(p_str)
					else:
						peer_id = int(peer.get("id", 0))
					var peer_name: String = peer.get("displayName", "Player " + str(peer_id % 1000))
					_set_known_peer_name(peer_id, peer_name)
					on_peer_joined(peer_id, peer_name)

		"peer_joined":
			var peer_str: String = str(msg.get("peerId", ""))
			var peer_id: int = 0
			if NetworkManager:
				NetworkManager._add_peer(peer_str)
				peer_id = NetworkManager._string_id_to_int(peer_str)
			else:
				peer_id = int(msg.get("peerId", 0))
			var peer_name: String = msg.get("displayName", "Player " + str(peer_id % 1000))
			_set_known_peer_name(peer_id, peer_name)
			on_peer_joined(peer_id, peer_name)

		"relay":
			var channel_val = msg.get("channel", "")
			# Must use the SAME id space as joined_room/players/peer_joined
			# (NetworkManager._string_id_to_int on the stringified id), not a
			# raw int() cast of the JSON number. Those two can disagree, which
			# silently broke get_peer_name(from_id) lookups for chat/relay
			# senders (nametags stayed correct because they're set separately
			# via _set_known_peer_name, which does use _string_id_to_int).
			var from_id: int
			if NetworkManager:
				from_id = NetworkManager._string_id_to_int(str(msg.get("fromPeerId", 0)))
			else:
				from_id = int(msg.get("fromPeerId", 0))
			if typeof(channel_val) == TYPE_STRING and channel_val == "position":
				_apply_remote_position(msg)
			elif typeof(channel_val) != TYPE_STRING and NetworkManager:
				# _handle_relay() is only for the @rpc/WebSocketRelayPeer transport,
				# which uses an INT channel + base64 "data" string (see
				# NetworkManager._send_relay_packet()). A named custom channel (e.g.
				# "tag_game" from send_relay()) has a STRING channel and a raw
				# Dictionary "data" -- routing that through here used to crash into
				# Marshalls.base64_to_raw(<Dictionary>) on every single custom-
				# channel message. Custom channels only ever go through
				# relay_received below, never through this pipeline.
				NetworkManager._handle_relay(msg)
			
			# Emetti segnale per canali custom (tag_game, etc.)
			# I giochi nei .pck si connettono a questo segnale per
			# ricevere messaggi sincronizzati SENZA modificare il client.
			if typeof(channel_val) == TYPE_STRING and channel_val != "position":
				relay_received.emit(channel_val, msg.get("data", {}), from_id)

		"peer_left":
			var peer_str: String = str(msg.get("peerId", ""))
			var peer_id: int = 0
			if NetworkManager:
				peer_id = NetworkManager._string_id_to_int(peer_str)
			else:
				peer_id = int(msg.get("peerId", 0))
			on_peer_left(peer_id)
			_known_peer_names.erase(peer_id)

		"error":
			var reason: String = msg.get("reason", msg.get("message", "unknown"))
			if reason == "session_expired":
				reason = "Session expired, please try again from the website"
			push_error("[Bloxity] Join failed: %s" % reason)
			_report_error(reason)

## Invia un messaggio relay su un canale custom a TUTTI gli altri peer.
## Qualunque script (anche dentro un .pck) puo' chiamarlo per sincronizzare
## stato di gioco tra tutti i client (es. "tag_game" per cambiare IT).
##   channel: nome del canale (es. "tag_game")
##   data:    dizionario con i dati da inviare
func send_relay(channel: String, data: Dictionary) -> void:
	if _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		var manager := get_node_or_null("/root/NetworkManager")
		if manager == null or not manager.has_method("send_custom_relay"):
			return
		manager.send_custom_relay(channel, data)
		return
	var payload := {
		"type": "relay",
		"channel": channel,
		"data": data,
	}
	_socket.send_text(JSON.stringify(payload))

## Sends the actual "join" message once we have a real token, whether from
## a direct --token= override or from the server's "token" reply to "claim".
func _send_join() -> void:
	var payload := {
		"type": "join",
		"token": _token
	}
	_socket.send_text(JSON.stringify(payload))
	print("[Bloxity] Sent join token")

## Applies a raw "position" relay message straight to the sending peer's
## capsule, entirely outside the WebSocketRelayPeer/@rpc pipeline. Every
## early-return below is logged (once per distinct reason) because this
## path previously had zero diagnostics -- if remote players ever appear
## frozen again, these warnings pinpoint exactly which link in the chain
## (unregistered sender, scene not ready, capsule not yet spawned) is
## dropping the packet instead of us having to re-derive it from scratch.
func _apply_remote_position(msg: Dictionary) -> void:
	var from_str: String = str(msg.get("fromPeerId", ""))
	if from_str == "" or not NetworkManager:
		push_warning("[Bloxity] _apply_remote_position: dropped -- empty fromPeerId or no NetworkManager")
		return
	if from_str == NetworkManager._self_peer_str:
		return # our own echoed position, not an error
	var data = msg.get("data", {})
	if not (data is Dictionary):
		push_warning("[Bloxity] _apply_remote_position: dropped -- 'data' from peer '%s' is not a Dictionary" % from_str)
		return
	var peer_int := NetworkManager._string_id_to_int(from_str)
	var scene := get_tree().current_scene
	if scene == null or not scene.has_method("get_player_node"):
		push_warning("[Bloxity] _apply_remote_position: dropped -- current_scene missing/no get_player_node (scene=%s)" % str(scene))
		return
	var remote_player = scene.get_player_node(peer_int)
	if remote_player == null or not remote_player.has_method("apply_remote_position"):
		push_warning("[Bloxity] _apply_remote_position: dropped -- no capsule for peer '%s' (int=%d) yet" % [from_str, peer_int])
		return
	var pos := Vector3(
		float(data.get("x", 0.0)),
		float(data.get("y", 0.0)),
		float(data.get("z", 0.0))
	)
	var yaw := float(data.get("ry", 0.0))
	if not is_finite(pos.x) or not is_finite(pos.y) or not is_finite(pos.z) or not is_finite(yaw):
		return
	if absf(pos.x) > 100000.0 or absf(pos.y) > 100000.0 or absf(pos.z) > 100000.0:
		return
	remote_player.apply_remote_position(pos, yaw)

## Override this in your game scene to spawn the local player.
func on_joined(_world: String, _room: String, _name: String) -> void:
	pass

## Override this to spawn a remote peer.
func on_peer_joined(_peer_id: int, _peer_name: String) -> void:
	pass

## Override this when a remote peer leaves.
func on_peer_left(_peer_id: int) -> void:
	pass

## Override this to show an error UI.
func on_join_error(_reason: String) -> void:
	pass

func _report_error(reason: String) -> void:
	if not _connection_failed:
		_connection_failed = true
		on_join_error(reason)

## Extracts a value ("sessionId" or, for dev overrides, "token") from a
## bloxity:// deep link or a --key= override.
func _extract_deep_link_value(key: String) -> String:
	var all_args := OS.get_cmdline_args()
	all_args.append_array(OS.get_cmdline_user_args())
	for arg in all_args:
		if arg.begins_with("bloxity://"):
			var value := _value_from_uri(arg, key)
			if value != "":
				return value
		elif arg.begins_with("--%s=" % key):
			return arg.replace("--%s=" % key, "").uri_decode()
	return ""

func _value_from_uri(uri: String, key: String) -> String:
	var query_start := uri.find("?")
	if query_start == -1:
		return ""
	var query := uri.substr(query_start + 1)
	for pair in query.split("&"):
		var kv := pair.split("=")
		if kv.size() == 2 and kv[0] == key:
			return kv[1].uri_decode()
	return ""
