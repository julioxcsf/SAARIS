extends OptionButton

@onready var janela_dialog = $SceneAcceptDialog
@onready var pick_file_button = $SceneAcceptDialog/VBoxContainer/pick_file_Button
@onready var fileDialog = $SceneAcceptDialog/VBoxContainer/pick_file_Button/FileDialog
@onready var new_scene_name = $SceneAcceptDialog/VBoxContainer/TextEdit
@onready var file_path = $SceneAcceptDialog/VBoxContainer/file_path

const MAX_CUSTOM_SCENES = 5
const ID_ADD_SCENE = 98
const ID_REMOVE_SCENE = 99

var scene_paths = {}
var last_selected_index = 0
var next_custom_id = 10 

func _ready() -> void:
	_setup_ui_connections()
	_build_default_menu()

func _setup_ui_connections():
	if not self.item_selected.is_connected(_on_option_item_selected):
		self.item_selected.connect(_on_option_item_selected)
	
	pick_file_button.pressed.connect(func(): fileDialog.popup_centered())
	if not fileDialog.file_selected.is_connected(_on_osm_file_selected):
		fileDialog.file_selected.connect(_on_osm_file_selected)
	if not janela_dialog.confirmed.is_connected(_on_janela_import_confirmed):
		janela_dialog.confirmed.connect(_on_janela_import_confirmed)
	
	Manager.request_load_scene_ui.connect(_on_load_scene_requested)

func _build_default_menu():
	self.clear()
	scene_paths.clear()
	
	self.add_item("Cenário de Teste", 0)
	scene_paths[0] = "res://Cenas/cenario_validacao.tscn"
	
	self.add_item("Ilha do Fundão", 1)
	scene_paths[1] = "res://Toda_ilha_fundao.osm"
	
	self.add_separator()
	self.add_item("Adicionar Cena...", ID_ADD_SCENE)
	self.add_item("Remover Cena Atual", ID_REMOVE_SCENE)
	
	self.set_item_disabled(self.item_count - 1, true) # Bloqueia exclusão dos mapas base
	
	self.select(0)
	last_selected_index = 0

func _on_option_item_selected(index: int):
	var id = self.get_item_id(index)
	
	if id == ID_ADD_SCENE:
		self.select(last_selected_index) 
		_open_import_dialog()
	elif id == ID_REMOVE_SCENE:
		self.select(last_selected_index) 
		_remove_current_scene()
	else:
		last_selected_index = index
		var nome_cena = self.get_item_text(index)
		var caminho = scene_paths.get(id, "")
		
		# Habilita o botão remover apenas para cenas com ID >= 10
		self.set_item_disabled(self.item_count - 1, id < 10)
		
		if caminho != "":
			Manager.emit_import_request(caminho, nome_cena)

func _open_import_dialog():
	var custom_count = self.item_count - 5 
	if custom_count >= MAX_CUSTOM_SCENES:
		Manager.emit_user_warning("Limite de %d cenas customizadas atingido.\nRemova uma para adicionar outra." % MAX_CUSTOM_SCENES)
		return
	janela_dialog.popup_centered()

func _remove_current_scene():
	var current_id = self.get_item_id(last_selected_index)
	if current_id < 10: return # Impede apagar o Teste ou a UFRJ
	
	scene_paths.erase(current_id)
	self.remove_item(last_selected_index)
	
	# Volta a seleção e variáveis para a cena padrão (Index 0) com segurança
	self.select(0)
	last_selected_index = 0
	self.set_item_disabled(self.item_count - 1, true)
	
	var default_path = scene_paths[0]
	var default_nome = self.get_item_text(0)
	Manager.emit_import_request(default_path, default_nome)

func _on_osm_file_selected(path: String):
	file_path.text = path
	self.set_meta("current_osm_path", path)

func _on_janela_import_confirmed():
	var nome = new_scene_name.text
	var path = self.get_meta("current_osm_path") if self.has_meta("current_osm_path") else ""
	
	if path == "" or nome == "":
		Manager.emit_user_warning("Nome ou Caminho do arquivo inválidos.")
		return
		
	_register_and_load_new_scene(nome, path)
	
	new_scene_name.text = ""
	file_path.text = "Nenhum arquivo selecionado"
	self.set_meta("current_osm_path", "")

func _register_and_load_new_scene(nome: String, path: String, snapshot_to_apply: Dictionary = {}):
	var custom_count = self.item_count - 5 
	if custom_count >= MAX_CUSTOM_SCENES:
		Manager.emit_user_warning("Limite de cenas atingido. Remova uma manualmente primeiro.")
		return
		
	var idx_rem = self.get_item_index(ID_REMOVE_SCENE)
	var idx_add = self.get_item_index(ID_ADD_SCENE)
	
	if idx_rem != -1: self.remove_item(idx_rem)
	if idx_add != -1: self.remove_item(idx_add)
	self.remove_item(self.item_count - 1)
	
	# Adiciona a nova cena e registra
	self.add_item(nome, next_custom_id)
	scene_paths[next_custom_id] = path
	
	# Reconstrói os botões fixos do rodapé
	self.add_separator()
	self.add_item("Adicionar Cena...", ID_ADD_SCENE)
	self.add_item("Remover Cena Atual", ID_REMOVE_SCENE)
	
	# Atualiza o foco da lista para a cena recém-criada
	var novo_index = self.item_count - 4
	self.select(novo_index)
	last_selected_index = novo_index
	self.set_item_disabled(self.item_count - 1, false) 
	
	next_custom_id += 1
	
	Manager.emit_import_request(path, nome)
	
	if not snapshot_to_apply.is_empty():
		_apply_snapshot_deferred(snapshot_to_apply)

func _on_load_scene_requested(nome: String, path: String, snapshot: Dictionary):
	for index in range(self.item_count):
		var id = self.get_item_id(index)
		if scene_paths.has(id) and scene_paths[id] == path:
			self.select(index)
			last_selected_index = index
			self.set_item_disabled(self.item_count - 1, id < 10)
			Manager.emit_import_request(path, nome)
			if not snapshot.is_empty():
				_apply_snapshot_deferred(snapshot)
			return
			
	_register_and_load_new_scene(nome, path, snapshot)

func _apply_snapshot_deferred(snapshot: Dictionary):
	print("[UI] Aguardando o Importer construir o mapa tridimensional...")
	
	# O CÓDIGO FICA PAUSADO AQUI ATÉ O MAPA EXISTIR
	await Manager.map_loaded_successfully 
	
	print("[UI] Mapa pronto! Mandando o Simulador posicionar TX, RX e RIS.")
	if Manager.engine:
		Manager.engine.apply_simulation_snapshot(snapshot)
