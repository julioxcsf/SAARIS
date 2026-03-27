extends Node3D

@onready var node_tx = $"../Node_TX"
@onready var node_rx = $"../Node_RX"


# Inicializa as conexões de sinais para gerenciar o ciclo de vida do RIS.
func _ready():
	Manager.request_add_ris.connect(_add_ris)
	Manager.request_remove_ris.connect(_remove_ris)
	Manager.request_update_ris.connect(_update_ris)
	Manager.request_get_ris_info.connect(_get_ris_info)
	Manager.request_update_tx.connect(_on_external_update)
	Manager.request_update_target.connect(_on_external_update)

# Força o recálculo do alinhamento e atualização da UI quando o TX ou RX mudam.
func _on_external_update(_index: int, _params: Dictionary):
	for i in range(get_child_count()):
		var ris = get_child(i)
		_recalculate_ris_logic(ris)
		_get_ris_info(i)

# Cria e configura um novo nó RIS, permitindo cópia de dados existentes.
func _add_ris(copy_data: Variant = null):
	var new_ris = Manager.ris_scene.instantiate()
	add_child(new_ris)
	
	var freq = 2400.0
	var ganho_fixo = false
	var ganho = 2.0
	var eficiencia = 0.9
	var cell_n = 1
	var cell_m = 1
	var pos = Vector3(0, 5.0, 0)
	
	if copy_data != null and copy_data is Dictionary:
		if copy_data.has("freq_mhz"): freq = copy_data["freq_mhz"]
		if copy_data.has("ganho_fixo"): ganho_fixo = copy_data["ganho_fixo"]
		if copy_data.has("ganho"): ganho = copy_data["ganho"]
		if copy_data.has("eficiencia"): eficiencia = copy_data["eficiencia"]
		if copy_data.has("cell_n"): cell_n = copy_data["cell_n"]
		if copy_data.has("cell_m"): cell_m = copy_data["cell_m"]
		if copy_data.has("posicao"): pos = copy_data["posicao"]
		
		# REGRA DE NASCIMENTO: Calcula N e M iniciais baseados na área alvo se disponível.
		if copy_data.has("area_alvo"):
			var lambda = 300.0 / freq
			var cell_area = pow(lambda / 2.0, 2)
			cell_n = int(sqrt(copy_data["area_alvo"] / cell_area))
			cell_m = cell_n
	
	new_ris.position = pos
	new_ris.set_meta("freq_mhz", freq)
	new_ris.set_meta("ganho_fixo", ganho_fixo)
	new_ris.set_meta("ganho", ganho)
	new_ris.set_meta("eficiencia", eficiencia)
	new_ris.set_meta("cell_n", cell_n)
	new_ris.set_meta("cell_m", cell_m)
	
	_recalculate_ris_logic(new_ris)
	
	var idx = new_ris.get_index()
	new_ris.name = "RIS_" + str(idx)
	new_ris.add_to_group("reflectors")
	
	Manager.handshake_ris_created.emit(idx, "RIS %d" % idx)
	_get_ris_info(idx)

# Remove o nó RIS correspondente ao índice e notifica o sistema.
func _remove_ris(index: int):
	if index < get_child_count():
		get_child(index).queue_free()
		await get_tree().process_frame 
		Manager.handshake_ris_deleted.emit(index)

# Atualiza os parâmetros do RIS, garantindo a consistência física com o RX.
func _update_ris(index: int, params: Dictionary):
	if index >= get_child_count(): return
	var ris = get_child(index)
	
	var mudou_n = params.has("cell_n") and params["cell_n"] != ris.get_meta("cell_n")
	var mudou_m = params.has("cell_m") and params["cell_m"] != ris.get_meta("cell_m")
	
	var mudou_ganho = false
	if params.has("ganho"):
		var ganho_antigo = ris.get_meta("ganho")
		if ganho_antigo == null:
			mudou_ganho = true
		else:
			# Ignora diferenças de arredondamento e anula a mudança de ganho se N ou M mudaram manualmente.
			if abs(params["ganho"] - ganho_antigo) > 0.01 and not (mudou_n or mudou_m):
				mudou_ganho = true
	
	if params.has("posicao"): ris.position = params["posicao"]
	
	# Só aplica a rotação customizada se enviada; a variável global não existe mais.
	if params.has("rotation"):
		ris.rotation_degrees.y = params["rotation"]
	
	for key in params.keys():
		ris.set_meta(key, params[key])
	
	var freq = ris.get_meta("freq_mhz")
	var cell_area = pow((300.0 / freq) / 2.0, 2)
	
	if node_rx.get_child_count() > 0 and node_rx.get_child(0) != null:
		var rx = node_rx.get_child(0)
		var area_rx = rx.get_meta("width") * rx.get_meta("length")
		
		if mudou_ganho:
			var area_alvo = area_rx * params["ganho"]
			var resultado = menor_area_possivel_com_celulas_RIS(area_alvo, cell_area)
			ris.set_meta("cell_n", resultado[0])
			ris.set_meta("cell_m", resultado[1])
			
		elif ris.get_meta("ganho_fixo"):
			var area_alvo = area_rx * ris.get_meta("ganho")
			if mudou_n:
				var n = ris.get_meta("cell_n")
				ris.set_meta("cell_m", max(1, ceil(area_alvo / (n * cell_area))))
			elif mudou_m:
				var m = ris.get_meta("cell_m")
				ris.set_meta("cell_n", max(1, ceil(area_alvo / (m * cell_area))))
				
		var area_final = (ris.get_meta("cell_n") * ris.get_meta("cell_m")) * cell_area
		ris.set_meta("ganho", area_final / area_rx)
	
	else:
		ris.set_meta("ganho", null)

	_recalculate_ris_logic(ris)
	_get_ris_info(index)


# Centraliza a chamada para aplicar as propriedades físicas e visuais.
func _recalculate_ris_logic(ris: Node3D):
	_apply_physics_to_mesh(ris)
	_align_ris_bisector(ris)


# Atualiza a escala da malha e recalcula a razão real do RIS baseada no número de células.
func _apply_physics_to_mesh(ris: Node3D):
	var freq = ris.get_meta("freq_mhz")
	var lambda = 300.0 / freq
	var cell_size = lambda / 2.0
	var area_cell = cell_size * cell_size
	
	var n = ris.get_meta("cell_n")
	var m = ris.get_meta("cell_m")
	
	if node_rx.get_child_count() > 0:
		var rx = node_rx.get_child(0)
		var area_rx = rx.get_meta("width") * rx.get_meta("length")
		
		var area_real = (n * m) * area_cell
		ris.set_meta("area_real", area_real)
		ris.set_meta("ganho", area_real / area_rx)

	ris.scale = Vector3(n * cell_size, m * cell_size, 0.05)

# Determina a configuração mais quadrada (N x M) para atingir a área alvo.
func menor_area_possivel_com_celulas_RIS(area_alvo: float, area_celula: float) -> Array:
	var total_celulas = ceil(area_alvo / area_celula)
	if total_celulas <= 1: return [1, 1]
	
	var n = int(round(sqrt(total_celulas)))
	if n < 1: n = 1
	var m = int(ceil(total_celulas / float(n)))
	
	return [n, m]
	
# Calcula e aplica a rotação do RIS para atuar como um espelho entre TX e RX.
func _align_ris_bisector(ris: Node3D):
	if node_tx.get_child_count() == 0 or node_rx.get_child_count() == 0: return
	
	var tx_pos = node_tx.get_child(0).global_position
	var rx_pos = node_rx.get_child(0).global_position
	var ris_pos = ris.global_position
	
	var vec_tx = (tx_pos - ris_pos).normalized()
	var vec_rx = (rx_pos - ris_pos).normalized()
	var bisector = (vec_tx + vec_rx).normalized()
	
	if bisector.length() > 0.1:
		ris.look_at(ris_pos + bisector, Vector3.UP)


# Compila os metadados do RIS e os envia para atualização da Interface Gráfica.
func _get_ris_info(index: int):
	if index < get_child_count():
		var ris = get_child(index)
		var n = ris.get_meta("cell_n")
		var m = ris.get_meta("cell_m")
		var ef = ris.get_meta("eficiencia")
		
		var razao_real = ris.get_meta("ganho")
		var ganho_db = null
		
		if razao_real != null and (razao_real * ef) > 0:
			ganho_db = 10.0 * (log(razao_real * ef) / log(10.0))
		
		var data = {
			"freq_mhz": ris.get_meta("freq_mhz"),
			"ganho_fixo": ris.get_meta("ganho_fixo"),
			"ganho": razao_real,
			"eficiencia": ef,
			"cell_n": n,
			"cell_m": m,
			"ganho_real_db": ganho_db,
			"posicao": ris.position,
			"rotation": ris.rotation_degrees.y
		}
		Manager.response_ris_info.emit(index, data)
