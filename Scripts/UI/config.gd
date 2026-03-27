extends MenuButton

# Referências da janela de configuração e seus controles numéricos
@onready var win_config = $AcceptDialog
@onready var spin_min = $AcceptDialog/VBoxContainer/HBoxContainer/SpinBox
@onready var spin_crit = $AcceptDialog/VBoxContainer/HBoxContainer2/SpinBox2
@onready var spin_max = $AcceptDialog/VBoxContainer/HBoxContainer3/SpinBox3
@onready var switch_gradient_label = $AcceptDialog/VBoxContainer/EscalaCorVisivel

# Referências da legenda visual do mapa de calor na tela principal
@onready var gradient_container = $"../../../AreaTrabalho/Simulacao/VBoxContainer"
@onready var label_min = $"../../../AreaTrabalho/Simulacao/VBoxContainer/label_pot/min"
@onready var label_crit = $"../../../AreaTrabalho/Simulacao/VBoxContainer/label_pot/crit"
@onready var label_max = $"../../../AreaTrabalho/Simulacao/VBoxContainer/label_pot/max"

func _ready() -> void:
	# Define valores iniciais conservadores de RF
	spin_min.value = -110.0
	spin_crit.value = -95.0
	spin_max.value = -60.0
	
	# MenuButton não emite 'pressed' direto; precisamos capturar o menu dropdown filho (popup)
	var popup = get_popup()
	popup.id_pressed.connect(_on_config_menu_item_selected)

	win_config.confirmed.connect(_on_config_confirmed)
	switch_gradient_label.toggled.connect(_on_gradient_toggled)
	
	# Atualiza as labels da interface em tempo real enquanto o usuário altera a spinbox
	spin_min.value_changed.connect(_update_gradient_label)
	spin_crit.value_changed.connect(_update_gradient_label)
	spin_max.value_changed.connect(_update_gradient_label)

	# Força o estado visual inicial para evitar bugs de exibição
	win_config.visible = false
	_update_gradient_label(0)
	_on_gradient_toggled(switch_gradient_label.button_pressed)


# Captura qual opção do dropdown foi selecionada
func _on_config_menu_item_selected(id: int):
	if id == 0: # ID 0 corresponde a "Configurar Cores" nas opções do nó
		win_config.popup_centered()


# Disparado ao clicar em "OK" na janela de configuração
func _on_config_confirmed():
	var min_val = spin_min.value
	var crit_val = spin_crit.value
	var max_val = spin_max.value
	
	# Proteção fundamental contra inversão da escala de calor que corromperia o Shader
	if min_val >= max_val:
		Manager.emit_user_warning("Erro: Potência Mínima deve ser menor que a Máxima.")
		return

	# Envia os dados validados para o motor recolorir a malha instantaneamente
	Manager.emit_heatmap_config(min_val, crit_val, max_val)


# Exibe ou oculta a barra visual de gradiente na interface principal
func _on_gradient_toggled(is_visible: bool):
	gradient_container.visible = is_visible


# Atualiza os textos da barra de gradiente dinamicamente (espaçamento cuidado pelo HBoxContainer)
func _update_gradient_label(_value: float):
	label_min.text = "%d [dBm] " % spin_min.value
	label_crit.text = "%d" % spin_crit.value
	label_max.text = "%d" % spin_max.value
