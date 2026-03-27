extends AcceptDialog

@onready var check_los = $"../SimulatorDialog/VBoxContainer/HBoxContainer1/CheckLOS"
@onready var check_reflection = $"../SimulatorDialog/VBoxContainer/HBoxContainer2/CheckReflection"
@onready var check_diffraction = $"../SimulatorDialog/VBoxContainer/HBoxContainer3/CheckDiffraction"
@onready var spin_pixels = $"../SimulatorDialog/VBoxContainer/HBoxContainer4/SpinPixels"
@onready var spin_max_reflections = $"../SimulatorDialog/VBoxContainer/HBoxContainer5/SpinNumReflection"
@onready var spin_reflection_loss = $"../SimulatorDialog/VBoxContainer/HBoxContainer6/SpinReflecLoss"
@onready var spin_expoent_path_loss =$"../SimulatorDialog/VBoxContainer/HBoxContainer7/SpinExpoent"
@onready var color_max = $"../SimulatorDialog/VBoxContainer/HBoxContainer8/MaxColor"
@onready var color_crit = $"../SimulatorDialog/VBoxContainer/HBoxContainer9/CritColor"
@onready var color_min = $"../SimulatorDialog/VBoxContainer/HBoxContainer10/MinColor"


func _ready() -> void:
	if not confirmed.is_connected(_on_config_confirmed):
		confirmed.connect(_on_config_confirmed)
	
	Manager.request_simulator_config.connect(_on_manager_enviou_config_simulador)

# Preenche os campos quando o Manager carrega os dados do disco
func _on_manager_enviou_config_simulador(config_data: Dictionary):
	check_los.button_pressed = config_data.get("los_ativado", true)
	check_reflection.button_pressed = config_data.get("reflection_ativado", true)
	check_diffraction.button_pressed = config_data.get("diffraction_ativado", true)
	spin_pixels.value = config_data.get("pixels_per_frame", 256)
	spin_max_reflections.value = config_data.get("max_reflections", 5)
	spin_reflection_loss.value = config_data.get("reflection_loss_db", 5.0)
	spin_expoent_path_loss.value = config_data.get("path_loss_exponent", 2.8)
	color_max.color = config_data.get("max_sinal_color", Color.RED)
	color_crit.color = config_data.get("critical_sinal_color", Color.GREEN)
	color_min.color = config_data.get("min_sinal_color", Color.BLUE)

func _on_config_confirmed():
	var config_data = {
		"los_ativado": check_los.button_pressed,
		"reflection_ativado": check_reflection.button_pressed,
		"diffraction_ativado": check_diffraction.button_pressed,
		"pixels_per_frame": int(spin_pixels.value),
		"max_reflections": int(spin_max_reflections.value),
		"reflection_loss_db": float(spin_reflection_loss.value),
		"path_loss_exponent": float(spin_expoent_path_loss.value), # CHAVE CORRIGIDA
		"max_sinal_color": color_max.color,
		"critical_sinal_color": color_crit.color,
		"min_sinal_color": color_min.color
	}
	
	Manager.emit_simulator_config(config_data)
	Manager.save_global_config(config_data, {}, {})
	
	if Manager.DEBUG:
		print("Interface: Dicionário do simulador enviado: ", config_data)
