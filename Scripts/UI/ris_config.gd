extends Button

@onready var ris_panel = $"../RIS_Panel"
@onready var list_ris = $"../RIS_Panel/VBoxContainer/ListaRIS"
@onready var editor_container = $"../RIS_Panel/VBoxContainer/EditorRIS"
@onready var btn_add = $"../RIS_Panel/VBoxContainer/HBoxContainer/BtnAdd"
@onready var btn_remove = $"../RIS_Panel/VBoxContainer/HBoxContainer/BtnRemove"
@onready var label_status = $"../RIS_Panel/VBoxContainer/EditorRIS/RIS_Status"

@onready var switch_ris_on = $"../RIS_Panel/VBoxContainer/EditorRIS/CheckON"
@onready var spin_freq = $"../RIS_Panel/VBoxContainer/EditorRIS/SpinFreq"
@onready var label_tamanho = $"../RIS_Panel/VBoxContainer/EditorRIS/label_tamanho"
@onready var spin_cell_x = $"../RIS_Panel/VBoxContainer/EditorRIS/VBoxContainer3/SpinCellN"
@onready var spin_cell_y = $"../RIS_Panel/VBoxContainer/EditorRIS/VBoxContainer4/SpinCellM"
@onready var spin_eficiencia =$"../RIS_Panel/VBoxContainer/EditorRIS/SpinEficiencia"

@onready var spin_pos_x = $"../RIS_Panel/VBoxContainer/EditorRIS/VBoxContainer5/SpinX"
@onready var spin_pos_y = $"../RIS_Panel/VBoxContainer/EditorRIS/VBoxContainer6/SpinY"
@onready var spin_pos_z = $"../RIS_Panel/VBoxContainer/EditorRIS/VBoxContainer7/SpinZ"
@onready var spin_rot = $"../RIS_Panel/VBoxContainer/EditorRIS/SpinRot"

@onready var fixar_x = $"../RIS_Panel/VBoxContainer/EditorRIS/VBoxContainer5/FixarX"
@onready var fixar_y = $"../RIS_Panel/VBoxContainer/EditorRIS/VBoxContainer6/FixarY"
@onready var fixar_z = $"../RIS_Panel/VBoxContainer/EditorRIS/VBoxContainer7/FixarZ"

var current_selected_index: int = -1

func _ready() -> void:
	setup_ris_ui()

func setup_ris_ui():
	Manager.handshake_ris_created.connect(_on_handshake_ris_created)
	Manager.handshake_ris_deleted.connect(_on_handshake_ris_deleted)
	Manager.handshake_ris_clear_all.connect(_on_handshake_clear_all)
	Manager.response_ris_info.connect(_on_response_ris_info)
	Manager.placement_click_resolved.connect(_on_plane_click_resolved)
	
	Manager.request_update_tx.connect(func(_idx, _data): _atualizar_diagnostico_ris())
	Manager.request_update_target.connect(func(_idx, _data): _atualizar_diagnostico_ris())
	Manager.request_update_ris.connect(func(_idx, _data): _atualizar_diagnostico_ris())
	
	switch_ris_on.toggled.connect(func(_is_on): _emit_current_data())
	btn_add.pressed.connect(_on_add_ris_pressed)
	btn_remove.pressed.connect(_on_remove_ris_pressed)
	list_ris.item_selected.connect(_on_ris_list_selected)
	
	fixar_x.toggled.connect(func(p): _on_fixar_toggled("X", p))
	fixar_y.toggled.connect(func(p): _on_fixar_toggled("Y", p))
	fixar_z.toggled.connect(func(p): _on_fixar_toggled("Z", p))
	
	_configurar_spinbox_realtime(spin_pos_x, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_pos_y, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_pos_z, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_rot, 1.0, 10.0)
	
	_configurar_spinbox_realtime(spin_freq, 10.0, 100.0)
	_configurar_spinbox_realtime(spin_cell_x, 1.0, 8.0)
	_configurar_spinbox_realtime(spin_cell_y, 1.0, 8.0)
	_configurar_spinbox_realtime(spin_eficiencia, 0.05, 0.1)
	
	self.toggle_mode = true
	self.toggled.connect(_on_toggle_menu)
	ris_panel.visible = false
	editor_container.visible = false
	
	Manager.simulation_state_changed.connect(_on_simulation_state_changed)

func _on_simulation_state_changed(busy: bool):
	btn_add.disabled = busy
	if btn_remove: btn_remove.disabled = busy
	_set_container_enabled(ris_panel, not busy)

func _set_container_enabled(container: Node, enabled: bool):
	for child in container.get_children():
		if child is SpinBox: child.editable = enabled
		elif child is Button or child is CheckBox: child.disabled = not enabled
		if child.get_child_count() > 0: _set_container_enabled(child, enabled)

func _configurar_spinbox_realtime(spin: SpinBox, step_val: float, arrow_val: float):
	spin.step = step_val
	spin.custom_arrow_step = arrow_val
	spin.value_changed.connect(_on_value_changed_realtime)

func _on_value_changed_realtime(_v: float):
	if current_selected_index == -1: return
	_emit_current_data()
	_atualizar_diagnostico_ris()

func _emit_current_data():
	var data = {
		"ligado": switch_ris_on.button_pressed,
		"freq_mhz": spin_freq.value,
		"ganho_fixo": false,
		"eficiencia": spin_eficiencia.value,
		"cell_n": spin_cell_x.value,
		"cell_m": spin_cell_y.value,
		"posicao": Vector3(spin_pos_x.value, spin_pos_y.value, spin_pos_z.value),
		"rotation": spin_rot.value
	}
	Manager.emit_update_ris_request(current_selected_index, data)

func _on_fixar_toggled(eixo: String, is_pressed: bool):
	if is_pressed and current_selected_index != -1:
		if eixo != "X": fixar_x.button_pressed = false
		if eixo != "Y": fixar_y.button_pressed = false
		if eixo != "Z": fixar_z.button_pressed = false
		var val = 0.0
		if eixo == "X": val = spin_pos_x.value
		elif eixo == "Y": val = spin_pos_y.value
		elif eixo == "Z": val = spin_pos_z.value
		Manager.request_plane_placement("RIS", current_selected_index, eixo, val)

func _on_plane_click_resolved(new_pos: Vector3):
	if Manager.current_placement_mode != Manager.PlacementMode.RIS: return
	fixar_x.button_pressed = false
	fixar_y.button_pressed = false
	fixar_z.button_pressed = false
	spin_pos_x.value = new_pos.x
	spin_pos_y.value = new_pos.y
	spin_pos_z.value = new_pos.z

func _on_toggle_menu(pressed: bool):
	ris_panel.visible = pressed
	self.text = "Gerenciar RIS ▼" if not pressed else "Gerenciar RIS ▲"

func _on_add_ris_pressed():
	# Define os parâmetros de inicialização do RIS focado no MVP
	var data_copy = {
		"freq_mhz": 2400.0,
		"ganho_fixo": false,
		"ligado": false, # RIS nasce desligado
		"eficiencia": 0.9,
		"posicao": Vector3.ZERO
	}
	Manager.emit_add_ris_request(data_copy)

func _atualizar_label_tamanho_fisico_visual_only():
	var freq = spin_freq.value
	if freq <= 0: return
	var cell_size_cm = ((300.0 / freq) / 2.0) * 100.0
	var total_w_m = cell_size_cm * spin_cell_x.value / 100.0
	var total_h_m = cell_size_cm * spin_cell_y.value / 100.0
	var area_total = total_w_m * total_h_m
	
	label_tamanho.text = "Célula unitária: \n%.1f x %.1f cm\n\nÁrea Total (m²): \n%.1f x %.1f = %.2f" % [
		cell_size_cm, cell_size_cm, total_w_m, total_h_m, area_total
	]

func _bloquear_sinais_spin(block: bool):
	var controles = [spin_freq, spin_eficiencia, spin_cell_x, spin_cell_y, spin_pos_x, spin_pos_y, spin_pos_z, spin_rot]
	for s in controles:
		s.set_block_signals(block)
	switch_ris_on.set_block_signals(block)

func _on_remove_ris_pressed():
	if current_selected_index != -1:
		Manager.emit_remove_ris_request(current_selected_index)

func _on_ris_list_selected(index: int):
	current_selected_index = index
	editor_container.visible = true
	Manager.emit_get_ris_info(index)

func _on_response_ris_info(index: int, data: Dictionary):
	if index != current_selected_index:
		return
		
	_bloquear_sinais_spin(true)
	
	if data.has("ligado"): switch_ris_on.button_pressed = data["ligado"]
	if data.has("freq_mhz"): spin_freq.value = data["freq_mhz"]
	if data.has("cell_n"): spin_cell_x.value = data["cell_n"]
	if data.has("cell_m"): spin_cell_y.value = data["cell_m"]
	if data.has("eficiencia"): spin_eficiencia.value = data["eficiencia"]
	if data.has("rotation"): spin_rot.value = data["rotation"]
	
	if data.has("posicao"):
		spin_pos_x.value = data["posicao"].x
		spin_pos_y.value = data["posicao"].y
		spin_pos_z.value = data["posicao"].z
	
	_bloquear_sinais_spin(false)
	
	_atualizar_label_tamanho_fisico_visual_only()
	_atualizar_diagnostico_ris()

func _on_handshake_ris_created(index: int, _name: String):
	list_ris.add_item("RIS %d" % index)
	var last_idx = list_ris.item_count - 1
	list_ris.select(last_idx)
	_on_ris_list_selected(last_idx)

func _on_handshake_ris_deleted(index: int):
	list_ris.remove_item(index)
	current_selected_index = -1
	editor_container.visible = false

func _on_handshake_clear_all():
	list_ris.clear()
	editor_container.visible = false

func _atualizar_diagnostico_ris():
	if current_selected_index == -1 or not Manager.engine or not is_instance_valid(label_status):
		return
		
	var ris_container = Manager.engine.node_ris_container
	if not ris_container or current_selected_index >= ris_container.get_child_count():
		return
		
	var ris_node = ris_container.get_child(current_selected_index)
	
	if Manager.engine.has_method("get_ris_diagnostic_string"):
		var texto_diag = Manager.engine.get_ris_diagnostic_string(ris_node)
		label_status.text = texto_diag
		label_status.modulate = Color.WHITE
