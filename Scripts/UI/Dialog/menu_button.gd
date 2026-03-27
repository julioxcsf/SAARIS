extends MenuButton

# Referências para as diferentes janelas de configuração
@onready var win_heatmap = $HeatDialog
@onready var win_camera = $CameraDialog
@onready var win_simulator =$SimulatorDialog

func _ready() -> void:
	var popup = get_popup()
	popup.id_pressed.connect(_on_item_selected)

func _on_item_selected(id: int) -> void:
	match id:
		0: win_heatmap.popup_centered()    # Lógica de Cores
		1: win_camera.popup_centered()     # Lógica de Câmera
		2: win_simulator.popup_centered()  # Lógica do Simulador
