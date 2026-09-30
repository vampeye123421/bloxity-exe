extends Area3D
## Componente sicuro "Livello 2" -- vedi kill_brick.gd per il modello
## generale.
##
## Teletrasporta il giocatore locale su target_position quando entra
## nell'area. Deliberatamente un Vector3 e NON un NodePath: un NodePath
## configurabile dal creator potrebbe in teoria puntare fuori dalla propria
## scena (es. risalire verso i nodi core tramite un path relativo ben
## costruito). Un Vector3 è puro dato numerico -- non c'è alcun modo di
## codificarci "esci dalla tua sottoscena".

@export var target_position: Vector3 = Vector3.ZERO
@export var cooldown_seconds: float = 0.5 # evita teleport a raffica se le due aree si sovrappongono

var _cooldown_remaining: Dictionary = {} # body -> secondi rimanenti


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _process(delta: float) -> void:
	for body in _cooldown_remaining.keys():
		if not is_instance_valid(body):
			_cooldown_remaining.erase(body)
			continue
		_cooldown_remaining[body] -= delta
		if _cooldown_remaining[body] <= 0.0:
			_cooldown_remaining.erase(body)


func _on_body_entered(body: Node3D) -> void:
	if _cooldown_remaining.has(body):
		return
	if body.has_method("respawn_at"):
		body.respawn_at(target_position)
		_cooldown_remaining[body] = cooldown_seconds
