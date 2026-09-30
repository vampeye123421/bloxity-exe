extends Node
# Autoload. Must be registered AFTER NetworkManager in the autoload list,
# since it hands a token straight to it on startup.
#
# Bloxity's client is launch-only: the website is what lets you log in, pick
# a friend, or pick a game. When you click "Play" on the site, it opens a
# bloxity://join?token=<one-time-token> link, the OS launches (or focuses)
# this client with that URL as a command-line argument, and this script
# reads it and immediately hands the token to NetworkManager.
#
# There is deliberately no room code / world id in the link itself — only an
# opaque, short-lived, single-use token. The server is the only thing that
# resolves that token to an actual room, which keeps a malicious or copied
# link from being able to direct a client anywhere the server didn't
# authorize.
#
# NOTE (packaging, not code): registering the bloxity:// URI scheme with the
# OS so it forwards links to this executable is done at install time
# (Windows registry / macOS Info.plist CFBundleURLTypes / Linux .desktop
# MimeType=x-scheme-handler/bloxity), not here.
#
# NOTE: if Bloxity is already running when a second bloxity:// link is
# clicked, the OS launches a second process. On macOS (unlike Windows) that
# second process does NOT receive the link as a launch argument at all, so
# checking OS.get_cmdline_args() alone leaves it stuck on an empty Lobby
# screen forever. The instance-lock handling in _ready() below forwards the
# token to the already-running instance over a localhost socket instead.

const INSTANCE_LOCK_PORT := 38217
const CLIPBOARD_SESSION_PREFIX := "BLOXITY_"

var had_token := false
var _lock_server: TCPServer
var _forward_peers: Array[StreamPeerTCP] = []

## SessionId estratto dalla clipboard su macOS (o da cmdline su Windows).
## Pubblico cosi' JoinClient.gd puo' leggerlo SENZA dover rileggere la
## clipboard (che potrebbe essere stata sovrascritta dall'utente tra
## l'avvio del client e la chiamata a start_join()).
var session_id: String = ""

func _ready() -> void:
	var all_args := OS.get_cmdline_args()
	all_args.append_array(OS.get_cmdline_user_args())
	var token := _extract_token(all_args)
	if token.is_empty():
		# macOS never delivers bloxity:// links via cmdline args (Apple
		# Events only) — without this, had_token stays false on every
		# macOS launch and _start_game_flow() in lobby.gd never even calls
		# GameJoinClient.start_join(), regardless of what fallback logic
		# JoinClient.gd itself has. This is the actual gate that matters.
		token = _extract_session_id_from_clipboard()
		# Salva il sessionId per JoinClient.gd -- se l'utente copia altro
		# nella clipboard tra ora e start_join(), JoinClient puo' comunque
		# leggere session_id senza dover rileggere la clipboard.
		if not token.is_empty():
			session_id = token
	if token != "":
		had_token = true

	if not _claim_instance_lock():
		# Another instance already owns the lock. Hand it our token (if any)
		# and get out of the way instead of sitting on a blank Lobby forever.
		if token != "":
			_forward_token_and_quit(token)
		else:
			get_tree().quit()
		return

	# NOTE: we deliberately do NOT call NetworkManager.join_with_token(token)
	# here. GameJoinClient (an autoload registered after this one) reads the
	# exact same cmdline token itself, but only opens its connection when
	# Lobby calls its start_join() after the auto-updater finishes -- see
	# JoinClient.gd:start_join(). Calling join_with_token() here too used to
	# fire a second, fully independent join attempt against the SAME
	# single-use token -- a race where whichever socket finished its
	# handshake first "won" the token and the other got a server-side
	# rejection (or, worse, a duplicate room join). GameJoinClient handles
	# the fresh-launch-with-token case entirely on its own; NetworkManager's
	# own join_with_token() flow is still needed below for the *forwarded*
	# token case (second instance launched while this one's already
	# running), since GameJoinClient's _ready() has already run without a
	# token by the time that forward arrives.


func _process(_delta: float) -> void:
	if _lock_server == null:
		return
	while _lock_server.is_connection_available():
		_forward_peers.append(_lock_server.take_connection())

	var i := _forward_peers.size() - 1
	while i >= 0:
		var peer := _forward_peers[i]
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED and peer.get_available_bytes() > 0:
			var forwarded_token := peer.get_utf8_string(peer.get_available_bytes()).strip_edges()
			_forward_peers.remove_at(i)
			if forwarded_token != "":
				var is_direct_token := forwarded_token.begins_with("DIRECT_TOKEN:")
				if is_direct_token:
					forwarded_token = forwarded_token.trim_prefix("DIRECT_TOKEN:")
				NetworkManager.join_with_session_or_token(forwarded_token, is_direct_token)
		elif peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_forward_peers.remove_at(i)
		i -= 1


func _claim_instance_lock() -> bool:
	var server := TCPServer.new()
	if server.listen(INSTANCE_LOCK_PORT, "127.0.0.1") == OK:
		_lock_server = server
		return true
	return false


func _forward_token_and_quit(token: String) -> void:
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host("127.0.0.1", INSTANCE_LOCK_PORT) == OK:
		var deadline := Time.get_ticks_msec() + 2000
		while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() < deadline:
			peer.poll()
			OS.delay_msec(10)
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			peer.put_utf8_string(token)
			peer.poll()
			OS.delay_msec(100) # let the send flush before the process exits
	get_tree().quit()


func _extract_token(args: PackedStringArray) -> String:
	for arg in args:
		if arg.begins_with("bloxity://"):
			var session_id := _token_from_uri(arg)
			if session_id != "":
				return session_id
		elif arg.begins_with("--sessionId="):
			return arg.replace("--sessionId=", "").uri_decode()
		elif arg.begins_with("--token="): # dev override, bypasses the claim exchange entirely
			return "DIRECT_TOKEN:" + arg.replace("--token=", "").uri_decode()
	return ""


func _token_from_uri(uri: String) -> String:
	var query_start := uri.find("?")
	if query_start == -1:
		return ""
	var query := uri.substr(query_start + 1)
	# Prefer sessionId (the relay flow) but fall back to a direct token if
	# the website's depositToken() failed and it linked straight to
	# bloxity://join?token=... instead — otherwise had_token stays false
	# for that link and lobby.gd never even calls GameJoinClient.start_join(),
	# which is what JoinClient.gd's own token fallback needs to run at all.
	var found_token := ""
	for pair in query.split("&"):
		var kv := pair.split("=")
		if kv.size() != 2:
			continue
		if kv[0] == "sessionId":
			return kv[1].uri_decode()
		elif kv[0] == "token":
			found_token = kv[1].uri_decode()
	return found_token


## macOS-only side channel: the website writes "BLOXITY_<sessionId>" to the
## clipboard right before launching the bloxity:// link, since macOS never
## delivers the link itself to this process as a cmdline argument. Mirrors
## JoinClient.gd's copy of this same check.
func _extract_session_id_from_clipboard() -> String:
	if not DisplayServer.clipboard_has():
		return ""
	var clip := DisplayServer.clipboard_get()
	if clip.begins_with(CLIPBOARD_SESSION_PREFIX):
		print("[Bloxity] launch_handler got sessionId from clipboard")
		return clip.trim_prefix(CLIPBOARD_SESSION_PREFIX)
	return ""
