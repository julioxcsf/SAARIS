extends Button

signal request_place_target
signal request_remove_target(index: int)

@onready var target_panel = get_node("../Target_Panel")
@onready var list_target = get_node("../Target_Panel/VBoxContainer/ListaTarget")
@onready var btn_add = get_node("../Target_Panel/VBoxContainer/HBoxContainer/BtnAdd")
@onready var btn_remove = get_node("../Target_Panel/VBoxContainer/HBoxContainer/BtnRemove")

# Referências do Editor de Propriedades
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
	# Conexões do Manager
	Manager.handshake_target_created.connect(_on_handshake_target_created)
	Manager.handshake_target_deleted.connect(_on_handshake_target_deleted)
	Manager.handshake_target_clear_all.connect(_on_handshake_clear_all)
	Manager.response_target_info.connect(_on_response_target_info)
	Manager.placement_click_resolved.connect(_on_plane_click_resolved)
	
	# Conexões de Botões
	btn_add.pressed.connect(_on_btn_target_add_pressed)
	btn_remove.pressed.connect(_on_btn_target_remove_pressed)
	btn_update.pressed.connect(_on_update_pressed)
	fixar_y.toggled.connect(func(p): _on_fixar_toggled("Y", p))
	
	# Configuração de Tempo Real (Posição e Rotação)
	_configurar_spinbox_realtime(spin_x, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_y, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_z, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_rot, 1.0, 10.0)

	# Ajuste de tamanho: move de 1m em 1m (scroll) e 10m em 10m (setas)
	_configurar_spinbox_realtime(spin_width, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_length, 1.0, 10.0)
	
	_configurar_spinbox_realtime(spin_importance, 0.1, 1.0)
	
	list_target.item_selected.connect(_on_item_selected)
	
	self.toggle_mode = true
	self.toggled.connect(_on_toggle_menu)
	target_panel.visible = false
	Manager.simulation_state_changed.connect(_on_simulation_state_changed)

func _on_simulation_state_changed(busy: bool):
	# Trava os botões principais
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
	spin.step = step_val            # Scroll do mouse (ex: 1.0)
	spin.custom_arrow_step = arrow_val # Setas da interface (ex: 10.0)
	spin.value_changed.connect(_on_value_changed_realtime)

func _on_value_changed_realtime(_new_value: float):
	if current_target_index == -1: return


	var data = {
		"posicao": Vector3(spin_x.value, spin_y.value, spin_z.value),
		"rotation": spin_rot.value,
		"width": spin_width.value,
		"length": spin_length.value,
		"importance": spin_importance.value
	}
	
	Manager.emit_update_target(current_target_index, data)


func _on_fixar_toggled(eixo: String, is_pressed: bool):
	if is_pressed and current_target_index != -1:
		Manager.request_plane_placement("RX", current_target_index, eixo, spin_y.value)

func _on_plane_click_resolved(new_pos: Vector3):
	if Manager.current_placement_mode != Manager.PlacementMode.RX: return
	
	fixar_y.button_pressed = false
	spin_x.value = new_pos.x
	spin_z.value = new_pos.z


func _on_toggle_menu(is_pressed: bool):
	target_panel.visible = is_pressed
	self.text = "Gerenciar RX ▼" if not is_pressed else "Gerenciar RX ▲"

func _on_item_selected(index: int):
	current_target_index = index
	Manager.emit_get_target_info(index)

func _on_btn_target_add_pressed():
	Manager.emit_place_target()

func _on_btn_target_remove_pressed():
	if current_target_index != -1:
		Manager.emit_remove_target(current_target_index)

func _on_update_pressed():
	if current_target_index == -1: return
	
	var data = {
		"width": spin_width.value,
		"length": spin_length.value,
		"rotation": spin_rot.value,
		"posicao": Vector3(spin_x.value, spin_y.value, spin_z.value)
	}
	Manager.emit_update_target(current_target_index, data)

func _on_response_target_info(index: int, data: Dictionary):
	if data.has("width"): spin_width.value = data["width"]
	if data.has("length"): spin_length.value = data["length"]
	if data.has("rotation"): spin_rot.value = data["rotation"]
	if data.has("importance"): spin_importance.value = data["importance"]
	if data.has("posicao"):
		spin_x.value = data["posicao"].x
		spin_y.value = data["posicao"].y
		spin_z.value = data["posicao"].z


func _on_handshake_target_created(index: int, nome: String):
	list_target.add_item(nome)
	# Seleciona automaticamente o último criado
	var last_idx = list_target.item_count - 1
	list_target.select(last_idx)
	_on_item_selected(last_idx)

func _on_handshake_target_deleted(index: int):
	list_target.remove_item(index)
	current_target_index = -1

func _on_handshake_clear_all():
	list_target.clear()
	current_target_index = -1
