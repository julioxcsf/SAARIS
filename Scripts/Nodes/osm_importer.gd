#osm_imported.gd OK 22/03/26
@tool
extends Node3D

# Adicione uma referência para onde os meshes devem ir
@onready var container_cena = get_node("../Scene3D")

# variaveis editaveis no Inspetor da interface da godot de projetos
@export_category("Arquivo e Controle")
@export_file("*.osm") var osm_file_path: String
@export var carregar_mapa: bool = false : set = _on_carregar_mapa_pressed
@export var limpar_tudo: bool = false : set = _on_limpar_tudo_pressed

@export_category("Configuração de Ruas e Chão")
@export var road_width: float = 6.0 
@export var gerar_chao_limite_real: bool = true
@export var cor_chao: Color = Color(0.15, 0.35, 0.15) 
@export var altura_extra_chao: float = 0.1 
@export var margin: float = 500.0

@export_category("Estatística de Alturas")
@export var altura_por_andar: float = 3.0
@export var usar_altura_padrao_se_falhar: float = 10.0

# X (Probabilidade 0.0-1.0), Y (Andares Inteiro)
@export var estatistica_alturas: Array[Vector2] = [
	Vector2(0.5, 2),  # 50% -> 2 andares
	Vector2(0.3, 5),  # 30% -> 5 andares
	Vector2(0.2, 12)  # 20% -> 12 andares
]

# --- DADOS INTERNOS ---
var nodes_db = {} 
var ways_db = {} 
var relations_db = [] 
var processed_ways = {} 
var map_center = Vector2.ZERO
var map_bounds = { "min_x": INF, "max_x": -INF, "min_z": INF, "max_z": -INF }

# Limites dos prédios (usado para centralizar e criar o chão)
var building_bounds = { "min_x": INF, "max_x": -INF, "min_z": INF, "max_z": -INF }

# Variável para centralizar o mapa em 0,0
var map_offset_normalization = Vector2.ZERO
var stats = {"real": 0, "sorteado": 0, "padrao": 0}
var material_predios = StandardMaterial3D.new()


func _ready() -> void:
	if not Engine.is_editor_hint():
		Manager.importer = self
		
		# 1. Conecta ao sinal de importação
		Manager.request_import.connect(importar_pelo_caminho)
		if Manager.DEBUG:
			print("[Importer] Conectado e ouvindo o Manager.")
		
		material_predios.albedo_color = Color(0.9, 0.9, 0.9)
		material_predios.roughness = 0.8
		material_predios.cull_mode = BaseMaterial3D.CULL_DISABLED
		material_predios.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		
		# Avisa o Manager qual arquivo estamos usando agora!
		# Garante que o Save funcione mesmo se não importar nada manualmente.
		if osm_file_path != "":
			Manager.current_osm_path = osm_file_path 
			generate_city()


func _on_carregar_mapa_pressed(value):
	if value:
		generate_city()
		carregar_mapa = false


func _on_limpar_tudo_pressed(value):
	if value:
		_clear_data()
		limpar_tudo = false


func generate_city():
	if osm_file_path == "":
		if Manager.DEBUG:
			print("[ERRO] Arquivo OSM não definido!")
		return
	
	if estatistica_alturas.is_empty():
		estatistica_alturas = [Vector2(0.5, 2), Vector2(0.3, 6), Vector2(0.2, 12)]
	
	if Manager.DEBUG:
		print("[INFO] Processando... (Foco nos Prédios)")
	_clear_data()
	stats = {"real": 0, "sorteado": 0, "padrao": 0}
	
	var parser = XMLParser.new()
	if parser.open(osm_file_path) != OK: return
	
	randomize() 
	
	var current_tag_holder = null
	var current_type = ""
	
	# PASSO 1: LEITURA COMPLETA
	while parser.read() == OK:
		var type = parser.get_node_type()
		if type == XMLParser.NODE_ELEMENT:
			var name = parser.get_node_name()
			if name == "node":
				var id = parser.get_named_attribute_value_safe("id").to_int()
				var lat = parser.get_named_attribute_value_safe("lat").to_float()
				var lon = parser.get_named_attribute_value_safe("lon").to_float()
				
				if map_center == Vector2.ZERO: map_center = Vector2(lon, lat)
				
				var x = (lon - map_center.x) * 101343.0 
				var z = (map_center.y - lat) * 111319.0
				nodes_db[id] = Vector2(x, z)
				
				# Limites globais (apenas para registro)
				if x < map_bounds.min_x: map_bounds.min_x = x
				if x > map_bounds.max_x: map_bounds.max_x = x
				if z < map_bounds.min_z: map_bounds.min_z = z
				if z > map_bounds.max_z: map_bounds.max_z = z
				
			elif name == "way":
				var id = parser.get_named_attribute_value_safe("id").to_int()
				current_type = "way"
				ways_db[id] = {"nodes": [], "tags": {}}
				current_tag_holder = ways_db[id]
			elif name == "relation":
				current_type = "relation"
				var rel_data = {"members": [], "tags": {}}
				relations_db.append(rel_data)
				current_tag_holder = rel_data
			elif name == "nd" and current_type == "way":
				current_tag_holder["nodes"].append(parser.get_named_attribute_value_safe("ref").to_int())
			elif name == "member" and current_type == "relation":
				var m_type = parser.get_named_attribute_value_safe("type")
				var m_ref = parser.get_named_attribute_value_safe("ref").to_int()
				var m_role = parser.get_named_attribute_value_safe("role")
				current_tag_holder["members"].append({"type": m_type, "ref": m_ref, "role": m_role})
			elif name == "tag" and current_tag_holder != null:
				current_tag_holder["tags"][parser.get_named_attribute_value_safe("k")] = parser.get_named_attribute_value_safe("v")
		elif type == XMLParser.NODE_ELEMENT_END:
			if parser.get_node_name() == "way" or parser.get_node_name() == "relation":
				current_tag_holder = null
	
	# Calcular o centro e limites baseados apenas nos prédios
	building_bounds = { "min_x": INF, "max_x": -INF, "min_z": INF, "max_z": -INF }
	var found_buildings = false
	
	for id in ways_db:
		var way = ways_db[id]
		# Verifica se é prédio
		if way["tags"].has("building"):
			found_buildings = true
			for n_id in way["nodes"]:
				if nodes_db.has(n_id):
					var p = nodes_db[n_id]
					if p.x < building_bounds.min_x: building_bounds.min_x = p.x
					if p.x > building_bounds.max_x: building_bounds.max_x = p.x
					if p.y < building_bounds.min_z: building_bounds.min_z = p.y
					if p.y > building_bounds.max_z: building_bounds.max_z = p.y
	
	if not found_buildings:
		if Manager.DEBUG:
			print("[AVISO] Nenhum prédio encontrado! Usando limites globais.")
		building_bounds = map_bounds.duplicate()
		
	# O centro de normalização será o centro geométrico dos PRÉDIOS
	var center_x = (building_bounds.min_x + building_bounds.max_x) / 2.0
	var center_z = (building_bounds.min_z + building_bounds.max_z) / 2.0
	map_offset_normalization = Vector2(center_x, center_z)
	
	if Manager.DEBUG:
		print("[INFO] Mapa Normalizado pelos Prédios.")
		print("   - Centro: ", map_offset_normalization)
		print("   - Área Urbana: %.1f x %.1f m" % [building_bounds.max_x - building_bounds.min_x, building_bounds.max_z - building_bounds.min_z])
	_build_geometry()


func _build_geometry():
	if gerar_chao_limite_real:
		_create_ground()
	
	var build_count = 0
	
	for rel in relations_db:
		if rel["tags"].has("building") or rel["tags"].get("type") == "multipolygon":
			if not rel["tags"].has("building") and not _has_building_member(rel): continue
			var height = _calcular_altura(rel["tags"])
			for member in rel["members"]:
				if member["type"] == "way" and (member["role"] == "outer" or member["role"] == ""):
					if ways_db.has(member["ref"]):
						_create_building_mesh(ways_db[member["ref"]]["nodes"], height)
						processed_ways[member["ref"]] = true
						build_count += 1
	
	for id in ways_db:
		var way = ways_db[id]
		if way["tags"].has("building") and not processed_ways.has(id):
			var height = _calcular_altura(way["tags"])
			_create_building_mesh(way["nodes"], height)
			build_count += 1
		elif way["tags"].has("highway"):
			_create_road_mesh(way["nodes"])
			
	if Manager.DEBUG:
		print("[RESULTADO] Prédios Gerados: ", stats.real + stats.sorteado + stats.padrao)
	get_tree().create_timer(0.1).timeout.connect(_debug_scene_tree)


func _debug_scene_tree():
	if not container_cena: return
	var children = container_cena.get_children()
	if Manager.DEBUG:
		print("--- [DEBUG] Árvore: %d objetos gerados ---" % children.size())


func _calcular_altura(tags) -> float:
	if tags.has("height"):
		var h_str = tags["height"].replace("m", "").replace(" ", "").replace(",", ".")
		if h_str.is_valid_float():
			stats.real += 1
			return h_str.to_float()
	if tags.has("building:levels"):
		var l_str = tags["building:levels"].replace(" ", "").replace(",", ".")
		if l_str.is_valid_float():
			stats.real += 1
			return l_str.to_float() * altura_por_andar
	if not estatistica_alturas.is_empty():
		var prob_total = 0.0
		for item in estatistica_alturas: prob_total += item.x
		var rand = randf(); var acumulado = 0.0
		for i in range(estatistica_alturas.size()):
			var item = estatistica_alturas[i]
			acumulado += (item.x / prob_total)
			if rand <= acumulado or i == estatistica_alturas.size() - 1:
				stats.sorteado += 1
				return float(item.y) * altura_por_andar
	stats.padrao += 1
	return usar_altura_padrao_se_falhar

func _create_ground():
	# Cria o chão baseado SOMENTE nos limites dos prédios + margem
	if building_bounds.min_x == INF: return
	
	# Largura e Profundidade da área urbana
	var urban_width = building_bounds.max_x - building_bounds.min_x
	var urban_depth = building_bounds.max_z - building_bounds.min_z
	
	# O centro já é (0,0) devido à normalização.
	# Então o chão vai de -metade - margem até +metade + margem
	var half_w = urban_width / 2.0
	var half_d = urban_depth / 2.0
	
	var min_x = -half_w - margin
	var max_x = half_w + margin
	var min_z = -half_d - margin
	var max_z = half_d + margin
	
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var mat = StandardMaterial3D.new()
	mat.albedo_color = cor_chao
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED 
	st.set_material(mat)
	
	var y_floor = -0.1
	var v1 = Vector3(min_x, y_floor, min_z); var v2 = Vector3(max_x, y_floor, min_z)
	var v3 = Vector3(max_x, y_floor, max_z); var v4 = Vector3(min_x, y_floor, max_z)
	
	st.set_normal(Vector3.UP)
	# UVs Corretos e Orientação Anti-Horária
	st.set_uv(Vector2(0, 0)); st.add_vertex(v1)
	st.set_uv(Vector2(1, 0)); st.add_vertex(v2)
	st.set_uv(Vector2(1, 1)); st.add_vertex(v3)
	
	st.set_uv(Vector2(0, 0)); st.add_vertex(v1)
	st.set_uv(Vector2(1, 1)); st.add_vertex(v3)
	st.set_uv(Vector2(0, 1)); st.add_vertex(v4)
	
	var mi = MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.name = "ChaoMapaDeCalor"
	
	# Colisão Manual
	var sb = StaticBody3D.new()
	sb.name = "StaticBody3D"
	var col = CollisionShape3D.new()
	col.name = "CollisionShape3D"
	col.shape = mi.mesh.create_trimesh_shape()
	sb.add_child(col); mi.add_child(sb)
	
	if container_cena: container_cena.add_child(mi)
	else: add_child(mi)


func _create_building_mesh(node_ids, height):
	var points_2d = PackedVector2Array()
	for id in node_ids:
		if nodes_db.has(id):
			# CENTRALIZA CADA PONTO (Aplica o offset calculado pelos prédios)
			points_2d.append(nodes_db[id] - map_offset_normalization)
	
	if points_2d.size() < 3: return
	if points_2d[0].distance_to(points_2d[-1]) < 0.1: points_2d.remove_at(points_2d.size() - 1)
	if points_2d.size() < 3: return

	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(material_predios)
	
	for i in range(points_2d.size()):
		var a = points_2d[i]
		var b = points_2d[(i + 1) % points_2d.size()]
		var v1 = Vector3(a.x, 0, a.y); var v2 = Vector3(b.x, 0, b.y)
		var v3 = Vector3(b.x, height, b.y); var v4 = Vector3(a.x, height, a.y)
		
		var wall_vec = (v2 - v1).normalized()
		var normal = wall_vec.cross(Vector3.UP).normalized() 
		st.set_normal(normal); st.add_vertex(v3); st.add_vertex(v2); st.add_vertex(v1)
		st.set_normal(normal); st.add_vertex(v4); st.add_vertex(v3); st.add_vertex(v1)

	var indices = Geometry2D.triangulate_polygon(points_2d)
	if not indices.is_empty():
		for i in range(0, indices.size(), 3):
			var p1 = points_2d[indices[i+2]]; var p2 = points_2d[indices[i+1]]; var p3 = points_2d[indices[i]]
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(p1.x, height, p1.y)); st.add_vertex(Vector3(p2.x, height, p2.y)); st.add_vertex(Vector3(p3.x, height, p3.y))
	
	var mi = MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.name = "Predio_OSM"
	
	var sb = StaticBody3D.new()
	sb.name = "StaticBody3D"
	var col = CollisionShape3D.new()
	col.name = "CollisionShape3D"
	col.shape = mi.mesh.create_trimesh_shape()
	sb.add_child(col); mi.add_child(sb)
	
	if container_cena: container_cena.add_child(mi)
	else: add_child(mi)


func _create_road_mesh(node_ids):
	var points = PackedVector2Array()
	for id in node_ids:
		if nodes_db.has(id):
			# CENTRALIZA ESTRADAS TAMBÉM (Senão elas ficam deslocadas dos prédios)
			points.append(nodes_db[id] - map_offset_normalization)
	if points.size() < 2: return

	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.1, 0.1, 0.1)
	mat.roughness = 0.9
	st.set_material(mat)
	
	var half_w = road_width / 2.0
	var y_pos = 0.1
	
	for i in range(points.size() - 1):
		var a = points[i]; var b = points[i+1]
		var dir = (b - a).normalized()
		var perp = Vector2(-dir.y, dir.x) * half_w
		
		var v1 = Vector3(a.x + perp.x, y_pos + altura_extra_chao, a.y + perp.y)
		var v2 = Vector3(a.x - perp.x, y_pos + altura_extra_chao, a.y - perp.y)
		var v3 = Vector3(b.x + perp.x, y_pos + altura_extra_chao, b.y + perp.y)
		var v4 = Vector3(b.x - perp.x, y_pos + altura_extra_chao, b.y - perp.y)
		
		st.set_normal(Vector3.UP)
		st.add_vertex(v1); st.add_vertex(v2); st.add_vertex(v3)
		st.add_vertex(v2); st.add_vertex(v4); st.add_vertex(v3)

	var mi = MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.name = "Estrada_OSM"
	
	if container_cena: container_cena.add_child(mi)
	else: add_child(mi)


func _has_building_member(rel):
	for m in rel["members"]:
		if m["type"] == "way" and ways_db.has(m["ref"]):
			if ways_db[m["ref"]]["tags"].has("building"): return true
	return false


func _clear_data():
	nodes_db.clear(); ways_db.clear(); relations_db.clear(); processed_ways.clear()
	map_bounds = { "min_x": INF, "max_x": -INF, "min_z": INF, "max_z": -INF }
	for c in get_children(): c.queue_free()


# A função que o Manager vai chamar remotamente
func importar_pelo_caminho(path: String, nome_projeto: String):
	if Manager.DEBUG:
		print("[Importer] Ordem recebida do Manager: Carregar ", path)
	self.osm_file_path = path
	
	# 1. MATA O SIMULADOR ANTES DE DESTRUIR O CHÃO
	if Manager.engine and Manager.engine.has_method("halt_simulator_for_scene_change"):
		Manager.engine.halt_simulator_for_scene_change()
	
	# Verifica se o nó container_cena existe na árvore
	if is_instance_valid(container_cena):
		
		# Verifica se a string tem algum conteúdo antes de renomear
		if not nome_projeto.is_empty(): 
			container_cena.name = nome_projeto # Altera o nome do nó
			
		# Limpa a cena antiga
		for child in container_cena.get_children():
			child.queue_free()
	
	# Aguarda a limpeza ocorrer
	if not Engine.is_editor_hint():
		await get_tree().process_frame
		
	# Decide como carregar
	if path.ends_with(".osm"):
		generate_city()
	elif path.ends_with(".tscn") or path.ends_with(".scn"):
		_instanciar_cena_godot(path)
	else:
		push_error("[Importer] Formato de arquivo desconhecido: " + path)

	# A MÁGICA AQUI: Espera a engine renderizar as peças e avisa que terminou!
	await get_tree().process_frame
	if Manager.DEBUG:
		print("[Importer] Cenário construído! Liberando o Simulador...")
	Manager.map_loaded_successfully.emit()


func _instanciar_cena_godot(path: String):
	print("[Importer] Carregando cena nativa do Godot...")
	var cena_nativa = load(path)
	if cena_nativa:
		var instancia = cena_nativa.instantiate()
		if container_cena:
			container_cena.add_child(instancia)
		else:
			add_child(instancia)
			Manager.engine.setup_and_start_v2()
		if Manager.DEBUG:
			print("[Importer] Cena nativa carregada com sucesso!")
	else:
		if Manager.DEBUG:
			push_error("[Importer] Falha ao encontrar a cena no caminho: " + path)
