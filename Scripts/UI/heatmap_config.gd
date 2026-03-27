# heatDialog.gd
extends AcceptDialog

# signal request_heatmap_config(min_dbm: float, crit_dbm: float, max_dbm: float)

# referencia para entradas de ajuste de valores de sinais para mapa de calor
@onready var spin_min = $AcceptDialog/VBoxContainer/HBoxContainer/SpinBox
@onready var spin_crit = $AcceptDialog/VBoxContainer/HBoxContainer2/SpinBox2
@onready var spin_max = $AcceptDialog/VBoxContainer/HBoxContainer3/SpinBox3
@onready var switch_gradient_label = $AcceptDialog/VBoxContainer/EscalaCorVisivel


@onready var gradient_container = $"../../../AreaTrabalho/Simulacao/VBoxContainer"
@onready var label_min = $"../../../../AreaTrabalho/Simulacao/VBoxContainer/label_pot/min"
@onready var label_crit = $"../../../../AreaTrabalho/Simulacao/VBoxContainer/label_pot/crit"
@onready var label_max = $"../../../../AreaTrabalho/Simulacao/VBoxContainer/label_pot/max"

func _ready() -> void:
	_setup_initial_values()
	_connect_internal_signals()
	
	# Inicializa o estado visual
	_update_gradient_label(0)
	_on_gradient_toggled(switch_gradient_label.button_pressed)

func _setup_initial_values():
	spin_min.value = -110.0
	spin_crit.value = -95.0
	spin_max.value = -60.0

func _connect_internal_signals():
	# Conecta o sinal de confirmação da própria janela
	if not confirmed.is_connected(_on_config_confirmed):
		confirmed.connect(_on_config_confirmed)
	
	# Conecta o switch de visibilidade
	if not switch_gradient_label.toggled.is_connected(_on_gradient_toggled):
		switch_gradient_label.toggled.connect(_on_gradient_toggled)
	
	# Mudanças em tempo real nas labels
	spin_min.value_changed.connect(_update_gradient_label)
	spin_crit.value_changed.connect(_update_gradient_label)
	spin_max.value_changed.connect(_update_gradient_label)

func _on_config_confirmed():
	var min_val = spin_min.value
	var crit_val = spin_crit.value
	var max_val = spin_max.value
	
	if min_val >= max_val:
		printerr("Erro: Min >= Max")
		return

	Manager.emit_heatmap_config(min_val, crit_val, max_val)

func _on_gradient_toggled(is_visible: bool):
	if gradient_container:
		gradient_container.visible = is_visible

func _update_gradient_label(_value: float):
	if label_min and label_crit and label_max:
		label_min.text = "%d [dBm] " % spin_min.value
		label_crit.text = "%d" % spin_crit.value
		label_max.text = "%d" % spin_max.value
