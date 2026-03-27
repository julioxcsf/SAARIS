extends Button

signal request_frequency_change(new_freq_mhz)

@onready var janela_freq: AcceptDialog = $AcceptDialog
@onready var option_freq: OptionButton = $AcceptDialog/VBoxContainer/HBoxContainer/OptionButton
@onready var spin_freq: SpinBox = $AcceptDialog/VBoxContainer/HBoxContainer2/SpinBox
@onready var freq_multiplier_btn: OptionButton = $AcceptDialog/VBoxContainer/HBoxContainer2/OptionButton

# Fatores de conversão diretos para a unidade base do motor (MHz)
const MULTIPLIER_TO_MHZ = {
	0: 1000.0,      # GHz -> MHz
	1: 1.0,         # MHz -> MHz
	2: 0.001,       # kHz -> MHz
	3: 0.000001     # Hz  -> MHz
}

# Presets mapeados: { "val": valor, "unit_idx": id_do_multiplicador }
const PRESETS = {
	0: { "val": 700.0,  "unit_idx": 1 }, # 700 MHz
	1: { "val": 1800.0, "unit_idx": 1 }, # 1800 MHz
	2: { "val": 3.5,    "unit_idx": 0 }, # 3.5 GHz
	3: { "val": 26.0,   "unit_idx": 0 }  # 26 GHz
}


func _ready() -> void:
	# Conecta a exibição da janela diretamente ao botão (modo modal)
	self.pressed.connect(janela_freq.popup_centered)
	
	option_freq.item_selected.connect(_on_freq_preset_selected)
	spin_freq.value_changed.connect(_on_input_changed)
	freq_multiplier_btn.item_selected.connect(_on_input_changed)
	
	freq_multiplier_btn.select(1) # Visual padrão para MHz


# Converte os campos visuais para MHz e emite o sinal para o motor
func _on_input_changed(_discard = null):
	var valor_visual = spin_freq.value
	var idx_unidade = freq_multiplier_btn.selected
	
	# Puxa o multiplicador (default 1.0 se houver erro no índice)
	var fator_mhz = MULTIPLIER_TO_MHZ.get(idx_unidade, 1.0)
	var frequencia_final_mhz = valor_visual * fator_mhz
	
	request_frequency_change.emit(frequencia_final_mhz)


# Ajusta a interface com base no preset escolhido pelo usuário
func _on_freq_preset_selected(index: int):
	if PRESETS.has(index):
		var p = PRESETS[index]
		
		# Bloqueia o sinal temporariamente para evitar a emissão de cálculos intermediários
		freq_multiplier_btn.set_block_signals(true)
		freq_multiplier_btn.select(p["unit_idx"])
		freq_multiplier_btn.set_block_signals(false)
		
		# Setar o valor dispara o `value_changed`, que chama `_on_input_changed` com a unidade já correta
		spin_freq.value = p["val"]
		
		spin_freq.editable = false
		freq_multiplier_btn.disabled = true
	else:
		# Modo "Personalizado" destrava os controles para entrada manual
		spin_freq.editable = true
		freq_multiplier_btn.disabled = false
		spin_freq.grab_focus()
