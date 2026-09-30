extends Node
## Autoload singleton. Holds the live "Game Settings" authored in Blubox
## Studio (gravity, camera mode, starter-character physics) for whatever
## world is currently loaded, and applies sane defaults when a world has
## none (older packs, or local test scenes with no WorldLoader).
##
## Populated by WorldLoader right after a world .pck is mounted, from
## res://user_content/<world_id>/game_settings.json if present (see
## world_loader.gd's _load_game_settings()). Consumed by player.gd at
## spawn time to apply gravity/camera/physics to the local player.
##
## Mirrors the schema written by Blubox Studio's
## blubox_game_settings_modal.gd / BluboxStudioIDE.GAME_SETTINGS, kept
## permissive (Dictionary.get with fallbacks everywhere) so a client built
## against a newer/older schema version doesn't hard-fail on a mismatch.

signal game_settings_loaded(settings: Dictionary)

const DEFAULTS := {
	"gravity": 9.8,
	"camera_mode": "first_person", # "first_person" | "third_person"
	"starter_character": {
		"mass": 1.0,
		"move_speed": 5.0,
		"jump_force": 4.5,
		"allow_double_jump": false,
	},
}

var current: Dictionary = DEFAULTS.duplicate(true)


## Called by WorldLoader once per world load, BEFORE world_loaded is
## emitted to main.gd, so the local player picks up the right settings on
## its very first _ready(). Resets to defaults first so a world that omits
## a field (or the whole file) can't accidentally inherit values left over
## from a previously-loaded world in the same client session.
func apply_from_json_string(json_text: String) -> bool:
	reset_to_defaults()
	if json_text.is_empty():
		game_settings_loaded.emit(current)
		return false

	var json := JSON.new()
	if json.parse(json_text) != OK:
		push_warning("[Bloxity][GameSettingsManager] game_settings.json malformato, uso i default")
		game_settings_loaded.emit(current)
		return false

	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("[Bloxity][GameSettingsManager] game_settings.json non e' un oggetto, uso i default")
		game_settings_loaded.emit(current)
		return false

	_merge_into_current(data)
	game_settings_loaded.emit(current)
	return true


func reset_to_defaults() -> void:
	current = DEFAULTS.duplicate(true)


func get_gravity() -> float:
	return float(current.get("gravity", DEFAULTS.gravity))


func get_camera_mode() -> String:
	var mode := String(current.get("camera_mode", DEFAULTS.camera_mode))
	if mode != "first_person" and mode != "third_person":
		return DEFAULTS.camera_mode
	return mode


func get_starter_character() -> Dictionary:
	var sc = current.get("starter_character", {})
	if typeof(sc) != TYPE_DICTIONARY:
		return DEFAULTS.starter_character.duplicate(true)
	return sc


func _merge_into_current(data: Dictionary) -> void:
	if data.has("gravity"):
		var g = data.get("gravity")
		if (typeof(g) == TYPE_FLOAT or typeof(g) == TYPE_INT) and is_finite(float(g)) and float(g) >= 0.0 and float(g) <= 100.0:
			current["gravity"] = float(g)

	if data.has("camera_mode"):
		var mode := String(data.get("camera_mode"))
		if mode == "first_person" or mode == "third_person":
			current["camera_mode"] = mode

	if data.has("starter_character") and typeof(data.get("starter_character")) == TYPE_DICTIONARY:
		var src: Dictionary = data.get("starter_character")
		var dst: Dictionary = current["starter_character"]
		for key in ["mass", "move_speed", "jump_force"]:
			if src.has(key):
				var v = src.get(key)
				if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v)):
					var min_value := 0.01 if key == "mass" else 0.0
					if float(v) < min_value or float(v) > 100.0:
						continue
					dst[key] = float(v)
		if src.has("allow_double_jump"):
			dst["allow_double_jump"] = bool(src.get("allow_double_jump"))
		current["starter_character"] = dst
