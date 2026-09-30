class_name WebSocketRelayPeer
extends MultiplayerPeerExtension
## Wraps the signaling WebSocket NetworkManager already owns and repurposes
## it as a dumb packet relay, so the high-level multiplayer API (RPCs,
## MultiplayerSynchronizer, spawner, etc.) works exactly like it did over
## WebRTC -- just routed through the Render signaling server instead of a
## P2P mesh.
##
## Correctness note: this collapses TRANSFER_MODE_UNRELIABLE into TCP-backed
## ordered delivery (see NetworkManager for why that's an accepted tradeoff,
## not a non-issue).
##
## NetworkManager drives this class: it owns the real WebSocketPeer, polls
## it in _process, and calls push_incoming_packet() whenever a "relay"
## message arrives. This class never touches the socket directly -- it only
## queues outgoing sends via send_callback and queues incoming packets for
## the MultiplayerAPI to pull via _get_packet_script().

var _unique_id: int = 0
var _peer_ids: Array[int] = []
var _int_to_str: Dictionary = {}   # int id -> server's string peerId
var _incoming: Array = []          # [{from:int, channel:int, mode:int, data:PackedByteArray}, ...]
const MAX_QUEUED_PACKETS := 4096

var _target_peer: int = 0
var _transfer_channel: int = 0
var _transfer_mode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _refusing := false
var _connection_status: int = MultiplayerPeer.CONNECTION_DISCONNECTED

var _last_packet_peer := 0
var _last_packet_channel := 0
var _last_packet_mode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE

## func(target_str: String, channel: int, mode: int, bytes: PackedByteArray) -> void
## target_str == "" means broadcast to everyone else in the room.
var send_callback: Callable


func setup(self_id: int) -> void:
	_unique_id = self_id
	_connection_status = MultiplayerPeer.CONNECTION_CONNECTED


func add_remote_peer(int_id: int, str_id: String) -> void:
	if int_id in _peer_ids:
		return
	_peer_ids.append(int_id)
	_int_to_str[int_id] = str_id
	peer_connected.emit(int_id)


func remove_remote_peer(int_id: int) -> void:
	if not (int_id in _peer_ids):
		return
	_peer_ids.erase(int_id)
	_int_to_str.erase(int_id)
	peer_disconnected.emit(int_id)


## Called by NetworkManager when a "relay" message arrives over the WS.
func push_incoming_packet(from_int: int, channel: int, mode: int, data: PackedByteArray) -> void:
	if _incoming.size() >= MAX_QUEUED_PACKETS:
		_incoming.pop_front()
	_incoming.push_back({ "from": from_int, "channel": channel, "mode": mode, "data": data })


func _get_available_packet_count() -> int:
	return _incoming.size()


func _get_max_packet_size() -> int:
	return 1 << 20  # 1 MB -- comfortably above anything JSON/base64 over WS should carry


func _get_packet_script() -> PackedByteArray:
	if _incoming.is_empty():
		return PackedByteArray()
	var pkt: Dictionary = _incoming.pop_front()
	_last_packet_peer = pkt["from"]
	_last_packet_channel = pkt["channel"]
	_last_packet_mode = pkt["mode"]
	return pkt["data"]


func _put_packet_script(p_buffer: PackedByteArray) -> Error:
	if not send_callback.is_valid():
		return ERR_UNCONFIGURED
	var target_str := ""
	if _target_peer > 0:
		if not _int_to_str.has(_target_peer):
			return ERR_INVALID_PARAMETER
		target_str = _int_to_str[_target_peer]
	# _target_peer == 0 (broadcast) and negative "everyone except -id" both
	# fall through to target_str == "" -- we don't have enough peers per
	# room for the except-id nuance to matter.
	send_callback.call(target_str, _transfer_channel, _transfer_mode, p_buffer)
	return OK


func _get_packet_peer() -> int:
	return _last_packet_peer


func _get_packet_channel() -> int:
	return _last_packet_channel


func _get_packet_mode() -> int:
	return _last_packet_mode


func _set_target_peer(p_peer: int) -> void:
	_target_peer = p_peer


func _set_transfer_channel(p_channel: int) -> void:
	_transfer_channel = p_channel


func _get_transfer_channel() -> int:
	return _transfer_channel


func _set_transfer_mode(p_mode: int) -> void:
	_transfer_mode = p_mode


func _get_transfer_mode() -> int:
	return _transfer_mode


func _is_server() -> bool:
	return _unique_id == 1


func _poll() -> void:
	pass  # No-op: NetworkManager polls the real WebSocketPeer itself and
		  # feeds this class via push_incoming_packet().


func _close() -> void:
	_incoming.clear()
	_peer_ids.clear()
	_int_to_str.clear()
	_connection_status = MultiplayerPeer.CONNECTION_DISCONNECTED


func _disconnect_peer(p_peer: int, _p_force: bool) -> void:
	remove_remote_peer(p_peer)


func _get_unique_id() -> int:
	return _unique_id


func _set_refuse_new_connections(p_enable: bool) -> void:
	_refusing = p_enable


func _is_refusing_new_connections() -> bool:
	return _refusing


func _is_server_relay_supported() -> bool:
	# There's no central authority peer here (just a raw relay through
	# Render) -- broadcast (_target_peer == 0) sends go straight to the
	# server, which fans them out itself, so SceneMultiplayer doesn't need
	# to do peer-1-relays-for-everyone routing.
	return false


func _get_connection_status() -> int:
	return _connection_status
