extends MenuButton

signal import_OSM

@onready var janela_dialog = $SceneAcceptDialog
@onready var pick_file_button = $SceneAcceptDialog/VBoxContainer/pick_file_Button
@onready var fileDialog = $SceneAcceptDialog/VBoxContainer/pick_file_Button/FileDialog
@onready var new_scene_name = $SceneAcceptDialog/VBoxContainer/TextEdit
@onready var file_path = $SceneAcceptDialog/VBoxContainer/file_path

func _ready() -> void:
	_setup_ui_scene()

func _setup_ui_scene():
	var popup = self.get_popup()
	if not popup.id_pressed.is_connected(_on_scene_menu_id_pressed):
		popup.id_pressed.connect(_on_scene_menu_id_pressed)
	
	pick_file_button.pressed.connect(func(): fileDialog.popup_centered())
	
	if not fileDialog.file_selected.is_connected(_on_osm_file_selected):
		fileDialog.file_selected.connect(_on_osm_file_selected)
	
	if not janela_dialog.confirmed.is_connected(_on_janela_import_confirmed):
		janela_dialog.confirmed.connect(_on_janela_import_confirmed)
	
	# Caminho absoluto baseado na sua imagem da árvore (Main -> Simulation -> OSM_Importer)
	var path_importer = "/root/Main/Simulation/OSM_Importer"
	var importer = get_node_or_null(path_importer)
	
	if importer:
		print("[UI] Sucesso: Importer encontrado! Conectando fio direto...")

		if self.import_OSM.is_connected(importer.importar_pelo_caminho):
			self.import_OSM.disconnect(importer.importar_pelo_caminho)
			
		self.import_OSM.connect(importer.importar_pelo_caminho)
		print("[UI] Conexão Realizada: Botão -> Importer")
	else:
		print("[UI] ERRO: Não achei o importer em: ", path_importer)
		print("[UI] Dica: Verifique se o nó pai se chama 'Simulation' mesmo.")

func _on_scene_menu_id_pressed(id: int):
	# Se for o primeiro item (Importar OSM)
	if id == 0: 
		# Abre a janela que pede Nome e Arquivo
		janela_dialog.popup_centered()

func _on_osm_file_selected(path: String):
	# Escreve o caminho no Label para o usuário ver o que escolheu
	file_path.text = path
	# Guarda no metadado para não perder
	self.set_meta("current_osm_path", path)
	print("Interface: Arquivo selecionado: ", path)

func _on_janela_import_confirmed():
	# Pega o nome do TextEdit (ou LineEdit)
	var nome = new_scene_name.text
	
	# Pega o path que guardamos
	var path = self.get_meta("current_osm_path") if self.has_meta("current_osm_path") else ""
	
	if path == "" or nome == "":
		print("Interface: Erro - Nome ou Path vazios!")
		return
		
	print("Interface: Enviando solicitação de importação: ", nome, " | ", path)
	
	# Emite o sinal para o simulador
	emit_signal("import_OSM", path, nome)
	
	# Limpa para a próxima vez
	new_scene_name.text = ""
	file_path.text = "Nenhum arquivo selecionado"
	self.set_meta("current_osm_path", "")
