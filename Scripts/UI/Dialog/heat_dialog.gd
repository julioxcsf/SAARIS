extends AcceptDialog

@onready var spin_min = $VBoxContainer/HBoxContainer/SpinPotMax
@onready var spin_crit = $VBoxContainer/HBoxContainer2/SpinPotCrit
@onready var spin_max = $VBoxContainer/HBoxContainer3/SpinPotMin
@onready var switch_gradient_label = $VBoxContainer/EscalaCorVisivel

@onready var gradient_container = $"../../../../AreaTrabalho/Simulacao/GradientContainer"
@onready var label_min = $"../../../../AreaTrabalho/Simulacao/GradientContainer/label_pot/min"
@onready var label_crit = $"../../../../AreaTrabalho/Simulacao/GradientContainer/label_pot/crit"
@onready var label_max = $"../../../../AreaTrabalho/Simulacao/GradientContainer/label_pot/max"

func _ready() -> void:
	# Sem setup de valores mágicos locais.
	_connect_internal_signals()

func _connect_internal_signals():
	if not confirmed.is_connected(_on_config_confirmed):
		confirmed.connect(_on_config_confirmed)
	
	if not switch_gradient_label.toggled.is_connected(_on_gradient_toggled):
		switch_gradient_label.toggled.connect(_on_gradient_toggled)
	
	spin_min.value_changed.connect(_update_gradient_label)
	spin_crit.value_changed.connect(_update_gradient_label)
	spin_max.value_changed.connect(_update_gradient_label)
	
	# A UI escuta o Manager no boot
	Manager.request_heatmap_config.connect(_on_manager_enviou_config_heatmap)

# Recebe a verdade absoluta do Manager
func _on_manager_enviou_config_heatmap(min_dbm: float, crit_dbm: float, max_dbm: float):
	spin_min.value = min_dbm
	spin_crit.value = crit_dbm
	spin_max.value = max_dbm
	
	# Atualiza o visual apenas depois que os dados chegarem
	_update_gradient_label(0)
	_on_gradient_toggled(switch_gradient_label.button_pressed)

func _on_config_confirmed():
	var min_val = spin_min.value
	var crit_val = spin_crit.value
	var max_val = spin_max.value
	
	if min_val >= max_val:
		printerr("[HeatDialog] Erro: Sinal Mínimo deve ser menor que o Sinal Máximo.")
		return
		
	var map_data = {
		"min_dbm": min_val,
		"crit_dbm": crit_val,
		"max_dbm": max_val,
		"mostrar_escala": switch_gradient_label.button_pressed
	}

	Manager.emit_heatmap_config(min_val, crit_val, max_val)
	Manager.save_global_config({}, {}, map_data)

func _on_gradient_toggled(is_visible: bool):
	if gradient_container:
		gradient_container.visible = is_visible

func _update_gradient_label(_value: float):
	if label_min and label_crit and label_max:
		label_min.text = "%d [dBm] " % spin_min.value
		label_crit.text = "%d" % spin_crit.value
		label_max.text = "%d" % spin_max.value
