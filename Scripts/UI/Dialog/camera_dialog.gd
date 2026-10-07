extends AcceptDialog

# Referencias corretas para a Camera
@onready var spin_speed = $VBoxContainer/HBoxContainer/SpinVelocidade
@onready var spin_sensibilidade = $VBoxContainer/HBoxContainer2/SpinSensibilidade
@onready var spin_fov = $VBoxContainer/HBoxContainer3/SpinFOV

func _ready() -> void:
	# O _setup_initial_values() foi obliterado. A interface nao adivinha nada.
	_connect_internal_signals()
	# o Manager aplica o settings.cfg na camera (deferred); aqui so espelhamos os valores nos campos
	call_deferred("_carregar_campos")

func _connect_internal_signals():
	if not confirmed.is_connected(_on_config_confirmed):
		confirmed.connect(_on_config_confirmed)

## Preenche os campos com o que esta salvo no settings.cfg (ou com a camera atual).
func _carregar_campos():
	var cam = Manager.camera
	spin_speed.value = Manager.ler_config("Camera", "speed", cam.speed if cam else 200.0)
	spin_sensibilidade.value = Manager.ler_config("Camera", "sensitivity", cam.sensitivity if cam else 0.2)
	spin_fov.value = Manager.ler_config("Camera", "fov", cam.fov if cam else 70.0)

func _on_config_confirmed():
	var val_speed = spin_speed.value
	var val_sens = spin_sensibilidade.value
	var val_fov = spin_fov.value

	var cam_data = {
		"speed": val_speed,
		"sensitivity": val_sens,
		"fov": val_fov
	}

	# Atualiza a camera em tempo real (chamada direta)
	if Manager.camera:
		Manager.camera.aplicar_config(val_speed, val_sens, val_fov)

	# Salva permanentemente
	Manager.save_global_config({}, cam_data, {})

	if Manager.DEBUG:
		print("Interface: Configuração de câmera enviada e salva.")
