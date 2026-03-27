extends ConfirmationDialog

@onready var item_list = $MarginContainer/ItemList

func _ready():
	# Conecta o sinal de quando o usuário clica no botão "OK" ou dá duplo clique
	if not self.confirmed.is_connected(_on_confirmed):
		self.confirmed.connect(_on_confirmed)
	if not item_list.item_activated.is_connected(_on_item_double_clicked):
		item_list.item_activated.connect(_on_item_double_clicked)
		
	# MÁGICA DE UI: Adiciona o botão "Apagar" dinamicamente no rodapé da janela
	self.add_button("Apagar Selecionado", false, "apagar_save")
	if not self.custom_action.is_connected(_on_custom_action):
		self.custom_action.connect(_on_custom_action)

# Função para ser chamada quando você apertar o botão "Load" na sua UI principal
func open_browser():
	item_list.clear()
	var dir = DirAccess.open(Manager.save_base_dir)

	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		var has_saves = false
		
		# Varre todas as pastas dentro de user://Saves/
		while file_name != "":
			if dir.current_is_dir() and not file_name.begins_with("."):
				# Adiciona o nome da pasta (que é o nome do save) na lista
				item_list.add_item(file_name)
				has_saves = true
			file_name = dir.get_next()
			
		if not has_saves:
			Manager.emit_user_warning("A pasta de saves está vazia.")
			return
			
		# Exibe a janela se encontrou saves
		self.popup_centered(Vector2(400, 300))
	else:
		Manager.emit_user_warning("Erro ao tentar acessar o diretório de saves.")

func _on_confirmed():
	var selected_items = item_list.get_selected_items()
	
	if selected_items.size() == 0:
		Manager.emit_user_warning("Por favor, selecione um projeto para carregar.")
		return
		
	# Pega o texto (nome da pasta) do item selecionado
	var save_name = item_list.get_item_text(selected_items[0])
	
	print("[SaveBrowser] Solicitando carregamento do projeto: ", save_name)
	
	# Passa o bastão para o Manager
	Manager.load_project(save_name)
	
	# Esconde a janela
	self.hide()

func _on_custom_action(action: StringName):
	if action == "apagar_save":
		var selected_items = item_list.get_selected_items()
		if selected_items.size() == 0:
			Manager.emit_user_warning("Selecione um projeto na lista para apagar.")
			return
			
		var save_name = item_list.get_item_text(selected_items[0])
		_delete_save_folder(save_name)
		
		# Atualiza a lista imediatamente após apagar
		open_browser()

# Lógica robusta para deletar pastas com arquivos dentro
func _delete_save_folder(save_name: String):
	var path_to_delete = Manager.save_base_dir + "/" + save_name
	var dir = DirAccess.open(path_to_delete)
	
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		
		# Apaga todos os arquivos lá dentro primeiro
		while file_name != "":
			if not dir.current_is_dir() and file_name != "." and file_name != "..":
				dir.remove(file_name) 
			file_name = dir.get_next()
			
		# Agora que está vazia, apagamos a pasta em si passando o caminho em STRING
		var err = DirAccess.remove_absolute(path_to_delete)
		
		if err == OK:
			print("[SaveBrowser] Projeto apagado permanentemente: ", save_name)
		else:
			Manager.emit_user_warning("Erro de permissão ao tentar apagar a pasta do sistema.")
	else:
		Manager.emit_user_warning("Erro: Pasta de save não encontrada para apagar.")

func _on_item_double_clicked(index: int):
	# Se o usuário der duplo clique na lista, carrega na hora
	_on_confirmed()
