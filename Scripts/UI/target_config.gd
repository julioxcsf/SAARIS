extends Button
## Painel "Gerenciar RX" - varios RX (regioes de cobertura de interesse). Sem sinais:
## tudo vai direto em  Manager.rx_handler.add_rx() / update_rx(i, {...}) / remove_rx(i).

@onready var target_panel = get_node("../Target_Panel")
@onready var list_target = get_node("../Target_Panel/VBoxContainer/ListaTarget")
@onready var btn_add = get_node("../Target_Panel/VBoxContainer/HBoxContainer/BtnAdd")
@onready var btn_remove = get_node("../Target_Panel/VBoxContainer/HBoxContainer/BtnRemove")

# Referencias do Editor de Propriedades
@onready var spin_width = $"../Target_Panel/VBoxContainer/EditorTarget/VBoxContainer/SpinSizeX"
@onready var spin_length = $"../Target_Panel/VBoxContainer/EditorTarget/VBoxContainer2/SpinSizeZ"
@onready var spin_rot = $"../Target_Panel/VBoxContainer/EditorTarget/SpinRot"
@onready var spin_x = $"../Target_Panel/VBoxContainer/EditorTarget/VBoxContainer3/SpinX"
@onready var spin_y = $"../Target_Panel/VBoxContainer/EditorTarget/VBoxContainer4/SpinY"
@onready var spin_z = $"../Target_Panel/VBoxContainer/EditorTarget/VBoxContainer5/SpinZ"
@onready var btn_update = $"../Target_Panel/VBoxContainer/EditorTarget/BtnUpdateAlvo"
@onready var fixar_y = $"../Target_Panel/VBoxContainer/EditorTarget/VBoxContainer4/FixarY"
@onready var spin_importance = $"../Target_Panel/VBoxContainer/EditorTarget/VBoxContainer6/SpinPeso"

var current_target_index: int = -1

func _ready():
	setup_target_ui()

func setup_target_ui():
	# Registro direto no Manager: ele chama aplicar_posicao() / recarregar() / set_ocupado()
	Manager.ui_rx = self
	add_to_group("trava_simulacao")

	btn_add.pressed.connect(_on_btn_target_add_pressed)
	btn_remove.pressed.connect(_on_btn_target_remove_pressed)
	btn_update.pressed.connect(_on_update_pressed)
	fixar_y.toggled.connect(func(p): _on_fixar_toggled("Y", p))

	# Posicao/rotacao/tamanho em tempo real (scroll 1 m, setas 10 m)
	_configurar_spinbox_realtime(spin_x, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_y, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_z, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_rot, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_width, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_length, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_importance, 0.1, 1.0)

	list_target.item_selected.connect(_on_item_selected)

	self.toggle_mode = true
	self.toggled.connect(_on_toggle_menu)
	target_panel.visible = false

func set_ocupado(busy: bool):
	btn_add.disabled = busy
	if btn_remove: btn_remove.disabled = busy
	_set_container_enabled(target_panel, not busy)

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

func _dados_da_tela() -> Dictionary:
	return {
		"posicao": Vector3(spin_x.value, spin_y.value, spin_z.value),
		"rotation": spin_rot.value,
		"width": spin_width.value,
		"length": spin_length.value,
		"importance": spin_importance.value,
	}

func _on_value_changed_realtime(_new_value: float):
	if current_target_index == -1: return
	Manager.rx_handler.update_rx(current_target_index, _dados_da_tela())   # chamada direta
	_atualizar_diagnostico_ris()

func _on_update_pressed():
	if current_target_index == -1: return
	Manager.rx_handler.update_rx(current_target_index, _dados_da_tela())
	_atualizar_diagnostico_ris()

func _on_fixar_toggled(eixo: String, is_pressed: bool):
	if is_pressed and current_target_index != -1:
		Manager.request_plane_placement("RX", current_target_index, eixo, spin_y.value)

## Chamado direto pelo Manager quando o clique no plano foi resolvido (RX: so X e Z mudam).
func aplicar_posicao(new_pos: Vector3):
	fixar_y.button_pressed = false
	spin_x.value = new_pos.x
	spin_z.value = new_pos.z

func _on_toggle_menu(is_pressed: bool):
	target_panel.visible = is_pressed
	self.text = "Gerenciar RX ▼" if not is_pressed else "Gerenciar RX ▲"

func _on_item_selected(index: int):
	current_target_index = index
	_preencher_campos(Manager.rx_handler.get_rx_info(index))

func _on_btn_target_add_pressed():
	var r: Dictionary = Manager.rx_handler.add_rx()          # devolve {index, name, data}
	list_target.add_item(r.name)
	list_target.select(r.index)
	current_target_index = r.index
	_preencher_campos(r.data)
	_atualizar_lista_ris()

func _on_btn_target_remove_pressed():
	if current_target_index == -1: return
	if Manager.rx_handler.remove_rx(current_target_index):
		list_target.remove_item(current_target_index)
		current_target_index = -1
		_atualizar_lista_ris()

func _preencher_campos(data: Dictionary):
	if data.is_empty(): return
	var spins = [spin_width, spin_length, spin_rot, spin_importance, spin_x, spin_y, spin_z]
	for s in spins: s.set_block_signals(true)
	if data.has("width"): spin_width.value = data["width"]
	if data.has("length"): spin_length.value = data["length"]
	if data.has("rotation"): spin_rot.value = data["rotation"]
	if data.has("importance"): spin_importance.value = data["importance"]
	if data.has("posicao"):
		spin_x.value = data["posicao"].x
		spin_y.value = data["posicao"].y
		spin_z.value = data["posicao"].z
	for s in spins: s.set_block_signals(false)

## Reconstroi a lista a partir do Manager.rx_handler (apos carregar um save).
func recarregar():
	list_target.clear()
	current_target_index = -1
	if Manager.rx_handler == null: return
	for rx in Manager.rx_handler.rx_cache:
		list_target.add_item(rx.name)

# o painel de RIS mostra a lista de RX alvo e o diagnostico; avisamos direto
func _atualizar_lista_ris():
	if Manager.ui_ris != null:
		Manager.ui_ris.atualizar_lista_rx()

func _atualizar_diagnostico_ris():
	if Manager.ui_ris != null:
		Manager.ui_ris.atualizar_diagnostico()
