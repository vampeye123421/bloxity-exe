extends AnimatableBody3D
## Componente sicuro "Livello 2" -- vedi kill_brick.gd per il modello
## generale (i creator configurano solo le @export, il codice è sempre
## quello del client).
##
## Va avanti e indietro tra point_a e point_b. Deliberatamente NON simulata
## via velocity/fisica integrata per-client: la posizione è una funzione
## pura di Time.get_ticks_msec(), quindi ogni client la calcola in modo
## identico senza bisogno di alcun pacchetto di rete dedicato alla
## piattaforma (a differenza del giocatore, qui non serve un
## NetworkManager.send_raw_position() equivalente). Un piccolo scarto di
## orologio tra client resta impercettibile; una simulazione fisica
## indipendente per client, invece, diverge visibilmente nel tempo.

@export var point_a: Vector3 = Vector3.ZERO
@export var point_b: Vector3 = Vector3(0, 0, 5)
@export var travel_time_seconds: float = 3.0 # tempo per UNA tratta (a->b oppure b->a)


func _ready() -> void:
	sync_to_physics = true # necessario perché un CharacterBody3D venga trascinato correttamente


func _physics_process(_delta: float) -> void:
	if travel_time_seconds <= 0.0:
		global_position = point_a
		return
	var t := fmod(Time.get_ticks_msec() / 1000.0, travel_time_seconds * 2.0)
	var ping_pong := t / travel_time_seconds
	if ping_pong > 1.0:
		ping_pong = 2.0 - ping_pong
	# smoothstep invece di lerp lineare: la piattaforma rallenta agli
	# estremi, così non “strappa” il giocatore che ci sta sopra a ogni
	# inversione di marcia.
	var eased := ping_pong * ping_pong * (3.0 - 2.0 * ping_pong)
	global_position = point_a.lerp(point_b, eased)
