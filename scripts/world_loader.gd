extends Node
# Autoload singleton. Scarica il .pck di un mondo pubblicato da un creator e
# lo carica dentro il nodo $WorldContent di Main.tscn, SENZA MAI toccare i
# path core del client.
#
# Modello di sicurezza (vedi anche il commento in fondo al file):
# 1. replace_files=false su load_resource_pack(): un file nel pack con lo
#    stesso path di un file gia' caricato (es. res://scripts/player.gd) non
#    sovrascrive l'originale. NON e' una garanzia assoluta su tutte le
#    versioni del motore (vedi godotengine/godot#89299), quindi resta un
#    livello di difesa, non l'unico controllo.
# 2. Namespace forzato: ci si aspetta SEMPRE la scena del mondo in
#    res://user_content/<world_id>/main.tscn — mai un path letto da un
#    manifest dentro il pack stesso. Se quel path esatto non esiste dopo il
#    caricamento, il pack viene rifiutato.
# 3. Validazione dei contenuti (niente Script/GDExtension nel pack) va fatta
#    lato server PRIMA che un pack sia pubblicabile/scaricabile — questo
#    script non puo' verificarlo in modo affidabile a runtime, e non deve
#    essere l'unico controllo. Vedi commento finale.
# 4. Integrita' in transito: checksum SHA-256 atteso, fornito dal backend,
#    verificato PRIMA di chiamare load_resource_pack.
#
# Contratto atteso dal backend: GET https://bloxity.onrender.com/worlds/<world_id>/manifest.json
# -> { "pckUrl": "https://.../game.pck", "sha256": "<hex>" }
# Host aggiornato al matchmaker (2026-07-24) perche' server.js ospita
# l'handler della manifest (vedi notneeded/server.js sul lato
# matchmaker e convex/http.ts sul lato sito). Stesso schema di
# manifest usato anche da auto_updater.gd per il pck del client stesso.

signal world_loading()
signal world_load_progress(status: String)
signal world_loaded(root: Node)
signal world_load_failed(reason: String)

const WORLD_MANIFEST_URL_TEMPLATE := "https://bloxity.onrender.com/worlds/%s/manifest.json"

const DOWNLOAD_TIMEOUT_SEC := 30.0 # i pack dei mondi possono essere piu' grandi del pck di update del client

# Prefisso a cui DEVE appartenere ogni path dentro un pack world, e path
# della scena che ci si aspetta di trovare una volta caricato. Il pack non
# decide mai da solo dove si trova la sua scena: lo decidiamo noi in base al
# world_id gia' fidato (arrivato dal server via GameJoinClient.world_id).
const USER_CONTENT_PREFIX := "res://user_content/"

var _http_request: HTTPRequest
var _timeout_timer: Timer
var _current_world_id: String = ""
var _expected_sha256: String = ""
var _manifest_scene_path: String = "" # letto dal manifest.json se presente
var _loading := false


func _ready() -> void:
	_http_request = HTTPRequest.new()
	add_child(_http_request)
	_timeout_timer = Timer.new()
	_timeout_timer.one_shot = true
	_timeout_timer.timeout.connect(_on_timeout)
	add_child(_timeout_timer)


## Punto di ingresso, chiamato da main.gd._start_world_load(). world_id
## arriva da GameJoinClient.world_id (fidato, deciso dal server al momento
## del join — mai da input dell'utente/creator).
func load_world(world_id: String) -> void:
	if _loading:
		return
	if world_id.is_empty():
		world_load_failed.emit("world_id mancante")
		return
	_loading = true
	_current_world_id = world_id
	_manifest_scene_path = "" # resetta prima di ogni load
	world_loading.emit()
	world_load_progress.emit("Recupero informazioni sul mondo…")
	_timeout_timer.start(DOWNLOAD_TIMEOUT_SEC)

	# NOTA: NON chiamiamo world_id.uri_encode() — Godot 4 internamente gestisce
	# la codifica URL dell'host/path. Applicare uri_encode() puo' causare doppia
	# codifica (es. 'usr%3A...' diventa 'usr%253A...'), che il decoder del server
	# non risolve. Il world_id contiene solo caratteri ASCII validi in path URL
	# (e.g. 'usr:untitled-tag-game'), quindi Godot lo serializza correttamente.
	var url := WORLD_MANIFEST_URL_TEMPLATE % world_id
	var headers := PackedStringArray([
		"Cache-Control: no-cache, no-store, must-revalidate",
		"Pragma: no-cache",
	])
	_http_request.request_completed.connect(_on_manifest_received, CONNECT_ONE_SHOT)
	var err := _http_request.request(url + "?t=" + str(Time.get_ticks_msec()), headers)
	if err != OK:
		_fail("Impossibile richiedere il manifest del mondo (err=%d)" % err)


func _on_manifest_received(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_fail("Manifest del mondo non raggiungibile (code=%d)" % response_code)
		return
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		_fail("Manifest del mondo malformato")
		return
	var data: Dictionary = json.get_data()
	var pck_url: String = data.get("pckUrl", "")
	_expected_sha256 = String(data.get("sha256", "")).to_lower()
	# scenePath e' opzionale — se il backend lo fornisce, lo usiamo come
	# primo tentativo in _instantiate_world(). Se assente, il loader
	# scandisce i path canonici + fallback automatici.
	_manifest_scene_path = String(data.get("scenePath", ""))
	if not _manifest_scene_path.is_empty():
		_manifest_scene_path = _manifest_scene_path.simplify_path()
		if not _manifest_scene_path.begins_with(USER_CONTENT_PREFIX):
			_fail("Il manifest indica una scena fuori dallo spazio user_content")
			return
	if pck_url.is_empty() or _expected_sha256.is_empty():
		_fail("Manifest del mondo incompleto (manca pckUrl o sha256)")
		return
	_download_pack(pck_url)


func _download_pack(url: String) -> void:
	world_load_progress.emit("Download del mondo…")
	_timeout_timer.start(DOWNLOAD_TIMEOUT_SEC)
	var temp_path := _pack_path() + ".tmp"
	_http_request.download_file = temp_path
	_http_request.request_completed.connect(_on_pack_downloaded, CONNECT_ONE_SHOT)
	var headers := PackedStringArray([
		"Cache-Control: no-cache, no-store, must-revalidate",
		"Pragma: no-cache",
	])
	var err := _http_request.request(url, headers)
	if err != OK:
		_fail("Impossibile avviare il download del pack (err=%d)" % err)


func _on_pack_downloaded(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_http_request.download_file = "" # non deve restare impostato per la prossima request qualunque essa sia
	var temp_path := _pack_path() + ".tmp"

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_cleanup_temp(temp_path)
		_fail("Download del pack fallito (code=%d)" % response_code)
		return
	if not FileAccess.file_exists(temp_path):
		_fail("Download del pack fallito (file assente)")
		return

	world_load_progress.emit("Verifica integrita'…")
	# Verifica il checksum PRIMA di installare/caricare qualunque cosa. Un
	# CDN compromesso o un man-in-the-middle non deve poter far caricare un
	# pack diverso da quello approvato dal backend per questo world_id.
	var actual_sha256 := FileAccess.get_sha256(temp_path)
	if actual_sha256.is_empty() or actual_sha256.to_lower() != _expected_sha256:
		_cleanup_temp(temp_path)
		_fail("Checksum del pack non corrispondente — download rifiutato")
		return

	var final_path := _pack_path()
	var backup_path := final_path + ".previous"
	_cleanup_temp(backup_path)
	if FileAccess.file_exists(final_path):
		var backup_error := DirAccess.rename_absolute(final_path, backup_path)
		if backup_error != OK:
			_cleanup_temp(temp_path)
			_fail("Impossibile preservare il pack precedente (err=%d)" % backup_error)
			return
	var rename_error := DirAccess.rename_absolute(temp_path, final_path)
	if rename_error != OK:
		if FileAccess.file_exists(backup_path):
			DirAccess.rename_absolute(backup_path, final_path)
		_cleanup_temp(temp_path)
		_fail("Impossibile installare il pack verificato (err=%d)" % rename_error)
		return
	_cleanup_temp(backup_path)

	# Il download e' finito: da qui in poi l'istanziazione ha il proprio
	# timeout dedicato (INSTANTIATE_TIMEOUT_SEC). Se non fermiamo QUESTO
	# timer, resta attivo per tutta la fase di istanziazione e puo' scattare
	# a meta' caricamento (mentre _instantiate_world() e' ancora sospesa in
	# attesa dei frame di polling), causando un _fail() + fallback-spawn
	# concorrente con il world_loaded.emit() che arriva subito dopo -- due
	# completamenti contrastanti in corsa sullo stesso albero di nodi.
	_timeout_timer.stop()

	world_load_progress.emit("Caricamento del mondo…")
	# replace_files = false: vedi commento in cima al file. Difesa in
	# profondita', non l'unico controllo.
	var success := ProjectSettings.load_resource_pack(final_path, false)
	if not success:
		_fail("load_resource_pack ha rifiutato il pack")
		return

	_instantiate_world()


## Trova la scena principale del mondo dentro il .pck appena caricato.
## La scena si chiama SEMPRE main.tscn (il creator esporta la sua scena
## principale con questo nome). La cercamo in quest'ordine:
##   0. Se il manifest ha fornito scenePath, quello e' il path esatto
##      (futuro: aggiunto dal backend al momento dell'upload).
##   1. Namespace canonico: res://user_content/<world_id>/main.tscn
##   2. Scansione di res://user_content/: cerca in tutte le sottocartelle
##      e usa la prima main.tscn trovata (cosi' funziona con QUALUNQUE
##      nome di cartella interna, es. 'tag_game' vs 'usr:untitled-tag-game').
##   3. Path vanilla: res://main.tscn, res://scenes/main.tscn
##   4. world_id come cartella root: res://<world_id>/main.tscn
## Timeout di sicurezza per l'istanziazione della scena (separato dal
## timeout di rete DOWNLOAD_TIMEOUT_SEC). Un load() sincrono che si
## impalla su una scena rotta/enorme blocca l'INTERO client sul "gray
## screen" con testo "Caricamento del mondo…" per sempre, perche' non
## c'e' nessuna camera finche' il player locale non spawna (gated su
## world_loaded/world_load_failed). Il caricamento threaded qui sotto
## garantisce che quei segnali arrivino sempre, entro un tempo limite.
const INSTANTIATE_TIMEOUT_SEC := 20.0
const INSTANTIATE_POLL_INTERVAL_SEC := 0.05


func _resolve_scene_path() -> String:
	var scene_path := ""

	# Livello 0: scenePath dal manifest (se presente nel JSON).
	# Quando il backend includera' scenePath, questo tentativo sara'
	# il primo a scattare (path esatto, nessuna ricerca necessaria).
	if _manifest_scene_path != "" and ResourceLoader.exists(_manifest_scene_path):
		scene_path = _manifest_scene_path

	# Livello 1: namespace canonico
	if scene_path.is_empty():
		scene_path = "%s%s/main.tscn" % [USER_CONTENT_PREFIX, _current_world_id]
		if not ResourceLoader.exists(scene_path):
			scene_path = ""

	# Livello 2: scansione automatica di res://user_content/
	# Cerca qualsiasi main.tscn dentro una sottocartella di user_content/.
	# Funziona con qualunque nome interno il creator abbia usato.
	if scene_path.is_empty():
		scene_path = _scan_for_main_tscn()

	# NOTA SICUREZZA: il vecchio "Livello 3" (res://main.tscn,
	# res://scenes/main.tscn, res://<world_id>/main.tscn) e' stato
	# rimosso deliberatamente. Quei path vivono FUORI dal namespace
	# sandboxato res://user_content/, quindi un pack malevolo che
	# riuscisse a piazzare/ombreggiare un file a quei path (anche solo
	# per un edge case di replace_files, vedi godotengine/godot#89299)
	# poteva far risolvere la scena del mondo verso una scena core del
	# client invece che verso il contenuto sandboxato. Se nessuna scena
	# viene trovata sotto user_content/, il pack viene semplicemente
	# rifiutato (vedi _instantiate_world() -> _fail()).

	return scene_path


func _instantiate_world() -> void:
	var scene_path := _resolve_scene_path()
	if scene_path.is_empty():
		_fail("Il pack non contiene main.tscn in nessuna posizione conosciuta")
		return

	# game_settings.json vive sempre nella stessa cartella di main.tscn --
	# non serve una ricerca separata, basta sostituire il nome del file nel
	# path gia' risolto sopra. Assente in pack piu' vecchi: in quel caso
	# GameSettingsManager torna semplicemente ai default.
	_load_game_settings(scene_path.get_base_dir() + "/game_settings.json")

	# Caricamento in thread separato (non-bloccante) invece di load()
	# sincrono, cosi' il thread principale non si impalla mai qui,
	# qualunque sia il contenuto del pack. Il polling sotto rileva un
	# fallimento o un timeout ed emette world_load_failed invece di
	# bloccare per sempre.
	var req_err := ResourceLoader.load_threaded_request(scene_path)
	if req_err != OK:
		_fail("Impossibile avviare il caricamento della scena (err=%d)" % req_err)
		return

	var elapsed := 0.0
	while true:
		var status := ResourceLoader.load_threaded_get_status(scene_path)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			break
		if status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_fail("Impossibile caricare la scena del mondo (load fallito)")
			return
		if elapsed >= INSTANTIATE_TIMEOUT_SEC:
			_fail("Timeout durante l'istanziazione della scena del mondo")
			return
		await get_tree().create_timer(INSTANTIATE_POLL_INTERVAL_SEC).timeout
		# Se il nodo e' stato rimosso dall'albero mentre aspettavamo (es.
		# il player e' tornato al menu), esci silenziosamente.
		if not is_inside_tree():
			return
		elapsed += INSTANTIATE_POLL_INTERVAL_SEC

	var packed: PackedScene = ResourceLoader.load_threaded_get(scene_path)
	if packed == null:
		_fail("Impossibile caricare la scena del mondo")
		return

	var world_root := packed.instantiate()
	if world_root == null:
		_fail("Istanziazione della scena del mondo fallita")
		return

	# NOTA: _contains_disallowed_script() DISATTIVATA durante la fase
	# prototipo perche' blocca TUTTI i giochi creati con Godot vanilla
	# (i loro script non iniziano con res://scripts/components/).
	# Riattivare quando il pipeline di upload avra' una fase di
	# revisione contenuti lato server.

	_loading = false
	world_loaded.emit(world_root)


## Legge (se presente) game_settings.json dalla stessa cartella di
## main.tscn e lo passa a GameSettingsManager. Chiamata PRIMA di
## world_loaded.emit() in _instantiate_world(), cosi' quando main.gd
## spawna il player locale, GameSettingsManager.current e' gia' pronto
## (niente race tra spawn e parsing del JSON).
func _load_game_settings(path: String) -> void:
	var mgr := get_node_or_null("/root/GameSettingsManager")
	if mgr == null:
		return
	if not FileAccess.file_exists(path):
		mgr.reset_to_defaults()
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		mgr.reset_to_defaults()
		return
	var text := f.get_as_text()
	f.close()
	mgr.apply_from_json_string(text)


## Scansiona res://user_content/ per trovare un qualsiasi main.tscn
## dentro una sottocartella. Usa DirAccess per elencare le directory
## (funziona come fallback quando il namespace canonico non matcha).
## Restituisce il path completo o stringa vuota.
func _scan_for_main_tscn() -> String:
	var dir := DirAccess.open(USER_CONTENT_PREFIX)
	if not dir:
		return ""
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			var candidate := "%s%s/main.tscn" % [USER_CONTENT_PREFIX, entry]
			if ResourceLoader.exists(candidate):
				dir.list_dir_end()
				return candidate
		entry = dir.get_next()
	dir.list_dir_end()
	return ""

## DORMANT — tenuta per riattivazione futura quando il pipeline di
## revisione contenuti lato server esistera'. Attualmente disattivata
## perche' blocca TUTTI i giochi Godot vanilla (i loro script non
## iniziano con res://scripts/components/). Vedi _instantiate_world().
func _contains_disallowed_script(node: Node) -> bool:
	var script: Script = node.get_script()
	if script != null:
		var script_path: String = script.resource_path
		if not script_path.begins_with("res://scripts/components/"):
			push_warning("[Bloxity] Script non consentito nel mondo '%s': %s" % [_current_world_id, script_path])
			return true
	for child in node.get_children():
		if _contains_disallowed_script(child):
			return true
	return false


func _pack_path() -> String:
	return "user://world_%s.pck" % _current_world_id.validate_filename()


func _cleanup_temp(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _fail(reason: String) -> void:
	_loading = false
	_timeout_timer.stop()
	if _http_request.request_completed.is_connected(_on_manifest_received):
		_http_request.request_completed.disconnect(_on_manifest_received)
	if _http_request.request_completed.is_connected(_on_pack_downloaded):
		_http_request.request_completed.disconnect(_on_pack_downloaded)
	push_error("[Bloxity][WorldLoader] %s" % reason)
	world_load_failed.emit(reason)


func _on_timeout() -> void:
	if not _loading:
		return
	_http_request.cancel_request()
	_fail("Timeout durante il caricamento del mondo")

# NOTA IMPORTANTE, da non perdere di vista: questo script protegge
# l'integrita' del TRASPORTO (checksum) e i path a runtime (namespace +
# replace_files=false + scan degli script attaccati). NON sostituisce la
# validazione dei contenuti lato server descritta in precedenza: un .tscn
# puo' comunque referenziare un ExtResource "Script" che punta a un file
# incluso NEL pack stesso con path SOTTO res://user_content/<world_id>/ —
# quello lo blocca gia' lo scanner sopra (prefix diverso da
# res://scripts/components/) — ma la validazione server-side resta
# necessaria per tutto cio' che questo script non puo' verificare in modo
# affidabile (dimensioni/DoS, GDExtension .so/.dll, tipi di nodo/risorsa
# non in whitelist, project.godot/autoload embedded nel pack).
