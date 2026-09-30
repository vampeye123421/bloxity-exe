extends Node

## Global text chat: "Enter" (or T) opens the input box, Enter again sends,
## Escape cancels. Rate limit + profanity filter here are a CLIENT-SIDE
## first line of defense only -- per the backend security audit, the
## matchmaker's "relay" channel broadcasts whatever a client sends without
## validating message contents, so a modified client can bypass both of
## these checks entirely and send anything, as fast as it wants, on the
## "chat" channel. Real anti-spam/anti-abuse enforcement belongs
## server-side too; this is not a substitute for that.

signal chat_message_received(peer_id: int, sender_name: String, text: String)

const MAX_MESSAGE_LENGTH := 200
const SEND_COOLDOWN_SEC := 1.2
const LOG_MAX_LINES := 60

# Placeholder list -- replace/extend with a real word list as needed.
# Simple case-insensitive substring match (no word-boundary/leetspeak
# handling) -- fine for a v1 client-side filter, not a robust anti-abuse
# system. Revisit if false positives (e.g. a bad word as a substring of an
# innocent word) become an issue.
const _PROFANITY_WORDS := [
	"badword1", "badword2", "badword3",
]

var _log: RichTextLabel = null
var _input_box: LineEdit = null
var _log_lines: Array[String] = []
var _last_send_ms := 0
var _chat_open := false


func _ready() -> void:
	var gjc := get_node_or_null("/root/GameJoinClient")
	if gjc and gjc.has_signal("relay_received"):
		gjc.relay_received.connect(_on_relay_received)


## Called by main.gd once its HUD chat nodes exist, so this autoload never
## has to guess a scene path or poll for them every frame.
func register_ui(log_label: RichTextLabel, input_box: LineEdit) -> void:
	_log = log_label
	_input_box = input_box
	_log_lines.clear()
	if _log:
		_log.text = ""
	if _input_box:
		_input_box.visible = false
		if not _input_box.text_submitted.is_connected(_on_input_submitted):
			_input_box.text_submitted.connect(_on_input_submitted)


## Called by main.gd on exit/scene teardown so this autoload doesn't hold
## stale references to freed Control nodes across a scene change.
func unregister_ui() -> void:
	_log = null
	_input_box = null
	_chat_open = false


func is_chat_active() -> bool:
	return _chat_open


func _unhandled_input(event: InputEvent) -> void:
	if _input_box == null:
		return
	if not _chat_open:
		if event is InputEventKey and event.pressed and not event.echo \
				and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER or event.keycode == KEY_T):
			_open_input()
			get_viewport().set_input_as_handled()
		return
	# Chat is open: Escape cancels. Enter-to-send is handled by the
	# LineEdit's own text_submitted signal, not here.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_close_input()
		get_viewport().set_input_as_handled()


func _open_input() -> void:
	if _input_box == null:
		return
	_chat_open = true
	_input_box.visible = true
	_input_box.text = ""
	_input_box.grab_focus()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_input() -> void:
	if _input_box == null:
		return
	_chat_open = false
	_input_box.visible = false
	_input_box.text = ""
	_input_box.release_focus()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_input_submitted(text: String) -> void:
	_close_input()
	_try_send(text)


func _try_send(raw_text: String) -> void:
	var text := raw_text.strip_edges()
	if text.is_empty():
		return
	if text.length() > MAX_MESSAGE_LENGTH:
		text = text.substr(0, MAX_MESSAGE_LENGTH)

	var now := Time.get_ticks_msec()
	if now - _last_send_ms < int(SEND_COOLDOWN_SEC * 1000):
		return # basic spam guard -- silently drop rather than queue

	text = _filter_profanity(text)

	var gjc := get_node_or_null("/root/GameJoinClient")
	if gjc == null or not gjc.has_method("send_relay"):
		return
	gjc.send_relay("chat", {"text": text})
	_last_send_ms = now

	# The server broadcasts to everyone EXCEPT the sender (see
	# broadcastToRoom's exceptPeerId), so without a local echo the sender
	# would never see their own message appear in the log or bubble.
	var self_id := _local_peer_id()
	var self_name := "You"
	var dn = gjc.get("display_name")
	if typeof(dn) == TYPE_STRING and dn != "":
		self_name = dn
	_display_message(self_id, self_name, text)


func _on_relay_received(channel: String, data: Dictionary, from_peer_id: int) -> void:
	if channel != "chat":
		return
	var text = data.get("text", "")
	if typeof(text) != TYPE_STRING or text.is_empty():
		return
	if text.length() > MAX_MESSAGE_LENGTH:
		text = text.substr(0, MAX_MESSAGE_LENGTH) # defensive -- a modified client could ignore our own length cap
	var gjc := get_node_or_null("/root/GameJoinClient")
	var sender_name := "Player"
	if gjc and gjc.has_method("get_peer_name"):
		var known: String = gjc.get_peer_name(from_peer_id)
		if known != "":
			sender_name = known
	_display_message(from_peer_id, sender_name, text)


func _display_message(peer_id: int, sender_name: String, text: String) -> void:
	chat_message_received.emit(peer_id, sender_name, text)
	_append_to_log(sender_name, text)
	_show_bubble_for(peer_id, text)


func _append_to_log(sender_name: String, text: String) -> void:
	if _log == null:
		return
	_log_lines.append("[b]%s:[/b] %s" % [sender_name.xml_escape(), text.xml_escape()])
	if _log_lines.size() > LOG_MAX_LINES:
		_log_lines = _log_lines.slice(_log_lines.size() - LOG_MAX_LINES, _log_lines.size())
	_log.text = "\n".join(_log_lines)
	_log.scroll_to_line(_log_lines.size() - 1)


func _show_bubble_for(peer_id: int, text: String) -> void:
	var scene := get_tree().current_scene
	if scene == null or not scene.has_method("get_player_node"):
		return
	var player = scene.get_player_node(peer_id)
	if player and player.has_method("show_chat_bubble"):
		player.show_chat_bubble(text)


func _local_peer_id() -> int:
	var nm := get_node_or_null("/root/NetworkManager")
	if nm == null:
		return 0
	var v = nm.get("_self_peer_int")
	if typeof(v) == TYPE_INT:
		return v
	return 0


func _filter_profanity(text: String) -> String:
	var result := text
	for word in _PROFANITY_WORDS:
		if word.is_empty():
			continue
		result = _replace_case_insensitive(result, word, "*".repeat(word.length()))
	return result


func _replace_case_insensitive(source: String, target: String, replacement: String) -> String:
	var lower_source := source.to_lower()
	var lower_target := target.to_lower()
	var out := ""
	var i := 0
	while i < source.length():
		if lower_source.substr(i, lower_target.length()) == lower_target:
			out += replacement
			i += lower_target.length()
		else:
			out += source[i]
			i += 1
	return out
