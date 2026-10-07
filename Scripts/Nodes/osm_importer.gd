#osm_imported.gd OK 22/03/26
@tool
extends Node3D

#PRECISO
#mas eu te expliquei o problema e voce esta achando que so quero isso..
#se eu quiser, quero aplicar o bloco em qualquer ligarm por exemplo,
#aplicar medate dele sobre outro bloco e outra metade no chao..
#quero poder fazer isso em qualquer ponto do mapa. entao voce vai
#ter que achar em qual bloco estou interferindo ou se e um bloco
#novo solitario, ou se os blocos novos estao se juntando e adicionar
#s dados corretamente no cache. e isso que estou te pedindo.

# Adicione uma referencia para onde os meshes devem ir
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
@export var cor_predio: Color = Color(0.15, 0.35, 0.15, 1.0)

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

# Limites dos predios (usado para centralizar e criar o chao)
var building_bounds = { "min_x": INF, "max_x": -INF, "min_z": INF, "max_z": -INF }

# Variavel para centralizar o mapa em 0,0
var map_offset_normalization = Vector2.ZERO
var stats = {"real": 0, "sorteado": 0, "padrao": 0}
var material_predios = StandardMaterial3D.new()

# dados brutos que serao usados na GPU
var obstaculos_brutos_cache: Array = [] # Guarda a geometria AABB para a GPU
var obstaculos_completos_cache: Array[Vector4] = [] # Guarda a geometria completa para reflexao em GPU

var _next_id: int = 1
var _next_vertex_offset: int = 0

# --- MODO GEO (origem fixa lat/lon + relevo) ---
const TerrainMesher = preload("res://Scripts/Geo/terrain_mesh.gd")
var geo_ativo: bool = false
var geo_frame = null                 # GeoFrame
var geo_terrain: Dictionary = {}     # heightfield (ver terrain_provider.gd)
var geo_region: Dictionary = {}      # {center: Vector2, half: float}
var _rel_ids: Dictionary = {}        # dedupe de relations entre celulas


func _ready() -> void:
	if not Engine.is_editor_hint():
		Manager.importer = self

		# O Manager chama importar_pelo_caminho() direto (Manager.importar_cena).

		material_predios.albedo_color = Color(0.9, 0.9, 0.9)
		material_predios.roughness = 0.8
		material_predios.cull_mode = BaseMaterial3D.CULL_DISABLED
		material_predios.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED

		# Avisa o Manager qual arquivo estamos usando agora!
		# Garante que o Save funcione mesmo se nao importar nada manualmente.
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
	obstaculos_brutos_cache.clear() # limpar dados pre-GPU
	obstaculos_completos_cache.clear() # (corrigido) senao os vertex_offset ficam errados ao reimportar
	geo_ativo = false

	stats = {"real": 0, "sorteado": 0, "padrao": 0}

	randomize()
	if not _parse_osm_file(osm_file_path, false): return

	# Calcular o centro e limites baseados apenas nos predios
	building_bounds = { "min_x": INF, "max_x": -INF, "min_z": INF, "max_z": -INF }
	var found_buildings = false

	for id in ways_db:
		var way = ways_db[id]
		# Verifica se e predio
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

	# O centro de normalizacao sera o centro geometrico dos PREDIOS
	var center_x = (building_bounds.min_x + building_bounds.max_x) / 2.0
	var center_z = (building_bounds.min_z + building_bounds.max_z) / 2.0
	map_offset_normalization = Vector2(center_x, center_z)

	if Manager.DEBUG:
		print("[INFO] Mapa Normalizado pelos Prédios.")
		print("   - Centro: ", map_offset_normalization)
		print("   - Área Urbana: %.1f x %.1f m" % [building_bounds.max_x - building_bounds.min_x, building_bounds.max_z - building_bounds.min_z])
	_build_geometry()


func _build_geometry():
	_next_id = 1
	_next_vertex_offset = 0

	if geo_ativo:
		_create_ground_geo()
	elif gerar_chao_limite_real:
		_create_ground()

	var build_count = 0

	for rel in relations_db:
		if rel["tags"].has("building") or rel["tags"].get("type") == "multipolygon":
			if not rel["tags"].has("building") and not _has_building_member(rel):
				continue

			var height = _calcular_altura(rel["tags"], rel.get("id", 0))

			# Marca todos os ways da relation como processados.
			for member in rel["members"]:
				if member["type"] == "way":
					processed_ways[member["ref"]] = true

			# Junta fragments OUTER antes de criar o predio.
			var outer_rings = _montar_aneis_relation(rel, "outer")

			# Alguns OSM usam role vazio como outer.
			if outer_rings.is_empty():
				outer_rings = _montar_aneis_relation(rel, "")

			for ring in outer_rings:
				if ring.size() >= 3:
					_create_building_mesh(ring, height)
					build_count += 1


	for id in ways_db:
		var way = ways_db[id]

		if way["tags"].has("building") and not processed_ways.has(id):
			var height = _calcular_altura(way["tags"], id)
			_create_building_mesh(way["nodes"], height)
			build_count += 1

		elif way["tags"].has("highway"):
			_create_road_mesh(way["nodes"])


	_finalizar_caches_obstaculos()

	if Manager.DEBUG:
		print("[RESULTADO] Prédios Gerados: ", stats.real + stats.sorteado + stats.padrao)

	get_tree().create_timer(0.1).timeout.connect(_debug_scene_tree)


func _montar_aneis_relation(rel, role: String) -> Array:
	var segmentos: Array = []

	for member in rel["members"]:
		if member["type"] != "way":
			continue

		if member["role"] != role:
			continue

		if not ways_db.has(member["ref"]):
			continue

		var nodes = ways_db[member["ref"]]["nodes"].duplicate()

		if nodes.size() >= 2:
			segmentos.append(nodes)


	var aneis: Array = []

	while not segmentos.is_empty():
		var atual = segmentos.pop_front()

		var mudou := true

		while mudou:
			mudou = false

			for i in range(segmentos.size()):
				var seg = segmentos[i]

				if seg.is_empty():
					continue

				var inicio_atual = atual[0]
				var fim_atual = atual[-1]

				var inicio_seg = seg[0]
				var fim_seg = seg[-1]


				# fim atual -> inicio segmento
				if fim_atual == inicio_seg:
					for j in range(1, seg.size()):
						atual.append(seg[j])

					segmentos.remove_at(i)
					mudou = true
					break


				# fim atual -> fim segmento
				elif fim_atual == fim_seg:
					seg.reverse()

					for j in range(1, seg.size()):
						atual.append(seg[j])

					segmentos.remove_at(i)
					mudou = true
					break


				# inicio segmento -> inicio atual
				elif fim_seg == inicio_atual:
					var novo = seg.duplicate()

					for j in range(1, atual.size()):
						novo.append(atual[j])

					atual = novo
					segmentos.remove_at(i)
					mudou = true
					break


				# inicio segmento invertido -> inicio atual
				elif inicio_seg == inicio_atual:
					seg.reverse()

					var novo = seg.duplicate()

					for j in range(1, atual.size()):
						novo.append(atual[j])

					atual = novo
					segmentos.remove_at(i)
					mudou = true
					break


		# Remove no duplicado de fechamento.
		if atual.size() >= 2 and atual[0] == atual[-1]:
			atual.remove_at(atual.size() - 1)

		if atual.size() >= 3:
			aneis.append(atual)

	return aneis


func _debug_scene_tree():
	if not container_cena: return
	var children = container_cena.get_children()
	if Manager.DEBUG:
		print("--- [DEBUG] Árvore: %d objetos gerados ---" % children.size())


func _calcular_altura(tags, owner_id: int = 0) -> float:
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
		var rand: float = randf()
		if geo_ativo:
			# Altura sorteada DETERMINISTICA por id OSM: a mesma cidade gera sempre os mesmos
			# predios (essencial para cache/reprodutibilidade dos resultados).
			var rng := RandomNumberGenerator.new()
			rng.seed = hash(owner_id)
			rand = rng.randf()
		var acumulado = 0.0
		for i in range(estatistica_alturas.size()):
			var item = estatistica_alturas[i]
			acumulado += (item.x / prob_total)
			if rand <= acumulado or i == estatistica_alturas.size() - 1:
				stats.sorteado += 1
				return float(item.y) * altura_por_andar
	stats.padrao += 1
	return usar_altura_padrao_se_falhar

func _create_ground():
	# Cria o chao baseado SOMENTE nos limites dos predios + margem
	if building_bounds.min_x == INF: return

	# Largura e Profundidade da area urbana
	var urban_width = building_bounds.max_x - building_bounds.min_x
	var urban_depth = building_bounds.max_z - building_bounds.min_z

	# O centro ja e (0,0) devido a normalizacao.
	# Entao o chao vai de -metade - margem ate +metade + margem
	var half_w = urban_width / 2.0
	var half_d = urban_depth / 2.0

	var min_x = -half_w - margin
	var max_x = half_w + margin
	var min_z = -half_d - margin
	var max_z = half_d + margin

	_update_simulator_map_size(max_x,min_x, max_z,min_z)

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
	# UVs Corretos e Orientacao Anti-Horaria
	st.set_uv(Vector2(0, 0)); st.add_vertex(v1)
	st.set_uv(Vector2(1, 0)); st.add_vertex(v2)
	st.set_uv(Vector2(1, 1)); st.add_vertex(v3)

	st.set_uv(Vector2(0, 0)); st.add_vertex(v1)
	st.set_uv(Vector2(1, 1)); st.add_vertex(v3)
	st.set_uv(Vector2(0, 1)); st.add_vertex(v4)

	var mi = MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.name = "ChaoMapaDeCalor"

	# Colisao Manual
	var sb = StaticBody3D.new()
	sb.name = "StaticBody3D"
	var col = CollisionShape3D.new()
	col.name = "CollisionShape3D"
	col.shape = mi.mesh.create_trimesh_shape()
	sb.add_child(col); mi.add_child(sb)

	if container_cena: container_cena.add_child(mi)
	else: add_child(mi)

func _create_building_cache(points_2d: PackedVector2Array, height: float, base_y: float = 0.0) -> void:
	var min_x = INF; var max_x = -INF
	var min_z = INF; var max_z = -INF

	for p in points_2d:
		if p.x < min_x: min_x = p.x
		if p.x > max_x: max_x = p.x
		if p.y < min_z: min_z = p.y
		if p.y > max_z: max_z = p.y

	var bounds_min := Vector3(min_x, base_y, min_z)
	var bounds_max := Vector3(max_x, base_y + height, max_z)
	var centro := (bounds_min + bounds_max) / 2.0
	var raio_maximo := bounds_min.distance_to(bounds_max) * 0.5

	var id_dono: int = _next_id
	var id_float: float = float(id_dono)

	var vertex_count: int = points_2d.size() + 1  # +1 pro fechamento

	# Escreve os pontos no buffer com ID sequencial
	for p in points_2d:
		obstaculos_completos_cache.append(Vector4(p.x, base_y + height, p.y, id_float))

	# Vertice de fechamento com ID negativo (flag de ultima aresta)
	var primeiro = points_2d[0]
	obstaculos_completos_cache.append(Vector4(primeiro.x, base_y + height, primeiro.y, -id_float))

	# Escreve o AABB com os metadados que a GPU precisa
	obstaculos_brutos_cache.append({
		"centro": centro,
		"raio_maximo": raio_maximo,
		"bounds_min": bounds_min,
		"bounds_max": bounds_max,
		"perda_difracao": 12.0,
		"coef_reflexao": 0.4,
		"id": id_dono,
		"vertex_offset": _next_vertex_offset,
		"vertex_count": vertex_count,
	})

	_next_id += 1
	_next_vertex_offset += vertex_count

func _finalizar_caches_obstaculos() -> void:
	obstaculos_brutos_cache.sort_custom(
		func(a, b): return a["centro"].x < b["centro"].x
	)
	if Manager.DEBUG:
		print("[Importer] %d prédios ordenados. %d vértices no buffer."
			% [obstaculos_brutos_cache.size(), obstaculos_completos_cache.size()])

func _update_simulator_map_size(x_max, x_min, y_max, y_min):
	var size_x = float(x_max) - float(x_min)
	var size_y = float(y_max) - float(y_min)

	Manager.engine.mapa_calor.size = Vector2(size_x, size_y)
	# Guarda a quina inicial exata (minima) onde o terreno comeca no cenario 3D
	Manager.engine.mapa_calor.map_offset = Vector2(x_min, y_min)
	print("[SAARIS] Mapa dimensionado: ", Manager.engine.mapa_calor.size, " metros. Offset inicial: ", Manager.engine.mapa_calor.map_offset)

func _create_building_mesh(node_ids, height):
	var points_2d = PackedVector2Array()
	for id in node_ids:
		if nodes_db.has(id):
			# CENTRALIZA CADA PONTO (Aplica o offset calculado pelos predios)
			points_2d.append(nodes_db[id] - map_offset_normalization)

	if points_2d.size() < 3: return
	if points_2d[0].distance_to(points_2d[-1]) < 0.1: points_2d.remove_at(points_2d.size() - 1)
	if points_2d.size() < 3: return

	# --- MODO GEO: so predios cujo centro esta na regiao; base assentada no relevo ---
	var base: float = 0.0
	if geo_ativo:
		var c := Vector2.ZERO
		for q in points_2d: c += q
		c /= float(points_2d.size())
		var rc: Vector2 = geo_region.center
		var rh: float = geo_region.half
		if absf(c.x - rc.x) > rh or absf(c.y - rc.y) > rh:
			return
		base = INF
		for q in points_2d:
			base = minf(base, terrain_height_at(q.x, q.y))

	_create_building_cache(points_2d, height, base)

	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(material_predios)

	for i in range(points_2d.size()):
		var a = points_2d[i]
		var b = points_2d[(i + 1) % points_2d.size()]
		var v1 = Vector3(a.x, base, a.y); var v2 = Vector3(b.x, base, b.y)
		var v3 = Vector3(b.x, base + height, b.y); var v4 = Vector3(a.x, base + height, a.y)

		var wall_vec = (v2 - v1).normalized()
		var normal = wall_vec.cross(Vector3.UP).normalized()
		st.set_normal(normal); st.add_vertex(v3); st.add_vertex(v2); st.add_vertex(v1)
		st.set_normal(normal); st.add_vertex(v4); st.add_vertex(v3); st.add_vertex(v1)

	var indices = Geometry2D.triangulate_polygon(points_2d)
	if not indices.is_empty():
		for i in range(0, indices.size(), 3):
			var p1 = points_2d[indices[i+2]]; var p2 = points_2d[indices[i+1]]; var p3 = points_2d[indices[i]]
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(p1.x, base + height, p1.y)); st.add_vertex(Vector3(p2.x, base + height, p2.y)); st.add_vertex(Vector3(p3.x, base + height, p3.y))

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
			# CENTRALIZA ESTRADAS TAMBEM (Senao elas ficam deslocadas dos predios)
			points.append(nodes_db[id] - map_offset_normalization)
	if points.size() < 2: return

	# MODO GEO: ignora ruas fora da regiao e acompanha o relevo
	if geo_ativo:
		var rc: Vector2 = geo_region.center
		var rh: float = geo_region.half + 30.0
		var dentro := false
		for q in points:
			if absf(q.x - rc.x) <= rh and absf(q.y - rc.y) <= rh:
				dentro = true
				break
		if not dentro: return

	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.1, 0.1, 0.1)
	mat.roughness = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(mat)

	var half_w = road_width / 2.0
	var y_pos = 0.1
	var passo_max: float = 12.0   # subdivide trechos longos para acompanhar o terreno

	for i in range(points.size() - 1):
		var a = points[i]; var b = points[i+1]
		var dir = (b - a).normalized()
		var perp = Vector2(-dir.y, dir.x) * half_w
		var nsub: int = 1
		if geo_ativo:
			nsub = maxi(1, int(ceil(a.distance_to(b) / passo_max)))
		for k in range(nsub):
			var a2: Vector2 = a.lerp(b, float(k) / float(nsub))
			var b2: Vector2 = a.lerp(b, float(k + 1) / float(nsub))
			var ya: float = y_pos + altura_extra_chao
			var yb: float = y_pos + altura_extra_chao
			if geo_ativo:
				ya = terrain_height_at(a2.x, a2.y) + 0.35
				yb = terrain_height_at(b2.x, b2.y) + 0.35
			var v1 = Vector3(a2.x + perp.x, ya, a2.y + perp.y)
			var v2 = Vector3(a2.x - perp.x, ya, a2.y - perp.y)
			var v3 = Vector3(b2.x + perp.x, yb, b2.y + perp.y)
			var v4 = Vector3(b2.x - perp.x, yb, b2.y - perp.y)
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
	nodes_db.clear(); ways_db.clear(); relations_db.clear(); processed_ways.clear(); _rel_ids.clear()
	map_center = Vector2.ZERO
	map_bounds = { "min_x": INF, "max_x": -INF, "min_z": INF, "max_z": -INF }
	for c in get_children(): c.queue_free()


# A funcao que o Manager vai chamar remotamente
func importar_pelo_caminho(path: String, nome_projeto: String):
	if Manager.DEBUG:
		print("[Importer] Ordem recebida do Manager: Carregar ", path)
	self.osm_file_path = path

	# 1. MATA O SIMULADOR ANTES DE DESTRUIR O CHAO
	if Manager.engine and Manager.engine.has_method("halt_simulator_for_scene_change"):
		Manager.engine.halt_simulator_for_scene_change()

	# Verifica se o no container_cena existe na arvore
	if is_instance_valid(container_cena):

		# Verifica se a string tem algum conteudo antes de renomear
		if not nome_projeto.is_empty():
			container_cena.name = nome_projeto # Altera o nome do no

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

	# Espera a engine renderizar as pecas e avisa que terminou!
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
		if Manager.DEBUG:
			print("[Importer] Cena nativa carregada com sucesso!")
	else:
		if Manager.DEBUG:
			push_error("[Importer] Falha ao encontrar a cena no caminho: " + path)


# MODO GEO: origem fixa lat/lon + relevo + varias celulas OSM

## Altura do terreno (m, relativa a origem vertical) em (x, z) locais. Bilinear.
func terrain_height_at(x: float, z: float) -> float:
	if geo_terrain.is_empty():
		return 0.0
	var res: int = geo_terrain.res
	var step: float = geo_terrain.step
	var off: Vector2 = geo_terrain.offset
	var hs: PackedFloat32Array = geo_terrain.heights
	var gx: float = clampf((x - off.x) / step, 0.0, float(res - 1) - 0.0001)
	var gz: float = clampf((z - off.y) / step, 0.0, float(res - 1) - 0.0001)
	var ix: int = int(gx)
	var iz: int = int(gz)
	var fx: float = gx - float(ix)
	var fz: float = gz - float(iz)
	var h00: float = hs[iz * res + ix]
	var h10: float = hs[iz * res + ix + 1]
	var h01: float = hs[(iz + 1) * res + ix]
	var h11: float = hs[(iz + 1) * res + ix + 1]
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fz)


## Le UM arquivo .osm e acumula em nodes_db / ways_db / relations_db.
## geo_mode=true: posicoes via geo_frame (origem fixa) e relations deduplicadas.
func _parse_osm_file(path: String, geo_mode: bool) -> bool:
	var parser = XMLParser.new()
	if parser.open(path) != OK:
		return false

	var current_tag_holder = null
	var current_type = ""

	while parser.read() == OK:
		var type = parser.get_node_type()
		if type == XMLParser.NODE_ELEMENT:
			var name = parser.get_node_name()
			if name == "node":
				var id = parser.get_named_attribute_value_safe("id").to_int()
				var lat = parser.get_named_attribute_value_safe("lat").to_float()
				var lon = parser.get_named_attribute_value_safe("lon").to_float()

				if geo_mode:
					nodes_db[id] = geo_frame.latlon_to_xz(lat, lon)
				else:
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
				var rid: int = parser.get_named_attribute_value_safe("id").to_int()
				var rel_data = {"members": [], "tags": {}, "id": rid}
				if geo_mode and _rel_ids.has(rid):
					pass   # ja lida em outra celula: usa um objeto descartavel
				else:
					_rel_ids[rid] = true
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
	return true


## Constroi a cena de uma regiao: terreno + predios + ruas, tudo no quadro local
## fixo (origem lat0/lon0). Chamado pelo GeoManager.
##   paths   : arquivos .osm (celulas ja em cache)
##   terrain : heightfield (terrain_provider.build_heightfield / flat_heightfield)
##   region  : {center: Vector2, half: float}
func generate_geo(paths: PackedStringArray, frame, terrain: Dictionary, region: Dictionary) -> void:
	if Manager.engine and Manager.engine.has_method("halt_simulator_for_scene_change"):
		Manager.engine.halt_simulator_for_scene_change()

	_clear_data()
	obstaculos_brutos_cache.clear()
	obstaculos_completos_cache.clear()
	stats = {"real": 0, "sorteado": 0, "padrao": 0}

	geo_ativo = true
	geo_frame = frame
	geo_terrain = terrain
	geo_region = region
	map_offset_normalization = Vector2.ZERO

	# Remove a cena anterior (validacao, regiao antiga...) ja, para nao coexistirem dois "ChaoMapaDeCalor"
	if is_instance_valid(container_cena):
		for child in container_cena.get_children():
			container_cena.remove_child(child)
			child.queue_free()

	for p in paths:
		_parse_osm_file(p, true)

	_build_geometry()
	if Manager.DEBUG:
		print("[Importer/Geo] %d prédios na região; terreno %dx%d" % [obstaculos_brutos_cache.size(), terrain.res, terrain.res])


## Malha do terreno (heightfield) com colisao. Mantem o nome "ChaoMapaDeCalor"
## porque o simulador procura por ele para aplicar a textura do mapa de calor.
func _create_ground_geo() -> void:
	var mesher = TerrainMesher.new()
	var mi: MeshInstance3D = mesher.build(geo_terrain)
	mi.name = "ChaoMapaDeCalor"
	if container_cena: container_cena.add_child(mi)
	else: add_child(mi)

	# Informa o simulador: o mapa de calor cobre exatamente a regiao do terreno
	var off: Vector2 = geo_terrain.offset
	var sz: Vector2 = geo_terrain.size
	_update_simulator_map_size(off.x + sz.x, off.x, off.y + sz.y, off.y)
