extends HBoxContainer

@onready var start_button = $start_button
@onready var cancel_button = $cancel_button
@onready var progress_bar: ProgressBar = $ProgressBar

var is_running = false

func _ready() -> void:
	start_button.pressed.connect(_on_start_button_pressed)
	cancel_button.pressed.connect(_on_cancel_button_pressed)
	Manager.simulation_progress_update.connect(_on_simulation_progress_update)
	
	progress_bar.visible = false


func _on_start_button_pressed():
	is_running = !is_running
	
	if is_running:
		start_button.text = "Stop"
		progress_bar.visible = true
		progress_bar.modulate = Color.WHITE # Reseta a cor ao iniciar
		Manager.request_start.emit()   
	else:
		start_button.text = "Start"
		Manager.request_stop.emit()


func _on_cancel_button_pressed():
	# Reseta a interface e o estado explicitamente, sem simular cliques falsos
	is_running = false
	start_button.text = "Start"
	
	progress_bar.value = 0.0
	progress_bar.modulate = Color.WHITE
	progress_bar.visible = false
	
	Manager.request_cancel.emit() 


func _on_simulation_progress_update(percentual: float):
	progress_bar.visible = true
	progress_bar.value = percentual
	
	if percentual >= 99.9:
		progress_bar.modulate = Color.GREEN
		
		# Proteção do Load: Retorna o botão para "Start" de forma silenciosa
		# caso a simulação atinja 100% naturalmente. Se for um Load, ignora.
		if is_running:
			is_running = false
			start_button.text = "Start"
