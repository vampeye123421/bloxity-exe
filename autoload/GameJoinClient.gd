# autoload/GameJoinClient.gd
extends JoinClient

signal joined_room(world: String, room: String, display_name: String)
signal peer_joined(peer_id: int, peer_name: String)
signal peer_left(peer_id: int)
signal join_failed(reason: String)

func on_joined(world: String, room: String, name_str: String) -> void:
	print("SERVER SENT NAME: '" + name_str + "'")
	print("Local player joined %s/%s as %s" % [world, room, name_str])
	joined_room.emit(world, room, name_str)

	# Direct scene node update fallback matching tutorial structure
	var main_node := get_node_or_null("/root/Main")
	if main_node:
		# Update UI Room label if present
		var room_label := main_node.get_node_or_null("HUD/RoomLabel") as Label
		if room_label and room != "":
			room_label.text = "Room: " + room + " | " + name_str

		var player_id := 0
		var network_manager := get_node_or_null("/root/NetworkManager")
		if network_manager != null:
			player_id = int(network_manager.get("_self_peer_int"))
		var local_player = main_node.get_player_node(player_id) if player_id != 0 and main_node.has_method("get_player_node") else null
		if local_player and local_player.has_method("set_player_name"):
			local_player.set_player_name(name_str)

func on_peer_joined(peer_id: int, peer_name: String) -> void:
	print("Remote peer %d joined as: %s" % [peer_id, peer_name])
	peer_joined.emit(peer_id, peer_name)

func on_peer_left(peer_id: int) -> void:
	print("Peer %d left" % peer_id)
	peer_left.emit(peer_id)

func on_join_error(reason: String) -> void:
	push_error("Join error: %s" % reason)
	join_failed.emit(reason)
