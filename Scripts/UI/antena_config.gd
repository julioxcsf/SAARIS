extends Button

@onready var antenas_panel = $"../Antena_Panel"
@onready var lista_antenas = $"../Antena_Panel/VBoxContainer/ListaAntenas"
@onready var btn_remove = $"../Antena_Panel/VBoxContainer/HBoxContainer/BtnRemove"
@onready var btn_add = $"../Antena_Panel/VBoxContainer/HBoxContainer/BtnAdd"

@onready var check_ligado = $"../Antena_Panel/VBoxContainer/EditorRIS/ON_OFF"
@onready var spin_freq = $"../Antena_Panel/VBoxContainer/EditorRIS/VBoxContainer/Spin_Freq_MHz"
@onready var spin_pot = $"../Antena_Panel/VBoxContainer/EditorRIS/VBoxContainer2/Spin_Pot_dBm"
@onready var spin_x = $"../Antena_Panel/VBoxContainer/EditorRIS/VBoxContainer3/SpinX"
@onready var spin_y = $"../Antena_Panel/VBoxContainer/EditorRIS/VBoxContainer4/SpinY"
@onready var spin_z = $"../Antena_Panel/VBoxContainer/EditorRIS/VBoxContainer5/SpinZ"

@onready var fixar_x = $"../Antena_Panel/VBoxContainer/EditorRIS/VBoxContainer3/FixarX"
@onready var fixar_y = $"../Antena_Panel/VBoxContainer/EditorRIS/VBoxContainer4/FixarY"
@onready var fixar_z = $"../Antena_Panel/VBoxContainer/EditorRIS/VBoxContainer5/FixarZ"

var current_tx_index: int = -1

func _ready() -> void:
	setup_tx_ui()

func setup_tx_ui():
	# Registro direto no Manager: ele chama aplicar_posicao() / recarregar() / set_ocupado()
	Manager.ui_tx = self
	add_to_group("trava_simulacao")

	# Sinais internos da UI e botoes (os do proprio Godot: botoes, spinboxes)
	btn_add.pressed.connect(_on_add_pressed)
	btn_remove.pressed.connect(_on_remove_pressed)
	lista_antenas.item_selected.connect(_on_item_selected)

	_configurar_spinbox_realtime(spin_x, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_y, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_z, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_freq, 10.0, 100.0)
	_configurar_spinbox_realtime(spin_pot, 1.0, 5.0)

	check_ligado.toggled.connect(func(_p): _on_value_changed_realtime(0.0))

	fixar_x.toggled.connect(func(p): _on_fixar_toggled("X", p))
	fixar_y.toggled.connect(func(p): _on_fixar_toggled("Y", p))
	fixar_z.toggled.connect(func(p): _on_fixar_toggled("Z", p))

	self.toggle_mode = true
	self.toggled.connect(_on_toggle_menu)
	antenas_panel.visible = false

func set_ocupado(busy: bool):
	btn_add.disabled = busy
	if btn_remove: btn_remove.disabled = busy
	_set_container_enabled(antenas_panel, not busy)

func _set_container_enabled(container: Node, enabled: bool):
	for child in container.get_children():
		if child is SpinBox:
			child.editable = enabled
		elif child is Button or child is CheckBox:
			child.disabled = not enabled
		if child.get_child_count() > 0:
			_set_container_enabled(child, enabled)

func _configurar_spinbox_realtime(spin: SpinBox, step_val: float, arrow_val: float):
	spin.step = step_val
	spin.custom_arrow_step = arrow_val
	spin.value_changed.connect(_on_value_changed_realtime)

# --- CHAMADAS DIRETAS AO HANDLER ---

func _on_item_selected(index: int):
	current_tx_index = index
	# Busca direta e sincrona dos dados da antena selecionada
	var data = Manager.tx_handler.get_tx_info(index)
	if not data.is_empty():
		_atualizar_campos_ui(data)

func _on_add_pressed():
	# Cria a antena e recebe imediatamente os dados de batismo
	var resultado = Manager.tx_handler.add_tx()

	lista_antenas.add_item(resultado.name)
	var last_idx = lista_antenas.item_count - 1
	lista_antenas.select(last_idx)

	current_tx_index = last_idx
	_atualizar_campos_ui(resultado.data)

func _on_remove_pressed():
	if current_tx_index != -1:
		# Deleta diretamente do cache/arvore e atualiza a UI local na hora
		var deletado_com_sucesso = Manager.tx_handler.remove_tx(current_tx_index)
		if deletado_com_sucesso:
			lista_antenas.remove_item(current_tx_index)
			current_tx_index = -1

func _on_value_changed_realtime(_v: float):
	if current_tx_index == -1: return
	var data = {
		"ligado": check_ligado.button_pressed,
		"freq": spin_freq.value,
		"potencia": spin_pot.value,
		"posicao": Vector3(spin_x.value, spin_y.value, spin_z.value)
	}
	# Atualiza o objeto 3D diretamente por referencia no handler
	Manager.tx_handler.update_tx(current_tx_index, data)

## Reconstroi a lista a partir do Manager.tx_handler (apos carregar um save, por exemplo).
func recarregar():
	lista_antenas.clear()
	current_tx_index = -1
	if Manager.tx_handler == null:
		return
	for tx in Manager.tx_handler.tx_cache:
		lista_antenas.add_item(tx.name)

# --- AUXILIARES E INTERACOES 3D ---

func _atualizar_campos_ui(data: Dictionary):
	var controles = [spin_x, spin_y, spin_z, spin_freq, spin_pot]

	# Bloqueia sinais para evitar loops de chamadas ao atualizar valores via script
	for s in controles: s.set_block_signals(true)
	check_ligado.set_block_signals(true)

	if data.has("ligado"): check_ligado.button_pressed = data["ligado"]
	if data.has("freq"): spin_freq.value = data["freq"]
	if data.has("potencia"): spin_pot.value = data["potencia"]
	if data.has("posicao"):
		spin_x.value = data["posicao"].x
		spin_y.value = data["posicao"].y
		spin_z.value = data["posicao"].z

	for s in controles: s.set_block_signals(false)
	check_ligado.set_block_signals(false)

func _on_fixar_toggled(eixo: String, is_pressed: bool):
	if is_pressed and current_tx_index != -1:
		if eixo != "X": fixar_x.button_pressed = false
		if eixo != "Y": fixar_y.button_pressed = false
		if eixo != "Z": fixar_z.button_pressed = false

		var val = 0.0
		if eixo == "X": val = spin_x.value
		elif eixo == "Y": val = spin_y.value
		elif eixo == "Z": val = spin_z.value

		Manager.request_plane_placement("TX", current_tx_index, eixo, val)

## Chamado direto pelo Manager quando o clique no plano foi resolvido.
func aplicar_posicao(new_pos: Vector3):
	fixar_x.button_pressed = false
	fixar_y.button_pressed = false
	fixar_z.button_pressed = false

	spin_x.value = new_pos.x
	spin_y.value = new_pos.y
	spin_z.value = new_pos.z

func _on_toggle_menu(is_pressed: bool):
	antenas_panel.visible = is_pressed
	self.text = "Gerenciar TX ▼" if not is_pressed else "Gerenciar TX ▲"
