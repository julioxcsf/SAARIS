extends Node

# Sinais de controle de simulação
signal request_start
signal request_stop
signal request_cancel
signal simulation_progress_update(percent: float)
signal simulation_stats_received(data: Dictionary)
signal show_user_warning(mensagem: String)

# Sinais de controle de importação
signal request_import(path: String, nome: String)
signal request_load_scene_ui(nome: String, path: String, snapshot: Dictionary)
signal map_loaded_successfully

# Sinais de ajuste de resolução e mapa
signal request_heatmap_config(min_dbm: float, crit_dbm: float, max_dbm: float)
signal request_resolution_update(new_res: Vector2i)

# Sinais de controle de TX
signal request_add_tx
signal request_remove_tx(index: int)
signal request_update_tx(index: int, params: Dictionary)
signal request_get_tx_info(index: int)
signal response_tx_info(index: int, data: Dictionary)
signal handshake_tx_created(index: int, nome: String)
signal handshake_tx_deleted(index: int)
signal handshake_tx_updated(index: int, params: Dictionary)
signal handshake_tx_clear_all

# Sinais de controle de RX
signal request_place_target
signal request_remove_target(index: int)
signal request_update_target(index: int, params: Dictionary)
signal request_get_target_info(index: int)
signal response_target_info(index: int, data: Dictionary)
signal request_reconstruct_target(data: Dictionary)
signal handshake_target_created(index: int, nome: String)
signal handshake_target_deleted(index: int)
signal handshake_target_clear_all

# Sinais de controle de RIS
signal request_add_ris(copy_data: Variant)
signal request_remove_ris(index: int)
signal request_update_ris(index: int, params: Dictionary)
signal request_get_ris_info(index: int)
signal response_ris_info(index: int, data: Dictionary)
signal request_toggle_ris(is_active: bool)
signal handshake_ris_created(index: int, nome: String)
signal handshake_ris_deleted(index: int)
signal handshake_ris_clear_all

# Sinais de câmera e intersecção
signal placement_click_resolved(new_pos: Vector3)
signal power_probe_updated(dbm: float, pos: Vector3)
signal request_camera_config(speed: float, sensitivity: float, fov: float)

# Sinais do simulador
signal simulation_state_changed(busy: bool)
signal request_simulator_config(config_data: Dictionary)


var tx_container: Node3D = null
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

var engine = null
var importer = null
var is_simulating: bool = false : 
	set(val):
		is_simulating = val
		simulation_state_changed.emit(val)
var is_probe_active: bool = false
var DEBUG = false

# Inicializa o gerenciador e cria o diretório de saves caso não exista.
func _ready():
	if DEBUG:
		print("[Manager] Hub sintonizado.")
		
	# MÁGICA PORTÁTIL: Define a pasta local do projeto ou do executável
	if OS.has_feature("editor"):
		# No editor, salva na pasta raiz do projeto de forma absoluta
		save_base_dir = ProjectSettings.globalize_path("res://Saves")
	else:
		# No .exe exportado, salva do lado do executável
		save_base_dir = OS.get_executable_path().get_base_dir() + "/Saves"
		
	# Garante que a pasta existe antes de qualquer coisa
	if not DirAccess.dir_exists_absolute(save_base_dir):
		DirAccess.make_dir_recursive_absolute(save_base_dir)
		
	var target_candelaria = save_base_dir + "/Candelaria_RIS"
	if not DirAccess.dir_exists_absolute(target_candelaria):
		print("[Manager] Inicializando save de avaliação (Candelaria_RIS)...")
		DirAccess.make_dir_recursive_absolute(target_candelaria)
		
		# Copia o binário e o OSM do cofre res:// para a pasta dinâmica onde o jogo enxerga
		DirAccess.copy_absolute("res://Assets_BKP_Saves/Candelaria_RIS/savefile.bin", target_candelaria + "/savefile.bin")
		if FileAccess.file_exists("res://Assets_BKP_Saves/Candelaria_RIS/cenario.osm"):
			DirAccess.copy_absolute("res://Assets_BKP_Saves/Candelaria_RIS/cenario.osm", target_candelaria + "/cenario.osm")
		
	# Trava o caminho do arquivo de configuração
	config_file_path = save_base_dir + "/settings.cfg"
	call_deferred("load_global_config")

# Emite um alerta visual na interface do usuário.
func emit_user_warning(msg: String):
	show_user_warning.emit(msg)


# Solicita a adição de um novo transmissor na cena.
func emit_add_tx_request():
	request_add_tx.emit()

# Solicita a remoção de um transmissor específico pelo índice.
func emit_remove_tx_request(index: int):
	request_remove_tx.emit(index)

# Solicita a atualização dos parâmetros de um transmissor existente.
func emit_update_tx_request(index: int, params: Dictionary):
	request_update_tx.emit(index, params)

# Solicita os dados de um transmissor para exibição ou processamento.
func emit_get_tx_info(index: int):
	request_get_tx_info.emit(index)


# Solicita o posicionamento de um novo receptor na cena.
func emit_place_target():
	request_place_target.emit()

# Solicita a remoção de um receptor específico pelo índice.
func emit_remove_target(index: int):
	request_remove_target.emit(index)

# Solicita a atualização dos parâmetros de um receptor existente.
func emit_update_target(index: int, params: Dictionary):
	request_update_target.emit(index, params)

# Solicita os dados de um receptor para exibição ou processamento.
func emit_get_target_info(index: int):
	request_get_target_info.emit(index)


# Solicita a adição de uma nova superfície refletora inteligente.
func emit_add_ris_request(copy_data: Variant = null): 
	request_add_ris.emit(copy_data)

# Solicita a remoção de uma superfície refletora específica.
func emit_remove_ris_request(index: int): 
	request_remove_ris.emit(index)

# Solicita a atualização dos parâmetros de uma superfície refletora.
func emit_update_ris_request(index: int, params: Dictionary): 
	request_update_ris.emit(index, params)

# Solicita os dados de uma superfície refletora para exibição.
func emit_get_ris_info(index: int): 
	request_get_ris_info.emit(index)

# Alterna o estado de visualização da superfície refletora.
func emit_toggle_ris(is_active: bool): 
	request_toggle_ris.emit(is_active)

# Notifica os manipuladores para recalcular a lógica das superfícies refletoras.
func _notify_ris_handlers():
	var ris_handler = get_node("../Node_RIS")
	for i in range(ris_handler.get_child_count()):
		ris_handler._recalculate_ris_logic(ris_handler.get_child(i))


# Dispara as configurações de mapeamento de calor.
func emit_heatmap_config(min_dbm: float, crit_dbm: float, max_dbm: float):
	request_heatmap_config.emit(min_dbm, crit_dbm, max_dbm)

# Dispara as configurações de controle da câmera.
func emit_camera_config(speed: float, sensitivity: float, fov: float):
	request_camera_config.emit(speed, sensitivity, fov)

# Dispara a atualização da resolução espacial do mapa.
func emit_resolution_update(new_res: Vector2i):
	request_resolution_update.emit(new_res)

# Envia o dicionário de configurações para o motor de simulação.
func emit_simulator_config(config_data: Dictionary):
	request_simulator_config.emit(config_data)

# Dispara o processo de importação de um novo mapa.
func emit_import_request(path: String, nome: String):
	current_map_path = path
	current_scene_name = nome
	request_import.emit(path, nome)


# Prepara o sistema para posicionar um elemento em um plano fixo.
func request_plane_placement(type: String, index: int, axis: String, fixed_value: float):
	if type == "TX": current_placement_mode = PlacementMode.TX
	elif type == "RX": current_placement_mode = PlacementMode.RX
	elif type == "RIS": current_placement_mode = PlacementMode.RIS
	
	current_placement_target_index = index
	current_placement_axis = axis
	current_placement_fixed_value = fixed_value
	
	if DEBUG:
		print("[Manager] Entrando em modo de fixação de ", type, " no eixo ", axis, " = ", fixed_value)

# Encerra o modo de posicionamento no plano.
func end_plane_placement():
	current_placement_mode = PlacementMode.NONE
	current_placement_target_index = -1
	current_placement_axis = ""


# Salva o estado atual do projeto e copia os arquivos de cenário necessários.
func save_project(save_name: String):
	if not engine:
		emit_user_warning("Erro: Motor de simulação não conectado.")
		return
	
	# ALTERAÇÃO AQUI: Usa a variável dinâmica em vez do user://
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
		emit_user_warning("Erro de permissão ao gravar arquivo de save.")

# Carrega um projeto salvo interpretando corretamente o formato do arquivo.
func load_project(save_name: String):
	var base_dir = save_base_dir + "/" + save_name
	var file_path = base_dir + "/savefile.bin"
	
	if not FileAccess.file_exists(file_path):
		emit_user_warning("Arquivo de save não encontrado ou corrompido.")
		return
		
	print("[Manager] Carregando: ", save_name)
	
	var file = FileAccess.open(file_path, FileAccess.READ)
	var snapshot = file.get_var()
	file.close()
	
	var ref = ""
	var nome_cena = save_name
	
	if "map_reference" in snapshot:
		ref = snapshot["map_reference"]
		if "scene_name" in snapshot:
			nome_cena = snapshot["scene_name"]
	elif "osm_filename" in snapshot:
		ref = snapshot["osm_filename"]
	else:
		emit_user_warning("Save incompatível ou corrompido.")
		return
		
	var load_path = ref
	
	if ref == "cenario.osm":
		load_path = base_dir + "/" + ref
		
	request_load_scene_ui.emit(nome_cena, load_path, snapshot)

# ==============================================================================
# SISTEMA DE CONFIGURAÇÃO (user://settings.cfg)
# ==============================================================================

# Salva as configurações atuais no disco
func save_global_config(sim_data: Dictionary, cam_data: Dictionary, map_data: Dictionary):
	var config = ConfigFile.new()
	
	# O SEGREDO ESTÁ AQUI: Tenta carregar o arquivo existente primeiro.
	# Se existir, ele puxa tudo. Se não existir, ele ignora e segue a vida.
	config.load(config_file_path)
	
	# Aba: Ajustes do Simulador
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

	# Aba: Ajustes de Câmera
	if not cam_data.is_empty():
		config.set_value("Camera", "speed", cam_data.get("speed", 200.0))
		config.set_value("Camera", "sensitivity", cam_data.get("sensitivity", 0.2))
		config.set_value("Camera", "fov", cam_data.get("fov", 70.0))

	# Aba: Ajuste no mapa de cor
	if not map_data.is_empty():
		config.set_value("Heatmap", "min_dbm", map_data.get("min_dbm", -110.0))
		config.set_value("Heatmap", "crit_dbm", map_data.get("crit_dbm", -95.0))
		config.set_value("Heatmap", "max_dbm", map_data.get("max_dbm", -60.0))
		config.set_value("Heatmap", "mostrar_escala", map_data.get("mostrar_escala", false))

	var err = config.save(config_file_path)
	if err == OK and DEBUG:
		print("[Manager] Configurações globais salvas com sucesso.")

# Carrega as configurações e dispara os sinais para o motor e UI
func load_global_config():
	var config = ConfigFile.new()
	var err = config.load(config_file_path)
	
	if err != OK:
		if DEBUG: print("[Manager] Arquivo de config não encontrado. Usando padrões.")
		return false # Retorna falso para a UI saber que deve usar os valores padrão
	
	# 1. Recupera e emite configurações da Câmera
	var c_speed = config.get_value("Camera", "speed", 200.0)
	var c_sens = config.get_value("Camera", "sensitivity", 0.2)
	var c_fov = config.get_value("Camera", "fov", 70.0)
	emit_camera_config(c_speed, c_sens, c_fov)
	
	# 2. Recupera e emite configurações do Heatmap
	var h_min = config.get_value("Heatmap", "min_dbm", -110.0)
	var h_crit = config.get_value("Heatmap", "crit_dbm", -95.0)
	var h_max = config.get_value("Heatmap", "max_dbm", -60.0)
	emit_heatmap_config(h_min, h_crit, h_max)
	
	# 3. Recupera e emite configurações do Simulador
	var sim_data = {
		"los_ativado": config.get_value("Simulador", "los", true),
		"reflection_ativado": config.get_value("Simulador", "reflexao", true),
		"diffraction_ativado": config.get_value("Simulador", "difracao", true),
		"pixels_per_frame": config.get_value("Simulador", "pixels_per_frame", 256),
		"max_reflections": config.get_value("Simulador", "max_reflections", 5),
		"reflection_loss_db": config.get_value("Simulador", "reflection_loss_db", 5.0),
		"path_loss_exponent": config.get_value("Simulador", "path_loss_exponent", 2.8),
		"max_sinal_color": config.get_value("Simulador", "cor_max", Color.RED),
		"critical_sinal_color": config.get_value("Simulador", "cor_crit", Color.GREEN),
		"min_sinal_color": config.get_value("Simulador", "cor_min", Color.BLUE)
	}
	emit_simulator_config(sim_data)
	
	return true # Sucesso
