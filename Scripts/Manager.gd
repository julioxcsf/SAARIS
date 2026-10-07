extends Node
## Manager (autoload) - agora e so um "quadro de referencias" + estado global.
##
## SEM SINAIS de controle: a interface chama direto, por exemplo
##     Manager.engine.mapa_calor.resolution = Vector2i(512, 512)
##     Manager.tx_handler.update_tx(i, {...})
##     Manager.rx_handler.add_rx()
##     Manager.ris_handler.update_ris(i, {"alvo": rx_node})
## O unico sinal que sobrou e `map_loaded_successfully`, usado so para `await`
## (esperar o mapa ficar pronto antes de aplicar um save).

signal map_loaded_successfully

# --- referencias ---
var engine = null          # simulator_on_GPU.gd
var importer = null        # osm_importer.gd
var tx_handler = null      # node_tx.gd   (lista tx_cache)
var rx_handler = null      # node_rx.gd   (lista rx_cache)
var ris_handler = null     # node_ris.gd  (lista ris_cache)
var camera = null          # camera_3d.gd
var network_node = null
var geo = null             # GeoManager (relevo + OSM + antenas reais); definido por geo_manager.gd

# Widgets de UI que precisam ser chamados de fora (cada um se registra no _ready)
var ui_aviso = null        # UI_config_janela_aviso.gd   -> mostrar(msg)
var ui_cenas = null        # UI_config_scene_button.gd   -> carregar_cena(nome, path, snapshot)
var ui_resolucao = null    # resolution_config.gd        -> refletir_resolucao(Vector2i)
var ui_dados = null        # relatorio_ui.gd (label)     -> atualizar_sonda / atualizar_estatisticas
var ui_tx = null           # antena_config.gd            -> aplicar_posicao(Vector3) / recarregar()
var ui_rx = null           # target_config.gd
var ui_ris = null          # ris_config.gd
var ui_relatorio = null    # relatorio_config.gd         -> abrir()

var tx_scene = preload("res://Cenas/Componentes/tx.tscn")
var ris_scene = preload("res://Cenas/Componentes/ris_module.tscn")
var current_osm_path: String = ""
var current_map_path: String = ""
var current_scene_name: String = ""
var save_base_dir: String = ""
var config_file_path: String = ""

enum PlacementMode { NONE, TX, RX, RIS }
var current_placement_mode: PlacementMode = PlacementMode.NONE
var current_placement_axis: String = ""
var current_placement_fixed_value: float = 0.0
var current_placement_target_index: int = -1

## Quando true, os paineis (grupo "trava_simulacao") ficam bloqueados.
## Cada painel implementa set_ocupado(busy: bool).
var is_simulating: bool = false :
	set(val):
		is_simulating = val
		if is_inside_tree():
			get_tree().call_group("trava_simulacao", "set_ocupado", val)
var is_probe_active: bool = false
var DEBUG = false


func _ready():
	if DEBUG:
		print("[Manager] Hub sintonizado.")

	# Pasta de saves: ao lado do projeto (editor) ou do executavel (exportado)
	if OS.has_feature("editor"):
		save_base_dir = ProjectSettings.globalize_path("res://Saves")
	else:
		save_base_dir = OS.get_executable_path().get_base_dir() + "/Saves"

	if not DirAccess.dir_exists_absolute(save_base_dir):
		DirAccess.make_dir_recursive_absolute(save_base_dir)

	var target_candelaria = save_base_dir + "/Candelaria_RIS"
	if not DirAccess.dir_exists_absolute(target_candelaria):
		print("[Manager] Inicializando save de avaliação (Candelaria_RIS)...")
		DirAccess.make_dir_recursive_absolute(target_candelaria)
		DirAccess.copy_absolute("res://Assets_BKP_Saves/Candelaria_RIS/savefile.bin", target_candelaria + "/savefile.bin")
		if FileAccess.file_exists("res://Assets_BKP_Saves/Candelaria_RIS/cenario.osm"):
			DirAccess.copy_absolute("res://Assets_BKP_Saves/Candelaria_RIS/cenario.osm", target_candelaria + "/cenario.osm")

	config_file_path = save_base_dir + "/settings.cfg"
	call_deferred("load_global_config")


# --- atalhos diretos ---

func start_simulation():
	engine.start_simulation()


## Mostra um aviso ao usuario (direto na janela de aviso).
func aviso(msg: String) -> void:
	if ui_aviso != null:
		ui_aviso.mostrar(msg)
	else:
		push_warning("[SAARIS] " + msg)


## Troca o cenario: guarda caminho/nome e manda o importador carregar (chamada direta).
func importar_cena(path: String, nome: String) -> void:
	current_map_path = path
	current_scene_name = nome
	if importer != null:
		importer.importar_pelo_caminho(path, nome)


# --- posicionamento no plano ---

## Prepara o sistema para posicionar um elemento por clique do mouse em um plano fixo.
func request_plane_placement(type: String, index: int, axis: String, fixed_value: float):
	if type == "TX": current_placement_mode = PlacementMode.TX
	elif type == "RX": current_placement_mode = PlacementMode.RX
	elif type == "RIS": current_placement_mode = PlacementMode.RIS

	current_placement_target_index = index
	current_placement_axis = axis
	current_placement_fixed_value = fixed_value

	if DEBUG:
		print("[Manager] Entrando em modo de fixação de ", type, " no eixo ", axis, " = ", fixed_value)

## A camera chama isto quando o clique no plano foi resolvido: o painel certo recebe a posicao.
func resolver_posicao_plano(pos: Vector3) -> void:
	var painel = null
	match current_placement_mode:
		PlacementMode.TX: painel = ui_tx
		PlacementMode.RX: painel = ui_rx
		PlacementMode.RIS: painel = ui_ris
	if painel != null:
		painel.aplicar_posicao(pos)
	end_plane_placement()

func end_plane_placement():
	current_placement_mode = PlacementMode.NONE
	current_placement_target_index = -1
	current_placement_axis = ""


# --- cena: limpar tudo ---

## Remove TX/RX/RIS e o resultado da simulacao (usado ao carregar um save).
func limpar_cena_dinamica() -> void:
	if ris_handler: ris_handler.clear_all()
	if rx_handler: rx_handler.clear_all()
	if tx_handler: tx_handler.clear_all()
	for painel in [ui_tx, ui_rx, ui_ris]:
		if painel != null:
			painel.recarregar()


# --- SAVE / LOAD ---

func save_project(save_name: String):
	if not engine:
		aviso("Erro: Motor de simulação não conectado.")
		return

	var base_dir = save_base_dir + "/" + save_name
	if not DirAccess.dir_exists_absolute(base_dir):
		DirAccess.make_dir_recursive_absolute(base_dir)

	var map_reference_to_save = current_map_path
	if current_map_path.ends_with(".osm"):
		var dest_osm = base_dir + "/cenario.osm"
		if DirAccess.copy_absolute(current_map_path, dest_osm) == OK:
			map_reference_to_save = "cenario.osm"
		else:
			print("[Manager] Erro ao copiar OSM. Salvando caminho absoluto original.")

	var snapshot = engine.get_simulation_snapshot()
	snapshot["map_reference"] = map_reference_to_save
	snapshot["scene_name"] = current_scene_name
	snapshot["timestamp"] = Time.get_datetime_string_from_system()

	var file = FileAccess.open(base_dir + "/savefile.bin", FileAccess.WRITE)
	if file:
		file.store_var(snapshot)
		file.close()
		print("[Manager] Simulação salva com sucesso em: ", base_dir)
	else:
		aviso("Erro de permissão ao gravar arquivo de save.")

func load_project(save_name: String):
	var base_dir = save_base_dir + "/" + save_name
	var file_path = base_dir + "/savefile.bin"

	if not FileAccess.file_exists(file_path):
		aviso("Arquivo de save não encontrado ou corrompido.")
		return

	print("[Manager] Carregando: ", save_name)

	var file = FileAccess.open(file_path, FileAccess.READ)
	var snapshot = file.get_var()
	file.close()

	var ref = ""
	var nome_cena = save_name
	if typeof(snapshot) == TYPE_DICTIONARY and "map_reference" in snapshot:
		ref = snapshot["map_reference"]
		if "scene_name" in snapshot:
			nome_cena = snapshot["scene_name"]
	elif typeof(snapshot) == TYPE_DICTIONARY and "osm_filename" in snapshot:
		ref = snapshot["osm_filename"]
	else:
		aviso("Save incompatível ou corrompido.")
		return

	var load_path = ref
	if ref == "cenario.osm":
		load_path = base_dir + "/" + ref

	if ui_cenas != null:
		ui_cenas.carregar_cena(nome_cena, load_path, snapshot)   # chamada direta
	else:
		aviso("Menu de cenas não encontrado.")


# --- CONFIG (settings.cfg) ---

func ler_config(secao: String, chave: String, padrao):
	var config = ConfigFile.new()
	if config.load(config_file_path) != OK:
		return padrao
	return config.get_value(secao, chave, padrao)

func save_global_config(sim_data: Dictionary, cam_data: Dictionary, map_data: Dictionary):
	var config = ConfigFile.new()
	config.load(config_file_path)   # mantem o que ja existe

	if not sim_data.is_empty():
		config.set_value("Simulador", "los", sim_data.get("los_ativado", true))
		config.set_value("Simulador", "reflexao", sim_data.get("reflection_ativado", true))
		config.set_value("Simulador", "difracao", sim_data.get("diffraction_ativado", true))
		config.set_value("Simulador", "pixels_per_frame", sim_data.get("pixels_per_frame", 256))
		config.set_value("Simulador", "max_reflections", sim_data.get("max_reflections", 5))
		config.set_value("Simulador", "reflection_loss_db", sim_data.get("reflection_loss_db", 5.0))
		config.set_value("Simulador", "path_loss_exponent", sim_data.get("path_loss_exponent", 2.8))
		config.set_value("Simulador", "cor_max", sim_data.get("max_sinal_color", Color.RED))
		config.set_value("Simulador", "cor_crit", sim_data.get("critical_sinal_color", Color.GREEN))
		config.set_value("Simulador", "cor_min", sim_data.get("min_sinal_color", Color.BLUE))

	if not cam_data.is_empty():
		config.set_value("Camera", "speed", cam_data.get("speed", 200.0))
		config.set_value("Camera", "sensitivity", cam_data.get("sensitivity", 0.2))
		config.set_value("Camera", "fov", cam_data.get("fov", 70.0))

	if not map_data.is_empty():
		config.set_value("Heatmap", "min_dbm", map_data.get("min_dbm", -110.0))
		config.set_value("Heatmap", "crit_dbm", map_data.get("crit_dbm", -95.0))
		config.set_value("Heatmap", "max_dbm", map_data.get("max_dbm", -60.0))
		config.set_value("Heatmap", "mostrar_escala", map_data.get("mostrar_escala", false))

	var err = config.save(config_file_path)
	if err == OK and DEBUG:
		print("[Manager] Configurações globais salvas com sucesso.")

## Le o settings.cfg e APLICA direto na camera e no motor (os dialogos leem do arquivo ao abrir).
func load_global_config():
	var config = ConfigFile.new()
	if config.load(config_file_path) != OK:
		if DEBUG: print("[Manager] Arquivo de config não encontrado. Usando padrões.")
		return false

	if camera != null:
		camera.aplicar_config(
			config.get_value("Camera", "speed", 200.0),
			config.get_value("Camera", "sensitivity", 0.2),
			config.get_value("Camera", "fov", 70.0))

	if engine != null:
		engine.update_power_limits(
			config.get_value("Heatmap", "min_dbm", -110.0),
			config.get_value("Heatmap", "crit_dbm", -95.0),
			config.get_value("Heatmap", "max_dbm", -60.0))
		engine.aplicar_config_simulador({
			"los_ativado": config.get_value("Simulador", "los", true),
			"reflection_ativado": config.get_value("Simulador", "reflexao", true),
			"diffraction_ativado": config.get_value("Simulador", "difracao", true),
			"pixels_per_frame": config.get_value("Simulador", "pixels_per_frame", 256),
			"max_reflections": config.get_value("Simulador", "max_reflections", 5),
			"reflection_loss_db": config.get_value("Simulador", "reflection_loss_db", 5.0),
			"path_loss_exponent": config.get_value("Simulador", "path_loss_exponent", 2.8),
			"max_sinal_color": config.get_value("Simulador", "cor_max", Color.RED),
			"critical_sinal_color": config.get_value("Simulador", "cor_crit", Color.GREEN),
			"min_sinal_color": config.get_value("Simulador", "cor_min", Color.BLUE),
		})
	return true
