extends Button
## Painel "Gerenciar RIS" - varios RIS; cada um escolhe o RX alvo. Sem sinais:
## tudo vai direto em  Manager.ris_handler.add_ris() / update_ris(i, {...}) / remove_ris(i).

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

var opt_modo: OptionButton         # modo do feixe: regiao do RX (padrao) ou feixe fixo
var opt_alvo: OptionButton          # criado por codigo: escolhe o RX alvo do RIS selecionado
var current_selected_index: int = -1

func _ready() -> void:
	setup_ris_ui()

func setup_ris_ui():
	# Registro direto no Manager: ele chama aplicar_posicao() / recarregar() / set_ocupado()
	Manager.ui_ris = self
	add_to_group("trava_simulacao")

	list_ris.clear()          # tira o item de exemplo do .tscn
	_criar_seletor_alvo()

	switch_ris_on.toggled.connect(func(_is_on): _enviar_dados())
	btn_add.pressed.connect(_on_add_ris_pressed)
	btn_remove.pressed.connect(_on_remove_ris_pressed)
	list_ris.item_selected.connect(_on_ris_list_selected)

	fixar_x.toggled.connect(func(p): _on_fixar_toggled("X", p))
	fixar_y.toggled.connect(func(p): _on_fixar_toggled("Y", p))
	fixar_z.toggled.connect(func(p): _on_fixar_toggled("Z", p))

	_configurar_spinbox_realtime(spin_pos_x, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_pos_y, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_pos_z, 1.0, 10.0)
	_configurar_spinbox_realtime(spin_freq, 10.0, 100.0)
	_configurar_spinbox_realtime(spin_cell_x, 1.0, 8.0)
	_configurar_spinbox_realtime(spin_cell_y, 1.0, 8.0)
	_configurar_spinbox_realtime(spin_eficiencia, 0.05, 0.1)

	# A rotacao agora e automatica (espelho entre TX e RX alvo): o campo so mostra o angulo.
	spin_rot.step = 1.0
	spin_rot.editable = false
	spin_rot.tooltip_text = "Automática: o RIS é orientado como espelho entre o TX e o RX alvo."

	self.toggle_mode = true
	self.toggled.connect(_on_toggle_menu)
	ris_panel.visible = false
	editor_container.visible = false

func _criar_seletor_alvo():
	var linha := HBoxContainer.new()
	var rotulo := Label.new()
	rotulo.text = "RX alvo:"
	opt_alvo = OptionButton.new()
	opt_alvo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	linha.add_child(rotulo)
	linha.add_child(opt_alvo)
	editor_container.add_child(linha)
	editor_container.move_child(linha, switch_ris_on.get_index() + 1)
	opt_alvo.item_selected.connect(_on_alvo_selecionado)
	atualizar_lista_rx()

	var linha2 := HBoxContainer.new()
	var rotulo2 := Label.new()
	rotulo2.text = "Feixe:"
	opt_modo = OptionButton.new()
	opt_modo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt_modo.add_item("Região do RX: energia espalhada pela área")
	opt_modo.add_item("Região do RX: energia concentrada em todos os pontos")
	opt_modo.add_item("Feixe fixo no centro do RX (lóbulo físico)")
	opt_modo.tooltip_text = "Espalhada: a potência focalizada (mancha ≈ (λ·d2)²/A) é dividida pela área do RX; RX maior = média menor por ponto.\nConcentrada: toda a região recebe a potência do lóbulo principal (eq. 19 no centro do RX, o máximo que o painel entrega); nenhum ponto passa disso.\nFeixe fixo: um único lóbulo sinc² apontado para o centro do RX (o mais fiel fisicamente)."
	linha2.add_child(rotulo2)
	linha2.add_child(opt_modo)
	editor_container.add_child(linha2)
	editor_container.move_child(linha2, linha.get_index() + 1)
	opt_modo.item_selected.connect(func(i: int):
		if current_selected_index != -1:
			Manager.ris_handler.update_ris(current_selected_index, {"modo_feixe": ["regiao", "regiao_focada", "fixo"][clampi(i, 0, 2)]}))

func set_ocupado(busy: bool):
	btn_add.disabled = busy
	if btn_remove: btn_remove.disabled = busy
	_set_container_enabled(ris_panel, not busy)
	spin_rot.editable = false

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
	_enviar_dados()

## Le os campos e aplica DIRETO no RIS selecionado; depois rele os valores reais (o handler pode ajusta-los).
func _enviar_dados():
	if current_selected_index == -1: return
	Manager.ris_handler.update_ris(current_selected_index, {
		"ligado": switch_ris_on.button_pressed,
		"freq_mhz": spin_freq.value,
		"ganho_fixo": false,
		"eficiencia": spin_eficiencia.value,
		"cell_n": int(spin_cell_x.value),
		"cell_m": int(spin_cell_y.value),
		"posicao": Vector3(spin_pos_x.value, spin_pos_y.value, spin_pos_z.value),
	})
	_atualizar_label_tamanho()
	spin_rot.set_value_no_signal(Manager.ris_handler.get_ris_info(current_selected_index).get("rotation", 0.0))
	atualizar_diagnostico()

func _on_alvo_selecionado(item: int):
	if current_selected_index == -1: return
	# item 0 = "(nenhum)"; item k = RX de indice k-1
	Manager.ris_handler.update_ris(current_selected_index, {"alvo_index": item - 1})
	_preencher_campos(Manager.ris_handler.get_ris_info(current_selected_index))

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

## Chamado direto pelo Manager quando o clique no plano foi resolvido.
func aplicar_posicao(new_pos: Vector3):
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
	var r: Dictionary = Manager.ris_handler.add_ris()      # nasce desligado; alvo padrao = 1o RX
	list_ris.add_item(r.name)
	list_ris.select(r.index)
	_on_ris_list_selected(r.index)

func _on_remove_ris_pressed():
	if current_selected_index == -1: return
	if Manager.ris_handler.remove_ris(current_selected_index):
		list_ris.remove_item(current_selected_index)
		current_selected_index = -1
		editor_container.visible = false

func _on_ris_list_selected(index: int):
	current_selected_index = index
	editor_container.visible = true
	atualizar_lista_rx()
	_preencher_campos(Manager.ris_handler.get_ris_info(index))

func _preencher_campos(data: Dictionary):
	if data.is_empty(): return
	var controles = [spin_freq, spin_eficiencia, spin_cell_x, spin_cell_y, spin_pos_x, spin_pos_y, spin_pos_z, spin_rot]
	for s in controles: s.set_block_signals(true)
	switch_ris_on.set_block_signals(true)

	switch_ris_on.button_pressed = data.get("ligado", false)
	spin_freq.value = data.get("freq_mhz", 2400.0)
	spin_cell_x.value = data.get("cell_n", 1)
	spin_cell_y.value = data.get("cell_m", 1)
	spin_eficiencia.value = data.get("eficiencia", 0.9)
	spin_rot.value = data.get("rotation", 0.0)
	if data.has("posicao"):
		spin_pos_x.value = data["posicao"].x
		spin_pos_y.value = data["posicao"].y
		spin_pos_z.value = data["posicao"].z
	if opt_alvo != null:
		opt_alvo.select(int(data.get("alvo_index", -1)) + 1)
	if opt_modo != null:
		opt_modo.select(maxi(0, ["regiao", "regiao_focada", "fixo"].find(String(data.get("modo_feixe", "regiao")))))

	for s in controles: s.set_block_signals(false)
	switch_ris_on.set_block_signals(false)

	_atualizar_label_tamanho()
	atualizar_diagnostico()

func _atualizar_label_tamanho():
	var freq = spin_freq.value
	if freq <= 0: return
	var cell_size_cm = ((300.0 / freq) / 2.0) * 100.0
	var total_w_m = cell_size_cm * spin_cell_x.value / 100.0
	var total_h_m = cell_size_cm * spin_cell_y.value / 100.0
	var area_total = total_w_m * total_h_m
	label_tamanho.text = "Célula unitária: \n%.1f x %.1f cm\n\nÁrea Total (m²): \n%.1f x %.1f = %.2f" % [
		cell_size_cm, cell_size_cm, total_w_m, total_h_m, area_total
	]

## Repopula o seletor com os RX existentes (chamado quando um RX e criado/removido).
func atualizar_lista_rx():
	if opt_alvo == null or Manager.rx_handler == null: return
	opt_alvo.clear()
	opt_alvo.add_item("(nenhum)")
	for nome in Manager.rx_handler.nomes():
		opt_alvo.add_item(nome)
	if current_selected_index >= 0 and Manager.ris_handler != null:
		var info: Dictionary = Manager.ris_handler.get_ris_info(current_selected_index)
		opt_alvo.select(int(info.get("alvo_index", -1)) + 1)
		atualizar_diagnostico()
	else:
		opt_alvo.select(0)

func atualizar_diagnostico():
	if current_selected_index == -1 or Manager.ris_handler == null or not is_instance_valid(label_status):
		return
	label_status.text = Manager.ris_handler.diagnostico(current_selected_index)
	label_status.modulate = Color.WHITE

## Reconstroi a lista a partir do Manager.ris_handler (apos carregar um save).
func recarregar():
	list_ris.clear()
	current_selected_index = -1
	editor_container.visible = false
	if Manager.ris_handler != null:
		for ris in Manager.ris_handler.ris_cache:
			list_ris.add_item(ris.name)
	atualizar_lista_rx()
