extends Node3D

const PLAYER_SCENE = preload("res://scenes/Player.tscn")

## Rete (30s) + istanziazione (20s) nel WorldLoader possono sommarsi fino a
## ~50s nel caso peggiore prima che world_load_failed arrivi. Diamo un buon
## margine extra qui: se a 60s non e' successo nulla, forziamo lo spawn.
const WORLD_LOAD_WATCHDOG_SEC := 60.0

var _spawned: Dictionary = {} # int id -> Player node
var _local_player_spawned := false
var _world_load_aborted := false # true dopo il primo hard-abort (evita doppio change_scene_to_file)


func _ready() -> void:
	var room_label := $HUD/RoomLabel
	if NetworkManager.current_room_id != "":
		room_label.text = "Room: " + NetworkManager.current_room_id
	else:
		room_label.text = "Local test (no network)"

	# Add procedural sky environment if missing so background isn't plain gray
	_ensure_environment()

	# Hand the HUD's chat log/input Controls to the ChatManager autoload so
	# it doesn't need to guess a scene path or poll for them.
	if get_node_or_null("/root/ChatManager"):
		ChatManager.register_ui($HUD/ChatLog, $HUD/ChatInput)

	var client = get_node_or_null("/root/GameJoinClient")
	if client:
		client.peer_joined.connect(_on_client_peer_joined)
		client.peer_left.connect(_on_peer_disconnected)

	# Avvia il caricamento del mondo (async: HTTP -> download -> SHA verify -> load)
	# Il player locale NON viene spawnato qui — aspetta _on_world_loaded o _on_world_load_failed
	_start_world_load(client)

	# Watchdog di sicurezza: WorldLoader ha gia' i suoi timeout interni
	# (rete + istanziazione), ma questo e' un secondo livello di difesa
	# lato client. Se per un qualsiasi motivo non ancora previsto ne'
	# world_loaded ne' world_load_failed arrivano mai, il client resta
	# bloccato per sempre sulla schermata grigia "Loading world…" perche'
	# il player locale (e quindi la camera) non spawna mai. Un timeout qui
	# e' indistinguibile da un world_load_failed "silenzioso" (es. un
	# passaggio di verifica che si e' impallato invece di fallire
	# esplicitamente) — quindi NON forziamo piu' uno spawn di fallback:
	# passiamo dallo stesso hard-abort di _on_world_load_failed, cosi' non
	# esiste nessun percorso che faccia proseguire la sessione con un mondo
	# non verificato.
	if client and get_node_or_null("/root/WorldLoader") and not client.world_id.is_empty():
		get_tree().create_timer(WORLD_LOAD_WATCHDOG_SEC).timeout.connect(
			func():
				if not _local_player_spawned:
					_on_world_load_failed("timeout dopo %ds (watchdog)" % WORLD_LOAD_WATCHDOG_SEC)
		)

	# Mostra "Loading world…" sulla HUD se c'e' un mondo da caricare
	if client and get_node_or_null("/root/WorldLoader") and not client.world_id.is_empty():
		room_label.text = "Loading world…"

	# Connessioni multiplayer — spawn remote players subito (sono solo capsule)
	if multiplayer.multiplayer_peer != null and multiplayer.get_unique_id() != 0:
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)

		if get_node_or_null("/root/NetworkManager"):
			get_node("/root/NetworkManager").joined_room.connect(_on_network_manager_joined_room)

		# Spawn remote players (gia' connessi prima che main.tscn caricasse)
		for id in multiplayer.get_peers():
			_spawn_player(id)
			if client and _spawned.has(id):
				var known_name: String = client.get_peer_name(id)
				if known_name != "":
					_spawned[id].set_player_name(known_name)

	# Se NON c'e' WorldLoader (es. test locale senza rete), spawna subito il player
	if not get_node_or_null("/root/WorldLoader"):
		_spawn_local_player(client)


func _spawn_local_player(client: Node) -> void:
	if _local_player_spawned:
		return
	_local_player_spawned = true

	# Determina il nostro peer ID (CRITICO per fix dello spettatore bug):
	# 1. NetworkManager._self_peer_int quando usiamo il matchmaker (WebSocket raw)
	# 2. multiplayer.get_unique_id() quando usiamo Godot ENet/WebRTC
	# 3. Fallback a 1 per test locale senza rete
	var my_id := 1
	var nm := get_node_or_null("/root/NetworkManager")
	if nm != null:
		var nm_id := int(nm.get("_self_peer_int"))
		if nm_id > 0:
			my_id = nm_id
	elif multiplayer.multiplayer_peer != null and multiplayer.get_unique_id() != 0:
		my_id = multiplayer.get_unique_id()

	_spawn_player(my_id)

	# Imposta nome display sul player locale
	if client and client.display_name != "" and _spawned.has(my_id):
		_spawned[my_id].set_player_name(client.display_name)


func _on_network_manager_joined_room(_room_id: String, _world_id: String) -> void:
	for id in multiplayer.get_peers():
		_spawn_player(id)


func _on_client_peer_joined(peer_id: int, peer_name: String) -> void:
	_spawn_player(peer_id)
	if _spawned.has(peer_id):
		_spawned[peer_id].set_player_name(peer_name)


## world_id arriva da GameJoinClient.world_id, fissato dal server al momento
## del join (mai scelto dal client/creator). Se manca (es. test locale senza
## rete, vedi il fallback _spawn_player(1) sopra) semplicemente non si carica
## nessun mondo esterno -- $WorldContent resta vuoto.
func _start_world_load(client: Node) -> void:
	if client == null or client.world_id.is_empty():
		return
	if not get_node_or_null("/root/WorldLoader"):
		return
	var loader := get_node("/root/WorldLoader")
	loader.world_load_progress.connect(_on_world_load_progress)
	loader.world_loaded.connect(_on_world_loaded)
	loader.world_load_failed.connect(_on_world_load_failed)
	loader.load_world(client.world_id)


func _on_world_load_progress(status: String) -> void:
	$HUD/RoomLabel.text = status


func _on_world_loaded(world_root: Node) -> void:
	# WorldContent e' l'UNICO punto di innesto per contenuto esterno --
	# rimane sibling di HUD/Camera/player, mai antenato/discendente, cosi' un
	# path relativo dentro la scena del creator non puo' risalire per
	# collisione di nomi nei sistemi core.
	$WorldContent.add_child(world_root)

	# Aspetta 3 frame di fisica per permettere al motore di registrare
	# i collision shape della scena appena caricata. Senza questa pausa,
	# il player spawna e inizia a cadere prima che il terreno esista.
	var tree := get_tree()
	if not tree:
		return
	await tree.physics_frame
	await tree.physics_frame
	await tree.physics_frame

	# Se il nodo e' stato rimosso dall'albero mentre aspettavamo, esci.
	if not is_inside_tree():
		return

	# MONDO CARICATO — ora spawna il player locale (non cadra' nel vuoto
	# perche' la geometria del mondo e' gia' stata registrata dalla fisica)
	var client = get_node_or_null("/root/GameJoinClient")
	_spawn_local_player(client)

	if NetworkManager.current_room_id != "":
		$HUD/RoomLabel.text = "Room: " + NetworkManager.current_room_id


## Hard-abort di sicurezza. NON deve MAI spawnare il player o continuare
## la sessione: un fallimento qui puo' significare checksum non
## corrispondente, manifest manomesso, o pack rifiutato — proseguire in
## silenzio nasconderebbe un tentativo di tampering al giocatore. Invece
## mostriamo un errore ben visibile e torniamo alla Lobby, cosi' nessun
## contenuto/pack non verificato arriva mai a essere giocato.
func _on_world_load_failed(reason: String) -> void:
	# Guardia anti doppia-esecuzione: puo' arrivare sia dal segnale
	# world_load_failed sia dal watchdog qui sopra (o entrambi in corsa
	# tra loro). Il primo che arriva vince; i successivi sono no-op cosi'
	# non proviamo a cambiare scena due volte.
	if _world_load_aborted:
		return
	_world_load_aborted = true

	push_error("[Bloxity][SECURITY] Caricamento mondo abortito: %s" % reason)

	var room_label := $HUD/RoomLabel
	room_label.text = "Impossibile caricare il mondo in sicurezza: " + reason
	room_label.modulate = Color("ff6b6b")

	# NIENTE spawn del player, NIENTE fallback locale: la sessione finisce
	# qui. Diamo un attimo perche' il messaggio sia leggibile prima di
	# tornare alla Lobby.
	var tree := get_tree()
	if tree == null:
		return
	await tree.create_timer(2.0).timeout
	if not is_inside_tree():
		return
	tree.change_scene_to_file("res://scenes/Lobby.tscn")


func _ensure_environment() -> void:
	var env_node: WorldEnvironment = get_node_or_null("WorldEnvironment")
	if env_node and env_node.environment == null:
		var env := Environment.new()
		env.background_mode = Environment.BG_SKY
		var sky := Sky.new()
		var sky_mat := ProceduralSkyMaterial.new()
		sky.sky_material = sky_mat
		env.sky = sky
		env_node.environment = env


func _on_peer_connected(id: int) -> void:
	_spawn_player(id)


func _on_peer_disconnected(id: int) -> void:
	if _spawned.has(id):
		_spawned[id].queue_free()
		_spawned.erase(id)


## Used by JoinClient._apply_remote_position() to find the capsule for a
## given peer int id without JoinClient needing to know about _spawned's
## internals or main.tscn's node layout.
func get_player_node(id: int) -> Node:
	return _spawned.get(id)


## Real peer ids here are deterministic hashes of the server's string id
## (see NetworkManager._string_id_to_int), NOT small sequential ints --
## so loaded .pck content must NOT assume a bounded range like 1..255 to
## discover connected players. Use this instead of guessing a range.
func get_active_peer_ids() -> Array:
	return _spawned.keys()


func _exit_tree() -> void:
	if get_node_or_null("/root/ChatManager"):
		ChatManager.unregister_ui()


func _spawn_player(id: int) -> void:
	if _spawned.has(id):
		return
	var p := PLAYER_SCENE.instantiate()
	# The RPCs in player.gd (_network_update_transform) are routed by NodePath,
	# so every peer needs this node at the exact same path for the same
	# logical player. Without an explicit name, Godot auto-names siblings by
	# local add order ("Player", "Player2", ...), which differs per client
	# since everyone spawns themselves first -- that mismatch is why remote
	# players never visibly moved/appeared correctly. Naming by peer id (the
	# same deterministic hash on every client) keeps the path identical.
	p.name = str(id)

	# Authority MUST be set before add_child(): add_child() fires the child's
	# _ready() synchronously, and player.gd's _ready() branches on
	# is_multiplayer_authority(). Setting authority after add_child() means
	# _ready() runs while the node still has Godot's default authority (peer
	# 1), so a local player whose real id isn't 1 sees is_multiplayer_authority()
	# return false at _ready() time -- e.g. the mouse-capture setup gets
	# silently skipped on first spawn.
	p.set_multiplayer_authority(id)
	add_child(p)
	# Camera3D.current is set by player.gd._ready() itself, gated on
	# is_multiplayer_authority() -- that's the single source of truth for
	# who owns the camera. Do NOT also set it here from a separately
	# computed is_local guess: a stale/racy comparison against
	# NetworkManager._self_peer_int on a later remote spawn (e.g. a friend
	# joining mid-session) can disagree with is_multiplayer_authority() and
	# steal the viewport camera onto a remote capsule.
	# Spawn su SpawnLocation se il mondo pubblicato ne ha uno (vedi
	# _resolve_spawn_transform), altrimenti fallback y=20 per dare al
	# player il tempo di atterrare gentilmente sulla geometria del mondo
	# senza una caduta lunghissima. Se il mondo ha il pavimento a y=0, a
	# gravita' predefinita (~9.8) il player impiega ~2 secondi ad
	# atterrare — abbastanza per far registrare i collision shape, non
	# cosi' tanto da sembrare rotto.
	var spawn_transform := _resolve_spawn_transform()
	p.position = spawn_transform[0]
	p.rotation.y = spawn_transform[1]
	if spawn_transform.size() > 2:
		var spawn_index := posmod(id, 8)
		var angle := TAU * float(spawn_index) / 8.0
		p.position += Vector3(cos(angle), 0.0, sin(angle)) * 1.25
	_spawned[id] = p


## Cerca un marker "SpawnLocation" nel mondo appena caricato (BluboxPublisher
## lo tagga nel gruppo "spawn_location" nel main.tscn esportato — vedi
## world_loader.gd/BluboxPublisher lato Studio) e ne usa la global_position/
## global_rotation.y ESATTA (solo +0.05 verticale, niente jitter orizzontale)
## invece del fallback hardcoded, cosi' il player spawna esattamente dove
## piazzato in editor. Se il mondo non ha nessun marker (o non e' ancora
## stato caricato), torna il vecchio punto di caduta casuale a y=20 cosi'
## il comportamento resta identico a prima per i mondi senza SpawnLocation.
## Ritorna [Vector3 position, float yaw].
func _resolve_spawn_transform() -> Array:
	var tree := get_tree()
	if tree:
		var markers := tree.get_nodes_in_group("spawn_location")
		if not markers.is_empty():
			var marker: Node3D = markers[0] as Node3D
			if marker != null and is_instance_valid(marker):
				# Nessun offset orizzontale: il ±1.0 di jitter usato prima
				# faceva scostare il player fino a un metro dal punto esatto
				# piazzato in editor ("leggermente disallineato" - il bug
				# segnalato). Solo un epsilon verticale minimo per evitare
				# z-fighting/incastro con la geometria proprio a filo del
				# marker, non un vero e proprio "lift". L'anti-stacking tra
				# piu' player va gestito altrove (es. spread deterministico
				# per id) se serve, non qui a scapito della precisione.
				const SPAWN_LOCATION_EPSILON := 0.05
				var exact_pos := marker.global_position + Vector3(0, SPAWN_LOCATION_EPSILON, 0)
				return [exact_pos, marker.global_rotation.y, true]
	# Fallback: nessun SpawnLocation nel mondo (o nessun mondo/WorldContent
	# ancora popolato) — comportamento originale.
	return [Vector3(randf_range(-3.0, 3.0), 20.0, 10.0 + randf_range(-3.0, 3.0)), 0.0]
