extends Node3D

# 22 / 11 / 2025
# GTA - UFRJ

@onready var node_tx_container = $"../Node_TX"
@onready var node_rx_container = get_node_or_null("../Node_RX")
@onready var node_ris_container = get_node_or_null("../Node_RIS")
@onready var scene_3d_mapa = $"../Scene3D"

@export_group("Simulação - Performance & Qualidade")
@export var LOS_ativado = true
@export var reflection_ativado = true
@export var diffraction_ativado = true
@export var resolution = Vector2i(256, 256)
@export var pixels_per_frame = 1024
@export var max_reflections: int = 5
@export var offset_colider: float = 0.01
@export var reflection_loss_db: float = 5.0

@export_group("Física de Rádio")
@export var path_loss_exponent: float = 2.8
@export var potencia_tx_dbm: float = 20.0
@export var frequencia_mhz: float = 2400.0
@export var min_sinal_dbm: float = -120.0
@export var max_sinal_dbm: float = -30.0
@export var critical_sinal_dbm: float = -85.0

@export_group("Cores do Mapa de Calor")
@export var min_sinal_color: Color = Color.BLUE
@export var critical_sinal_color: Color = Color.GREEN 
@export var max_sinal_color: Color = Color.RED
@export var building_alpha: float = 1.0:
	set(value):
		building_alpha = clamp(value, 0.0, 1.0)
		ajustar_transparencia_predios(building_alpha)

var _baseline_power_map_watts: PackedFloat32Array = []
var _debug_los_only_watts: PackedFloat32Array = []
var _debug_diff_only_watts: PackedFloat32Array = []
var DEBUG_PROPAGACAO = true

var _plane_size: Vector2
var _map_offset: Vector3 = Vector3.ZERO
var _chao_node: Node3D
var _chao_body: RID
var _chao_parent: Node3D
var _chao_static_body: StaticBody3D
var last_collider_rid
var _space_state: PhysicsDirectSpaceState3D

var _tx_nodes: Array[Node3D] = []
var _tx_rids: Array[RID] = []
var _aabb_cache: Dictionary = {}

var result_image: Image
var result_texture: ImageTexture
var _power_map_watts: PackedFloat32Array

var tx_index_LOS = 0
var _tx_parents: Array[Node3D] = []
var _tx_static_bodies: Array[RID] = []

var _current_pixel = Vector2i(0, 0)
var simular = false
var simulacao_comecou = false

var distancia_max_los_minimo: float = 5000.0
var min_watts: float = 0.0
var lambda_m: float = 1.0
var _start_time_msec = 0.0
var _last_stats_update_time: float = 0.0
var simulatioon_start_time: float = 0.0

var tx_nodes: Array[Node3D] = []
var chao_mesh: MeshInstance3D = null
var chao_body_rid: RID

func _ready():
	Manager.engine = self
	connect_UI_inputs()


func connect_UI_inputs() -> void:
	# Inputs de controle
	Manager.request_start.connect(_on_manager_start_requested)
	Manager.request_stop.connect(_on_manager_stop_requested)
	Manager.request_cancel.connect(_on_manager_cancel_requested)
	Manager.request_resolution_update.connect(_on_resolution_updated)
	Manager.request_heatmap_config.connect(_on_heatmap_config_requested)
	Manager.request_update_ris.connect(_on_ris_updated_post_sim)
	Manager.request_simulator_config.connect(_on_config_received)
	Manager.request_import.connect(setup_and_start_v2)
	
	# Reinicia a simulação se alguém mexer nas antenas
	Manager.handshake_tx_created.connect(func(idx, nome): if simulacao_comecou: setup_and_start_v2())
	Manager.handshake_tx_deleted.connect(func(idx): if simulacao_comecou: setup_and_start_v2())
	
	# GATILHOS DE PÓS-PROCESSAMENTO INSTANTÂNEO (RIS e RX)
	Manager.request_update_ris.connect(_trigger_post_process_args)
	Manager.request_add_ris.connect(func(data): _trigger_post_process())
	Manager.request_remove_ris.connect(func(idx): _trigger_post_process())
	Manager.request_update_target.connect(_trigger_post_process_args)
	Manager.request_reconstruct_target.connect(func(data): _trigger_post_process())


# Dispara recálculo instantâneo com argumentos.
func _trigger_post_process_args(_arg1 = null, _arg2 = null):
	_trigger_post_process()

# Recalcula a camada extra apenas se o backup existir.
func _trigger_post_process():
	if not simular and not _baseline_power_map_watts.is_empty():
		recalculate_ris_post_process()


# Prepara o cenário de simulação verificando dependências físicas.
func setup_simulation():
	var chao = scene_3d_mapa.find_child("ChaoMapaDeCalor", true, false)
	
	if not chao or not chao is MeshInstance3D:
		push_error("[Simulator] Chão não encontrado em Scene3D! Verifique se o mapa foi carregado.")
		return
	
	_space_state = get_world_3d().direct_space_state
	_chao_parent = chao
	
	if chao.mesh:
		var aabb = chao.mesh.get_aabb()
		_plane_size = Vector2(aabb.size.x, aabb.size.z)
		_map_offset = aabb.position
	else:
		push_error("O nó do chão não possui uma malha (mesh)!")
		return
	
	var chao_sb = chao.find_child("StaticBody*", true, false)
	if chao_sb:
		_chao_static_body = chao_sb
		_tx_rids.append(_chao_static_body.get_rid())
	
	_tx_nodes.clear()
	_tx_rids.clear()
	
	for tx in node_tx_container.get_children():
		var ligado = tx.get("ligado")
		if tx is Node3D and ligado != false:
			_tx_nodes.append(tx)
			var tx_collisions = tx.find_children("*", "CollisionObject3D", true)
			for col in tx_collisions:
				_tx_rids.append(col.get_rid())
			_tx_rids.append(_chao_static_body.get_rid())
	
	_aabb_cache.clear()
	_scan_obstacles_recursive(scene_3d_mapa)
	
	if _tx_nodes.is_empty() or not _space_state:
		push_error("Abortando: Condições mínimas não atendidas.")
		return
	
	if not result_image or result_image.get_size() != resolution:
		result_image = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
		result_texture = ImageTexture.create_from_image(result_image)
	
	_power_map_watts.resize(resolution.x * resolution.y)
	_power_map_watts.fill(0.0)
	result_image.fill(Color(min_sinal_dbm, 0, 0, 1))
	
	var material = ShaderMaterial.new()
	material.shader = load("res://Shaders/mapa_calor_shader_material.gdshader")
	_chao_parent.material_override = material

# Inicia o cálculo da propagação do sinal.
func start_simulation():
	_update_shader_visualization_parameters()
	_update_visual_texture_from_watts()
	
	simulacao_comecou = true
	_start_time_msec = Time.get_ticks_msec()
	_last_stats_update_time = 0.0
	simulatioon_start_time = Time.get_ticks_msec()
	
	_current_pixel = Vector2i(0,0)
	Manager.is_simulating = true

# Método condensado para reiniciar e rodar a simulação rapidamente.
func setup_and_start_v2():
	var chao = scene_3d_mapa.find_child("ChaoMapaDeCalor", true, false)
	
	if not chao or not chao is MeshInstance3D:
		push_error("[Simulator] Chão não encontrado em Scene3D! Verifique se o mapa foi carregado.")
		return
	
	_space_state = get_world_3d().direct_space_state
	_chao_parent = chao
	
	if chao.mesh:
		var aabb = chao.mesh.get_aabb()
		_plane_size = Vector2(aabb.size.x, aabb.size.z)
		_map_offset = aabb.position
	else:
		push_error("O nó do chão não possui uma malha (mesh)!")
		return
	
	var chao_sb = chao.find_child("StaticBody*", true, false)
	if chao_sb:
		_chao_static_body = chao_sb
		_tx_rids.append(_chao_static_body.get_rid())
	
	_tx_nodes.clear()
	_tx_rids.clear()
	
	for tx in node_tx_container.get_children():
		var ligado = tx.get("ligado")
		if tx is Node3D and ligado != false:
			_tx_nodes.append(tx)
			var tx_collisions = tx.find_children("*", "CollisionObject3D", true)
			for col in tx_collisions:
				_tx_rids.append(col.get_rid())
			_tx_rids.append(_chao_static_body.get_rid())
	
	_aabb_cache.clear()
	_scan_obstacles_recursive(scene_3d_mapa)
	
	if _tx_nodes.is_empty() or not _space_state:
		return
	
	if not result_image or result_image.get_size() != resolution:
		result_image = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
		result_texture = ImageTexture.create_from_image(result_image)
	
	var total_pixels = resolution.x * resolution.y
	_power_map_watts.resize(total_pixels)
	_power_map_watts.fill(0.0)
	
	_debug_los_only_watts.resize(total_pixels)
	_debug_los_only_watts.fill(0.0)
	
	_debug_diff_only_watts.resize(total_pixels)
	_debug_diff_only_watts.fill(0.0)
	
	result_image.fill(Color(min_sinal_dbm, 0, 0, 1))
	
	var material = ShaderMaterial.new()
	material.shader = load("res://Shaders/mapa_calor_shader_material.gdshader")
	_chao_parent.material_override = material
	
	_update_shader_visualization_parameters()
	_update_visual_texture_from_watts()
	
	simulacao_comecou = true
	_start_time_msec = Time.get_ticks_msec()
	_last_stats_update_time = 0.0
	
	_current_pixel = Vector2i(0,0)
	Manager.is_simulating = true


# Busca as colisões de todos os obstáculos do cenário no início.
func _scan_obstacles_recursive(node):
	if node is StaticBody3D:
		var aabb = _calculate_aabb_logic(node)
		if aabb.size != Vector3.ZERO:
			_aabb_cache[node.get_rid()] = aabb
	for child in node.get_children():
		_scan_obstacles_recursive(child)


# Loop principal de processamento do simulador.
func _process(_delta):
	if not simular: 
		return
	
	if not is_instance_valid(_chao_parent):
		simular = false
		Manager.is_simulating = false
		push_error("[SAARIS] Simulação abortada: Referência do chão foi perdida.")
		return
	
	var calculated = 0
	while calculated < pixels_per_frame and _current_pixel.y < resolution.y:
		var target_pos_world = _pixel_to_world(_current_pixel)
		
		for i in range(_tx_nodes.size()):
			var tx = _tx_nodes[i]
			var p_dbm = tx.get("potencia_dbm") if tx.has_method("get") else potencia_tx_dbm
			var f_mhz = tx.get("freq_mhz") if tx.has_method("get") else frequencia_mhz
			
			var tx_pos = tx.global_position
			var dir_to_pixel = (target_pos_world - tx_pos).normalized()
			
			lambda_m = 300.0 / f_mhz
			
			_calculate_pixel_signal(p_dbm, 0, tx_pos, dir_to_pixel, _tx_rids, 0.0)
		
		var current_time = Time.get_ticks_msec()
		var tempo_core_segundos = (Time.get_ticks_msec() - _start_time_msec) / 1000.0
		if current_time - _last_stats_update_time > 1000.0:
			_last_stats_update_time = current_time
			_emitir_relatorio_atualizado()
		
		_advance_pixel()
		calculated += 1
	
	_update_visual_texture_from_watts()


# Controla o fluxo da matriz de pixels e encerra a simulação se concluído.
func _advance_pixel():
	_current_pixel.x += 1
	if _current_pixel.x >= resolution.x:
		_current_pixel.x = 0
		_current_pixel.y += 1
		Manager.emit_signal("simulation_progress_update", (float(_current_pixel.y) / resolution.y) * 100.0)
	
	if _current_pixel.y >= resolution.y:
		simular = false
		Manager.is_simulating = false
		_baseline_power_map_watts = _power_map_watts.duplicate()
		recalculate_ris_post_process()
		_emitir_relatorio_atualizado()
		_update_visual_texture_from_watts()
		export_profile_csv(0.0, 500.0, 0.0)


# Função centralizada para Perda de Trajeto (Log-Distance Path Loss)
func _calcular_perda_trajeto_fspl_db(distancia_m: float) -> float:
	if distancia_m <= 0.001: return 0.0
	
	# Perda de referência a 1 metro (l0)
	var l0 = 20.0 * log(1.0)/log(10.0) + 20.0 * log(frequencia_mhz)/log(10.0) - 27.55
	
	# Soma o expoente de perda do ambiente
	var fspl_db = l0 + (10.0 * path_loss_exponent * log(distancia_m)/log(10.0))
	
	return fspl_db

func _verifica_LOS(origin: Vector3, target_pos: Vector3, exclude_list: Array): # TESTANDO 27/01/26 nova função
	# O raio vai da origem até o alvo. 
	# Como o alvo (chão) está na exclude_list, se não houver obstáculo,
	# intersect_ray retornará vazio (Dicionário {}). Isso significa LOS LIVRE.
	var query = PhysicsRayQueryParameters3D.create(origin, target_pos)
	query.exclude = exclude_list
	
	# OTIMIZAÇÃO: Não precisamos mais checar colisao com Area3D se for só prédio
	query.collide_with_areas = false 
	
	return _space_state.intersect_ray(query)

# Verifica obstrução na primeira Zona de Fresnel.
func _verifica_1_zona_fresnel(origin: Vector3, direction: Vector3, target_pos: Vector3, emissor_RID: RID):
	var target_dist = target_pos.distance_to(origin)
	var fresnel_radius = 0.5 * sqrt(lambda_m * target_dist)
	if fresnel_radius < 0.1: 
		return false
	
	var params = PhysicsShapeQueryParameters3D.new()
	var shape = CylinderShape3D.new()
	shape.height = target_dist
	shape.radius = fresnel_radius
	params.shape = shape
	
	var mid_point = origin + direction * (target_dist / 2.0)
	var transform = Transform3D().looking_at(mid_point + direction, Vector3.UP)
	transform.origin = mid_point
	
	var up = direction.normalized()
	var right = up.cross(Vector3(0, 1, 0))
	if right.length() < 0.001:
		right = up.cross(Vector3(1, 0, 0))
	var forward = right.cross(up).normalized()
	var basis = Basis()
	basis.x = right.normalized()
	basis.y = up.normalized()
	basis.z = forward.normalized()
	transform.basis = basis
	params.transform = transform
	params.exclude = [emissor_RID,_chao_static_body]
	
	return _space_state.intersect_shape(params, 8)


# Dispara raios estocásticos e calcula a física da propagação de forma recursiva.
func _calculate_pixel_signal(pot_tx_dBm: float, collisions: int, origin: Vector3, ray_direction: Vector3, exclude_list: Array, distance_traveled: float):
	var target_position = _get_ground_intersection(origin, ray_direction)
	var result_los = _verifica_LOS(origin, target_position, exclude_list)
	
	if collisions > max_reflections:
		return
	
	# Se o raio colidiu
	if not result_los.is_empty():
		var hit_pos = result_los["position"]
		var hit_normal = result_los["normal"]
		var dist_to_hit = origin.distance_to(hit_pos)
		
		ray_direction = ray_direction.normalized()
		ray_direction = ray_direction.bounce(hit_normal)
		distance_traveled += dist_to_hit
		
		if reflection_ativado:
			# o raio continua viajanto apos a reflexão
			_calculate_pixel_signal(pot_tx_dBm, collisions+1, hit_pos, ray_direction, exclude_list, distance_traveled)
		
		if diffraction_ativado:
			# calcula a perda por difração no ponto de interseção com o chão
			var tx_real_pos = _tx_nodes[0].global_position
			var watts_finais = _calculate_radio_total_itu(tx_real_pos, target_position, pot_tx_dBm, collisions+1)
			_accumulate_power_at_pos(target_position, watts_finais, "DIFF")
		return 
			
	# Raio não colidiu
	else:
		if LOS_ativado and collisions == 0 or reflection_ativado and collisions > 0:
			var dist_to_pixel = origin.distance_to(target_position)
			var total_path_distance = distance_traveled + dist_to_pixel
			var fspl_db = _calcular_perda_trajeto_fspl_db(total_path_distance)
			
			var fresnel_loss_db = 0.0
			var check_1_zona = _verifica_1_zona_fresnel(origin, ray_direction, target_position, exclude_list[0])
			if check_1_zona:
				fresnel_loss_db = 6.0
			
			# Potência Final em dBm
			# Fórmula: Potência = TX - (N_Reflexoes * Perda_Ref) - Perda_Distancia - Perda_Fresnel
			var pot_final_dbm = pot_tx_dBm - (collisions * reflection_loss_db) - fspl_db - fresnel_loss_db
			_accumulate_power_at_pos(target_position, RFMath.dbm_to_watts(pot_final_dbm), "LOS")


# Converte coordenadas do pixel para o espaço mundial no eixo Y=0.
func _pixel_to_world(px: Vector2i) -> Vector3:
	if not is_instance_valid(_chao_parent):
		return Vector3.ZERO
		
	var uv_x = ((float(px.x) + 0.5) / resolution.x) - 0.5
	var uv_y = ((float(px.y) + 0.5) / resolution.y) - 0.5
	var local_x = uv_x * _plane_size.x
	var local_z = uv_y * _plane_size.y
	var world_pos = _chao_parent.to_global(Vector3(local_x, 0, local_z))
	world_pos.y -= 0.05
	return world_pos

# Calcula o ponto exato onde o raio toca o chão (Y=0)
func _get_ground_intersection(origin: Vector3, direction: Vector3) -> Vector3:
	if abs(direction.y) < 0.0001 or direction.y > 0:
		return Vector3.ZERO 
	
	var t = -origin.y / direction.y
	return origin + direction * t

# Soma as energias de múltiplas contribuições de sinal em um único pixel.
func _accumulate_power_at_pos(global_pos: Vector3, watts: float, tag: String = "TOTAL"):
	var local_pos = _chao_parent.to_local(global_pos)
	var uv_x = (local_pos.x / _plane_size.x) + 0.5
	var uv_y = (local_pos.z / _plane_size.y) + 0.5
	var px = int(uv_x * resolution.x)
	var py = int(uv_y * resolution.y)
	
	if px >= 0 and px < resolution.x and py >= 0 and py < resolution.y:
		var idx = py * resolution.x + px
		_power_map_watts[idx] += watts
		
		if tag == "LOS": _debug_los_only_watts[idx] += watts
		elif tag == "DIFF": _debug_diff_only_watts[idx] += watts

# Coleta a potência no pixel correspondente à posição de mundo solicitada.
func get_power_at_world_pos(world_pos: Vector3) -> float:
	if _power_map_watts.is_empty(): return -200.0
	
	var local_pos = _chao_parent.to_local(world_pos)
	var uv_x = (local_pos.x / _plane_size.x) + 0.5
	var uv_y = (local_pos.z / _plane_size.y) + 0.5
	
	var px = int(uv_x * resolution.x)
	var py = int(uv_y * resolution.y)
	
	if px >= 0 and px < resolution.x and py >= 0 and py < resolution.y:
		var idx = py * resolution.x + px
		var watts = _power_map_watts[idx]
		return RFMath.watts_to_dbm(watts) if watts > 0 else -200.0
		
	return -200.0

# Aplica as potências calculadas na imagem que serve de textura no chão.
func _update_visual_texture_from_watts():
	if result_image == null or result_image.get_size() != resolution:
		result_image = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
		
	if result_texture == null:
		result_texture = ImageTexture.create_from_image(result_image)

	for i in range(_power_map_watts.size()):
		var w = _power_map_watts[i]
		if w <= 0.0: continue
		var dbm = RFMath.watts_to_dbm(w)
		
		var y = int(i / resolution.x)
		var x = int(i % resolution.x)
		
		x = clamp(x, 0, resolution.x - 1)
		y = clamp(y, 0, resolution.y - 1)
		
		result_image.set_pixel(x, y, Color(dbm, 0, 0)) 
			
	result_texture.update(result_image)


# Helpers para extração correta de AABB para colisões otimizadas.
func _calculate_aabb_logic(collider_body: PhysicsBody3D) -> AABB:
	var parent_node = collider_body.get_parent()
	
	if not parent_node:
		push_error("Obstáculo %s não tem um nó PAI!" % collider_body.name)
		return AABB()

	if parent_node is MeshInstance3D:
		return parent_node.global_transform * parent_node.get_aabb()

	for child in parent_node.get_children():
		if child is MeshInstance3D:
			return child.global_transform * child.get_aabb()

	for child in collider_body.get_children():
		if child is MeshInstance3D:
			return child.global_transform * child.get_aabb()

	for child in collider_body.get_children():
		if child is CollisionShape3D:
			if child.shape and child.shape.has_method("get_aabb"):
				var local_aabb = child.shape.get_aabb()
				return child.global_transform * local_aabb
			else:
				push_error("FALHA AABB: Estrutura inválida na cena.")
				return AABB()
	
	return AABB()


# Método de Deygout Trifurcado (ITU-R P.526) para obstáculos.
# Encontra o obstáculo principal em 3 direções e soma as energias.
func _calculate_radio_total_itu(origem_tx: Vector3, destino_rx: Vector3, p_antena_dBm: float, n_reflexoes: int) -> float:
	var d_total = origem_tx.distance_to(destino_rx)
	if d_total < 0.1: return 0.0

	var fspl_dB = _calcular_perda_trajeto_fspl_db(d_total)
	var loss_reflexao_dB = n_reflexoes * reflection_loss_db
	var pot_chegada_los = p_antena_dBm - fspl_dB - loss_reflexao_dB
	
	var query = PhysicsRayQueryParameters3D.create(origem_tx, destino_rx)
	query.exclude = _tx_rids
	var result = _space_state.intersect_ray(query)
	
	if result.is_empty():
		return RFMath.dbm_to_watts(pot_chegada_los)

	var rid = result.collider.get_rid()
	var hit_pos = result.position
	var hit_normal = result.normal 
	var aabb = _aabb_cache.get(rid, _calculate_aabb_logic(result.collider))
	
	var up_vec = Vector3.UP
	var side_vec = hit_normal.cross(up_vec).normalized()

	var direcoes = [
		{"nome": "TOPO", "vec": up_vec, "max": (aabb.end.y + 0.5) - hit_pos.y},
		{"nome": "ESQ",  "vec": side_vec, "max": max(aabb.size.x, aabb.size.z) * 1.5},
		{"nome": "DIR",  "vec": -side_vec, "max": max(aabb.size.x, aabb.size.z) * 1.5}
	]
	
	var energia_total_watts = 0.0
	
	for data in direcoes:
		var edge_point = _binary_search_edge(origem_tx, hit_pos, data.vec, data.max, rid, hit_normal, data.nome)
		
		var d1 = origem_tx.distance_to(hit_pos)
		var d2 = hit_pos.distance_to(destino_rx)
		
		var los_pos_ideal = origem_tx.lerp(destino_rx, d1 / (d1 + d2))
		var h = edge_point.distance_to(los_pos_ideal)
		var v = RFMath.calculate_diffraction_parameter_v(h, d1, d2, lambda_m)
		var loss_diff_db = RFMath.calculate_knife_edge_loss_db(v) if v > -0.7 else 0.0
		
		var pot_caminho_dbm = pot_chegada_los - loss_diff_db
		energia_total_watts += RFMath.dbm_to_watts(pot_caminho_dbm)
			
	return energia_total_watts

# Busca binária pela extremidade de uma malha para calcular a difração.
func _binary_search_edge(origin: Vector3, start_point: Vector3, direction_vec: Vector3, max_dist: float, target_rid: RID, normal: Vector3, debug_nome: String) -> Vector3:
	var low = 0.0
	var high = max_dist
	var iterations = 20 
	
	for i in range(iterations):
		var mid = (low + high) / 2.0
		var test_point = start_point + direction_vec * mid
		var safety_point = test_point - (normal * 0.02)
		
		var query = PhysicsRayQueryParameters3D.create(origin, safety_point)
		var result = _space_state.intersect_ray(query)
		
		var hit_target = false
		if not result.is_empty() and result.collider.get_rid() == target_rid:
			hit_target = true
			
		if hit_target:
			low = mid
		else:
			high = mid

	return start_point + direction_vec * high


# Converte a posição 3D para o pixel da textura e pinta o valor bruto.
func _paint_pixel_at_global_pos(global_pos: Vector3, signal_dbm: float):
	if signal_dbm < min_sinal_dbm:
		return
		
	var local_pos = global_pos
	
	var uv_x = (local_pos.x*+1.0 / _plane_size.x) + 0.5
	var uv_y = (local_pos.z*+1.0 / _plane_size.y) + 0.5
	
	var px = int(uv_x * resolution.x)
	var py = int(uv_y * resolution.y)

	if px < 0 or px >= resolution.x or py < 0 or py >= resolution.y:
		Manager.log_error("Pintura REJEITADA. Raio pousou fora do mapa. global_pos: %s, px: %s, py: %s" % [global_pos, px, py])
		return

	var current_signal = result_image.get_pixel(px, py).r
	if signal_dbm > current_signal:
		result_image.set_pixel(px, py, Color(signal_dbm, 0, 0))


# Exporta um gradiente visual amigável da textura bruta baseada em dBm.
func _create_colored_image_for_export() -> Image:
	var colored_image = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RGBA8)

	var grad = Gradient.new()
	var critical_point_normalized = inverse_lerp(min_sinal_dbm, max_sinal_dbm, critical_sinal_dbm)
	critical_point_normalized = clamp(critical_point_normalized, 0.0, 1.0)
	grad.offsets = PackedFloat32Array([0.0, critical_point_normalized, 1.0])
	grad.colors = PackedColorArray([min_sinal_color, critical_sinal_color, max_sinal_color])
	
	for y in resolution.y:
		for x in resolution.x:
			var sinal_recebido_dbm = result_image.get_pixel(x, y).r
			var normalized_strength = inverse_lerp(min_sinal_dbm, max_sinal_dbm, sinal_recebido_dbm)
			normalized_strength = clamp(normalized_strength, 0.0, 1.0)

			var final_color = grad.sample(normalized_strength)
			colored_image.set_pixel(x, y, final_color)
	
	return colored_image

func _on_manager_start_requested():
	if !simulacao_comecou:
		setup_and_start_v2()
	simular = true

func _on_manager_stop_requested():
	simular = false
	Manager.is_simulating = false

func _on_manager_cancel_requested():
	setup_and_start_v2()
	simular = false
	Manager.is_simulating = false

func _on_resolution_updated(new_res: Vector2i):
	resolution = new_res
	if simulacao_comecou:
		setup_and_start_v2()

# Nova função para receber e aplicar os valores
func _on_heatmap_config_requested(min_h: float, crit_h: float, max_h: float):
	min_sinal_dbm = min_h
	critical_sinal_dbm = crit_h
	max_sinal_dbm = max_h
	
	_update_shader_visualization_parameters()
	
	if not simular:
		_update_visual_texture_from_watts()

func _on_ris_updated_post_sim(_idx: int, _params: Dictionary):
	if not simular and not _baseline_power_map_watts.is_empty():
		recalculate_ris_post_process()


func _on_config_received(config: Dictionary):
	LOS_ativado = config["los_ativado"]
	reflection_ativado = config["reflection_ativado"]
	diffraction_ativado = config["diffraction_ativado"]
	pixels_per_frame = config["pixels_per_frame"]
	max_reflections = config["max_reflections"]
	min_sinal_color = config["min_sinal_color"]
	critical_sinal_color = config["critical_sinal_color"]
	max_sinal_color = config["max_sinal_color"]
	
	var nova_perda = config["reflection_loss_db"]
	if reflection_loss_db != nova_perda:
		reflection_loss_db = nova_perda
		if is_inside_tree() and reflection_ativado: 
			setup_and_start_v2()
			
	_update_shader_visualization_parameters()
	setup_simulation()


# Atualiza as cores do mapa térmico direto no hardware gráfico.
func _update_shader_visualization_parameters():
	if not is_instance_valid(_chao_parent):
		return
	
	var material = _chao_parent.material_override as ShaderMaterial
	if not material: 
		return
		
	material.set_shader_parameter("signal_map", result_texture)
	material.set_shader_parameter("min_color", min_sinal_color)
	material.set_shader_parameter("critical_color", critical_sinal_color)
	material.set_shader_parameter("max_color", max_sinal_color)
	
	material.set_shader_parameter("min_sinal_dbm", min_sinal_dbm)
	material.set_shader_parameter("critical_sinal_dbm", critical_sinal_dbm)
	material.set_shader_parameter("max_sinal_dbm", max_sinal_dbm)


# Configura a opacidade do material que representa o cenário.
func ajustar_transparencia_predios(alpha: float):
	if Manager.importer and Manager.importer.material_predios:
		var mat = Manager.importer.material_predios 
		
		if alpha < 1.0:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		else:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			
		mat.albedo_color.a = alpha


# Retorna um dicionário com todos os parâmetros que definem o estado do cenário.
func get_simulation_snapshot() -> Dictionary:
	var tx_data = []
	if is_instance_valid(node_tx_container):
		for tx in node_tx_container.get_children():
			tx_data.append({
				"name": tx.name,
				"pos": tx.global_position,
				"freq": tx.get("freq_mhz"),
				"power": tx.get("potencia_dbm"),
				"active": tx.get("ligado")
			})
	
	var rx_data = []
	if is_instance_valid(node_rx_container):
		for rx in node_rx_container.get_children():
			rx_data.append({
				"name": rx.name,
				"pos": rx.global_position,
				"width": rx.get_meta("width") if rx.has_meta("width") else 1.0,
				"length": rx.get_meta("length") if rx.has_meta("length") else 1.0,
				"rotation": rx.get_meta("rotation") if rx.has_meta("rotation") else 0.0
			})

	var ris_data = []
	if is_instance_valid(node_ris_container):
		for ris in node_ris_container.get_children():
			ris_data.append({
				"name": ris.name,
				"pos": ris.global_position,
				"rot_y": ris.rotation_degrees.y,
				"manual_rot": ris.get_meta("manual_rotation_offset") if ris.has_meta("manual_rotation_offset") else 0.0,
				"freq_mhz": ris.get_meta("freq_mhz") if ris.has_meta("freq_mhz") else 2400.0,
				"ganho_fixo": ris.get_meta("ganho_fixo") if ris.has_meta("ganho_fixo") else false,
				"ganho": ris.get_meta("ganho") if ris.has_meta("ganho") else 2.0,
				"cell_n": ris.get_meta("cell_n") if ris.has_meta("cell_n") else 20,
				"cell_m": ris.get_meta("cell_m") if ris.has_meta("cell_m") else 20,
				"eficiencia": ris.get_meta("eficiencia") if ris.has_meta("eficiencia") else 0.9,
				"ligado": ris.get_meta("ligado") if ris.has_meta("ligado") else true
			})
	
	return {
		"resolution": resolution,
		"min_dbm": min_sinal_dbm,
		"max_dbm": max_sinal_dbm,
		"crit_dbm": critical_sinal_dbm,
		"tx_list": tx_data,
		"rx_list": rx_data,
		"ris_list": ris_data,
		"power_array": _baseline_power_map_watts, 
		"osm_offset": _map_offset, 
		"plane_size": _plane_size
	}

# Restaura o estado de todos os componentes com base em um snapshot.
func apply_simulation_snapshot(data: Dictionary):
	resolution = data.get("resolution", resolution)
	min_sinal_dbm = data.get("min_dbm", min_sinal_dbm)
	max_sinal_dbm = data.get("max_dbm", max_sinal_dbm)
	critical_sinal_dbm = data.get("crit_dbm", critical_sinal_dbm)
	
	_plane_size = data.get("plane_size", _plane_size)
	_map_offset = data.get("osm_offset", _map_offset)
	
	await get_tree().process_frame
	
	var novo_chao = scene_3d_mapa.find_child("ChaoMapaDeCalor", true, false)
	if novo_chao and novo_chao is MeshInstance3D:
		_chao_parent = novo_chao
		var material = ShaderMaterial.new()
		material.shader = load("res://Shaders/mapa_calor_shader_material.gdshader")
		_chao_parent.material_override = material

	if is_instance_valid(node_tx_container):
		for child in node_tx_container.get_children(): child.queue_free()
		Manager.handshake_tx_clear_all.emit()
		
	if is_instance_valid(node_rx_container):
		for child in node_rx_container.get_children(): child.queue_free()
		Manager.handshake_target_clear_all.emit()
		
	if is_instance_valid(node_ris_container):
		for child in node_ris_container.get_children(): child.queue_free()
		Manager.handshake_ris_clear_all.emit()
	
	await get_tree().process_frame
	
	if "tx_list" in data and is_instance_valid(node_tx_container):
		var tx_scene_ref = load("res://Cenas/Componentes/tx.tscn")
		if tx_scene_ref:
			for tx_info in data["tx_list"]:
				var new_tx = tx_scene_ref.instantiate()
				node_tx_container.add_child(new_tx)
				new_tx.name = tx_info.get("name", "TX")
				new_tx.global_position = tx_info.get("pos", Vector3.ZERO)
				new_tx.set("freq_mhz", tx_info.get("freq", 2400.0))
				new_tx.set("potencia_dbm", tx_info.get("power", 20.0))
				new_tx.set("ligado", tx_info.get("active", true))
				Manager.handshake_tx_created.emit(new_tx.get_index(), new_tx.name)

	if "rx_list" in data and is_instance_valid(node_rx_container):
			for rx_info in data["rx_list"]:
				Manager.request_reconstruct_target.emit(rx_info)
				await get_tree().process_frame
				if node_rx_container.get_child_count() > 0:
					var novo_rx = node_rx_container.get_child(node_rx_container.get_child_count() - 1)
					novo_rx.name = rx_info.get("name", "Alvo")
					var pos_salva = rx_info.get("pos", Vector3.ZERO)
					novo_rx.global_position = pos_salva
					#novo_rx.global_position = rx_info.get("pos", Vector3.ZERO)
					novo_rx.set_meta("width", rx_info.get("width", 1.0))
					novo_rx.set_meta("length", rx_info.get("length", 1.0))
					novo_rx.set_meta("rotation", rx_info.get("rotation", 0.0))
					novo_rx.set_meta("importance", rx_info.get("importance", 1.0))
					
					var dados_ui = rx_info.duplicate()
					dados_ui["posicao"] = pos_salva 
					Manager.response_target_info.emit(novo_rx.get_index(), dados_ui)

	if "ris_list" in data and is_instance_valid(node_ris_container):
		for ris_info in data["ris_list"]:
			var new_ris = Manager.ris_scene.instantiate()
			node_ris_container.add_child(new_ris)
			
			new_ris.name = ris_info.get("name", "RIS")
			new_ris.global_position = ris_info.get("pos", Vector3.ZERO)
			
			new_ris.set_meta("freq_mhz", ris_info.get("freq_mhz", 2400.0))
			new_ris.set_meta("ganho_fixo", ris_info.get("ganho_fixo", false))
			new_ris.set_meta("ganho", ris_info.get("ganho", 2.0))
			new_ris.set_meta("cell_n", ris_info.get("cell_n", 20))
			new_ris.set_meta("cell_m", ris_info.get("cell_m", 20))
			new_ris.set_meta("eficiencia", ris_info.get("eficiencia", 0.9)) 
			new_ris.set_meta("ligado", ris_info.get("ligado", true))
			new_ris.set_meta("manual_rotation_offset", ris_info.get("manual_rot", 0.0))
			
			new_ris.rotation_degrees.y = ris_info.get("rot_y", 0.0)
			new_ris.add_to_group("reflectors")
			
			var ris_handler = get_node_or_null("../Node_RIS")
			if ris_handler:
				ris_handler._recalculate_ris_logic(new_ris)
			
			var display_name = "RIS %d (%dx%d)" % [new_ris.get_index(), new_ris.get_meta("cell_n"), new_ris.get_meta("cell_m")]
			Manager.handshake_ris_created.emit(new_ris.get_index(), display_name)

	await get_tree().process_frame
	
	setup_simulation()
	

	if "power_array" in data:
		_power_map_watts = data["power_array"]
		_baseline_power_map_watts = _power_map_watts.duplicate()
		
		if not result_image or result_image.get_size() != resolution:
			result_image = Image.create(resolution.x, resolution.y, false, Image.FORMAT_RF)
			result_texture = ImageTexture.create_from_image(result_image)
			
		result_image.fill(Color(min_sinal_dbm, 0, 0, 1))
	_update_shader_visualization_parameters()
	_update_visual_texture_from_watts()

	_start_time_msec = Time.get_ticks_msec()
	
	Manager.emit_signal("simulation_progress_update", 100.0)
	simular = false              
	Manager.is_simulating = false

	_emitir_relatorio_atualizado()


# Retorna a potência coletada pela superfície do RIS baseada na densidade do feixe.
func potencia_sinal_recebida_no_RIS(p_tx_watts: float, d1: float, area_ris: float, cos_theta_i: float) -> float:
	var densidade_esfera = p_tx_watts / (4.0 * PI * pow(d1, 2))
	return densidade_esfera * area_ris * cos_theta_i

# Calcula a perda entre RIS e RX considerando campo próximo (lente) ou distante (espalhador).
func potencia_sinal_transmitida_do_RIS(p_tx_watts: float, p_capturada: float, d1: float, d2: float, lambda_m: float, rendimento: float, cos_theta_i: float, is_near_field: bool) -> float:
	if is_near_field:
		var fspl_total_linear = pow(lambda_m / (4.0 * PI * (d1 + d2)), 2)
		return p_tx_watts * fspl_total_linear * rendimento * pow(cos_theta_i, 2)
	else:
		var fspl_d2_linear = pow(lambda_m / (4.0 * PI * d2), 2)
		return p_capturada * fspl_d2_linear * rendimento * cos_theta_i

# Processa a reflexão inteligente focada apenas nos alvos RX da cena.
func _calcular_contribuicao_ris():
	if not node_ris_container or node_ris_container.get_child_count() == 0: return
	if not node_rx_container or node_rx_container.get_child_count() == 0: return

	for ris in node_ris_container.get_children():
		var ligado = ris.get_meta("ligado") if ris.has_meta("ligado") else true
		if not ligado: continue
		
		var rendimento = ris.get_meta("eficiencia") if ris.has_meta("eficiencia") else 0.9 
		
		for tx in _tx_nodes:
			var p_tx_dbm = tx.get("potencia_dbm")
			var f_mhz = tx.get("freq_mhz")
			var dist_tx_ris = tx.global_position.distance_to(ris.global_position)
			
			var exclude = []
			if _chao_static_body:
				exclude.append(_chao_static_body.get_rid())

			# ignora colisores do TX, RX e RIS
			for col in tx.find_children("*", "CollisionObject3D", true):
				exclude.append(col.get_rid())
			for col in ris.find_children("*", "CollisionObject3D", true):
				exclude.append(col.get_rid())

			# LOS TX -> RIS
			var query_tx_ris = PhysicsRayQueryParameters3D.create(tx.global_position, ris.global_position)
			query_tx_ris.exclude = exclude
			var los_tx_ris = _space_state.intersect_ray(query_tx_ris).is_empty()

			if not los_tx_ris:
				continue  # RIS não recebe energia
			
			if dist_tx_ris < 1.0: continue
			
			var p_tx_watts = RFMath.dbm_to_watts(p_tx_dbm)
			var lambda_m = 300.0 / f_mhz
			var cell_size = lambda_m / 2.0
			var dim_n = ris.get_meta("cell_n") * cell_size
			var dim_m = ris.get_meta("cell_m") * cell_size
			var area_ris = dim_n * dim_m
			var max_dim_ris = sqrt(pow(dim_n, 2) + pow(dim_m, 2))
			
			var dir_ris_to_tx = (tx.global_position - ris.global_position).normalized()
			var normal_ris = -ris.global_transform.basis.z.normalized() 
			var cos_theta_i = max(0.0, normal_ris.dot(dir_ris_to_tx))
			
			var d_fraunhofer = RFMath.gerar_distancia_de_fraunhofer(max_dim_ris, lambda_m)
			var p_capturada = potencia_sinal_recebida_no_RIS(p_tx_watts, dist_tx_ris, area_ris, cos_theta_i)
			
			_distribuir_potencia_ris_no_rx(ris, p_tx_watts, p_capturada, lambda_m, rendimento, cos_theta_i, d_fraunhofer, area_ris)

# Dispara o cálculo matemático entre o RIS e todos os alvos configurados.
func _distribuir_potencia_ris_no_rx(ris: Node3D, p_tx_watts: float, p_capturada: float, lambda_m: float, rendimento: float, cos_theta_i: float, d_fraunhofer: float, area_ris: float):
	for rx in node_rx_container.get_children():
		var dist_ris_rx = ris.global_position.distance_to(rx.global_position)
		if dist_ris_rx < 0.1: continue
		
		var exclude = []
		if _chao_static_body:
			exclude.append(_chao_static_body.get_rid())

		for col in ris.find_children("*", "CollisionObject3D", true):
			exclude.append(col.get_rid())
		for col in rx.find_children("*", "CollisionObject3D", true):
			exclude.append(col.get_rid())

		var query_ris_rx = PhysicsRayQueryParameters3D.create(ris.global_position, rx.global_position)
		query_ris_rx.exclude = exclude
		var los_ris_rx = _space_state.intersect_ray(query_ris_rx).is_empty()

		if not los_ris_rx:
			continue  # NÃO entrega potência para esse RX
		
		var d1 = ris.global_position.distance_to(_tx_nodes[0].global_position)
		var d2 = dist_ris_rx
		var is_near_field = (d2 < d_fraunhofer) # modelo ideal removido
		
		var p_chegando_rx_total = potencia_sinal_transmitida_do_RIS(p_tx_watts, p_capturada, d1, d2, lambda_m, rendimento, cos_theta_i, false)
		
		_aplicar_potencia_nos_pixels_rx(rx, p_chegando_rx_total)



# Projeta a potência final no mapa de matriz 2D sobre a área rotacionada do alvo.
func _aplicar_potencia_nos_pixels_rx(rx: MeshInstance3D, watts_recebidos: float):
	if not is_instance_valid(_chao_parent) or not is_instance_valid(rx):
		return
	
	var global_transform = rx.global_transform
	var w_rx = rx.get_meta("width")
	var l_rx = rx.get_meta("length")
	
	var quinas_locais = [
		Vector3(-w_rx / 2.0, 0, -l_rx / 2.0),
		Vector3(w_rx / 2.0, 0, -l_rx / 2.0), 
		Vector3(w_rx / 2.0, 0, l_rx / 2.0),   
		Vector3(-w_rx / 2.0, 0, l_rx / 2.0)   
	]
	
	var min_px = resolution.x
	var max_px = -1
	var min_py = resolution.y
	var max_py = -1
	
	for quina in quinas_locais:
		var world_pos = global_transform * quina
		var local_map_pos = _chao_parent.to_local(world_pos)
		
		var uv_x = (local_map_pos.x / _plane_size.x) + 0.5
		var uv_y = (local_map_pos.z / _plane_size.y) + 0.5
		
		var px = int(uv_x * resolution.x)
		var py = int(uv_y * resolution.y)
		
		if px < min_px: min_px = px
		if px > max_px: max_px = px
		if py < min_py: min_py = py
		if py > max_py: max_py = py
		
	min_px = clamp(min_px, 0, resolution.x - 1)
	max_px = clamp(max_px, 0, resolution.x - 1)
	min_py = clamp(min_py, 0, resolution.y - 1)
	max_py = clamp(max_py, 0, resolution.y - 1)
	
	var global_transform_inv = global_transform.affine_inverse()
	var indices_para_pintar = []
	
	for py in range(min_py, max_py + 1):
		for px in range(min_px, max_px + 1):
			
			var uv_x = (float(px) + 0.5) / resolution.x
			var uv_y = (float(py) + 0.5) / resolution.y
			
			var local_map_pos = Vector3(
				(uv_x - 0.5) * _plane_size.x,
				0.0,
				(uv_y - 0.5) * _plane_size.y
			)
			
			var world_pos = _chao_parent.to_global(local_map_pos)
			var rx_local_pos = global_transform_inv * world_pos
			
			if abs(rx_local_pos.x) <= (w_rx / 2.0) and abs(rx_local_pos.z) <= (l_rx / 2.0):
				indices_para_pintar.append(py * resolution.x + px)
	
	if indices_para_pintar.size() == 0: return 

	for idx in indices_para_pintar:
		_power_map_watts[idx] += watts_recebidos

# Limpa contribuições do RIS e recalcula dinamicamente sobre a matriz base.
func recalculate_ris_post_process():
	if _baseline_power_map_watts.is_empty(): return
	
	_power_map_watts = _baseline_power_map_watts.duplicate()
	_calcular_contribuicao_ris()
	
	_update_visual_texture_from_watts()
	_emitir_relatorio_atualizado()

# Atualiza métricas parciais de taxa de cobertura e manda para a Interface.
func _emitir_relatorio_atualizado():
	var elapsed = Time.get_ticks_msec() - _start_time_msec
	
	var pontos_cobertos = 0
	var total_pontos = _power_map_watts.size()
	var threshold_watts = RFMath.dbm_to_watts(critical_sinal_dbm)
	
	for w in _power_map_watts:
		if w >= threshold_watts:
			pontos_cobertos += 1
	
	var coverage = (float(pontos_cobertos) / total_pontos) * 100.0
	var m_per_px_x = _plane_size.x / resolution.x
	var m_per_px_y = _plane_size.y / resolution.y
	
	var stats = {
		"elapsed_time": elapsed,
		"coverage_percent": coverage,
		"threshold": critical_sinal_dbm,
		"terrain_size": _plane_size,
		"res_m_px": Vector2(m_per_px_x, m_per_px_y),
		"frequency": frequencia_mhz,
		"antenna_count": _tx_nodes.size(),
		"is_final": not simular
	}
	
	Manager.simulation_stats_received.emit(stats)


# Retorna uma string BBCode com os dados do RIS em tempo real para fins de painel lateral.
func get_ris_diagnostic_string(ris_node: Node3D) -> String:
	if not is_instance_valid(node_tx_container) or node_tx_container.get_child_count() == 0:
		return "[color=yellow]Aguardando TX...[/color]"
	if not is_instance_valid(node_rx_container) or node_rx_container.get_child_count() == 0:
		return "[color=yellow]Aguardando Alvo (RX)...[/color]"

	if not _space_state:
		_space_state = get_world_3d().direct_space_state
	if not _space_state:
		return "[color=yellow]Aguardando inicialização da física...[/color]"

	var tx = node_tx_container.get_child(0) 
	var rx = node_rx_container.get_child(0) 
	
	var exclude = []
	if _chao_static_body:
		exclude.append(_chao_static_body.get_rid())
	
	for col in tx.find_children("*", "CollisionObject3D", true):
		exclude.append(col.get_rid())
	for col in rx.find_children("*", "CollisionObject3D", true):
		exclude.append(col.get_rid())
	for col in ris_node.find_children("*", "CollisionObject3D", true):
		exclude.append(col.get_rid())
	
	# LOS TX -> RIS
	var query_tx = PhysicsRayQueryParameters3D.create(tx.global_position, ris_node.global_position)
	query_tx.exclude = exclude
	var tx_ris_livre = _space_state.intersect_ray(query_tx).is_empty()
	
	# LOS RIS -> RX
	var query_rx = PhysicsRayQueryParameters3D.create(ris_node.global_position, rx.global_position)
	query_rx.exclude = exclude
	var ris_rx_livre = _space_state.intersect_ray(query_rx).is_empty()

	# ÂNGULO
	var dir_ris_to_tx = (tx.global_position - ris_node.global_position).normalized()
	var normal_ris = -ris_node.global_transform.basis.z.normalized() 
	var cos_theta_i = clamp(normal_ris.dot(dir_ris_to_tx), -1.0, 1.0)
	
	var theta_i_deg = rad_to_deg(acos(cos_theta_i))
	var theta_ok = theta_i_deg < 60.0

	# CORES
	var c_ok = "[color=#66ff66]OK[/color]" 
	var c_false = "[color=#ff6666]FALSE[/color]"
	var c_ruim = "[color=#ff6666]RUIM[/color]" 

	# STRINGS
	var s1 = "1) LOS TX-RIS: " + (c_ok if tx_ris_livre else c_false)
	var s2 = "2) LOS RIS-RX: " + (c_ok if ris_rx_livre else c_false)
	var s3 = "3) θ_i (%.1f°): " % theta_i_deg + (c_ok if theta_ok else c_ruim)

	# STATUS FINAL
	var tudo_ok = tx_ris_livre and ris_rx_livre and theta_ok
	
	var status = "\n[b]Status do RIS: " + \
		("[color=#66ff66]EFICAZ (OK)[/color]" if tudo_ok else "[color=#ff6666]INEFICAZ[/color]") + "[/b]"

	return s1 + "\n" + s2 + "\n" + s3 + "\n" + status


func export_profile_csv(start_x: float, end_x: float, fixed_z: float):
	# 1. Validações Iniciais
	if _power_map_watts.is_empty():
		if Manager.DEBUG:
			push_error("SAARIS: Erro - Mapa de potência vazio.")
		return

	# 2. Configuração do Arquivo
# Gera um nome único com timestamp para evitar sobrescrever dados anteriores
	var time_stub = Time.get_datetime_string_from_system().replace(":", "-")
	var file_name = "saaris_export_%s.csv" % time_stub
	var path = Manager.save_base_dir + "/" + file_name
	var file = FileAccess.open(path, FileAccess.WRITE)
	
	if not file:
		if Manager.DEBUG:
			push_error("SAARIS: Falha ao criar arquivo em " + path)
		return

	# Cabeçalho (Console e Arquivo)
	var header = "dist_m;p_total_dbm;p_los_dbm;p_diff_dbm"
	print("--- INÍCIO EXPORTAÇÃO CSV (SAARIS) ---")
	print(header)
	file.store_line(header)
	
	# 3. Processamento dos Pontos
	var steps = 100
	var res_x = resolution.x
	var res_y = resolution.y

	for i in range(steps + 1):
		var t = float(i) / steps
		var current_x = lerp(start_x, end_x, t)
		var world_pos = Vector3(current_x, 0.0, fixed_z)
		
		# Conversão de Coordenadas Globais -> Local -> UV -> Pixel
		var local_pos = _chao_parent.to_local(world_pos)
		var uv_x = (local_pos.x / _plane_size.x) + 0.5
		var uv_y = (local_pos.z / _plane_size.y) + 0.5
		
		var px = int(uv_x * res_x)
		var py = int(uv_y * res_y)
		
		# Proteção contra índices fora da matriz
		if px >= 0 and px < res_x and py >= 0 and py < res_y:
			var idx = py * res_x + px
			
			# Lambda para conversão segura (Evita log de zero)
			var to_dbm = func(w: float): return RFMath.watts_to_dbm(w) if w > 0.0 else -200.0
			
			var total = RFMath.watts_to_dbm(_power_map_watts[idx])
			var los = to_dbm.call(_debug_los_only_watts[idx])
			var diff = to_dbm.call(_debug_diff_only_watts[idx])
			
			var dist_m = abs(current_x - start_x)
			var line = "%.2f;%.2f;%.2f;%.2f" % [dist_m, total, los, diff]
			
			print(line)
			file.store_line(line)
			
	# 4. Finalização
	file.close()
	if Manager.DEBUG:
		print("--- FIM EXPORTAÇÃO ---")
		print("Arquivo salvo com sucesso em: " + ProjectSettings.globalize_path(path))
