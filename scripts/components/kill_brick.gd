extends Area3D
## Componente sicuro "Livello 2": i creator lo attaccano a un'Area3D nella
## propria scena e configurano SOLO le proprietà esportate qui sotto
## tramite l'inspector -- nessun codice di loro scrittura viene mai
## eseguito. Il file .gd stesso viene sempre dal client (vedi
## res://scripts/world_loader.gd:_contains_disallowed_script), mai dal
## pack del mondo.
##
## Comportamento: quando il capsule del giocatore locale entra nell'area,
## lo riporta a respawn_position. Agisce solo sul proprio giocatore
## (player.gd:respawn_at() ignora la chiamata se non è authority locale),
## quindi non c'è modo per questo componente di spostare l'avatar di un
## altro peer.

@export var respawn_position: Vector3 = Vector3.ZERO


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if body.has_method("respawn_at"):
		body.respawn_at(respawn_position)
