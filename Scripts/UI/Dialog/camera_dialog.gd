extends AcceptDialog

# Referências corretas para a Câmera
@onready var spin_speed = $VBoxContainer/HBoxContainer/SpinVelocidade
@onready var spin_sensibilidade = $VBoxContainer/HBoxContainer2/SpinSensibilidade
@onready var spin_fov = $VBoxContainer/HBoxContainer3/SpinFOV

func _ready() -> void:
	# O _setup_initial_values() foi obliterado. A interface não adivinha nada.
	_connect_internal_signals()

func _connect_internal_signals():
	if not confirmed.is_connected(_on_config_confirmed):
		confirmed.connect(_on_config_confirmed)
		
	# A interface abaixa a cabeça e escuta o Manager gritar os valores no boot
	Manager.request_camera_config.connect(_on_manager_enviou_config_camera)

# Função engatilhada automaticamente quando o Manager lê o user://settings.cfg
func _on_manager_enviou_config_camera(new_speed: float, new_sens: float, new_fov: float):
	spin_speed.value = new_speed
	spin_sensibilidade.value = new_sens
	spin_fov.value = new_fov

func _on_config_confirmed():
	var val_speed = spin_speed.value
	var val_sens = spin_sensibilidade.value
	var val_fov = spin_fov.value
	
	var cam_data = {
		"speed": val_speed,
		"sensitivity": val_sens,
		"fov": val_fov
	}
	
	# Atualiza o simulador em tempo real
	Manager.emit_camera_config(val_speed, val_sens, val_fov)
	
	# Salva permanentemente
	Manager.save_global_config({}, cam_data, {})
	
	if Manager.DEBUG:
		print("Interface: Configuração de câmera enviada e salva.")
