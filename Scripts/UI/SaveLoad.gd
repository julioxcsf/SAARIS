# SaveLoad.gd
extends MenuButton

@onready var save_browser = $SaveBrowserDialog

var save_as_dialog: ConfirmationDialog
var save_name_input: LineEdit

enum Opcoes { SAVE_AS = 0, LOAD = 1, HELP = 2 }

func _ready() -> void:
	_create_save_as_dialog()
	setup_menu()
	print("[UI_Menu] Botão de ações pronto e conectado.")

func _create_save_as_dialog():
	save_as_dialog = ConfirmationDialog.new()
	save_as_dialog.title = "Salvar Projeto Como..."
	
	# Cria um organizador vertical para empilhar os elementos sem sobreposição
	var vbox = VBoxContainer.new()
	
	var label = Label.new()
	label.text = "Digite o nome do projeto:"
	vbox.add_child(label)
	
	save_name_input = LineEdit.new()
	save_name_input.placeholder_text = "Ex: cena_teste_01"
	save_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL 
	vbox.add_child(save_name_input)
	
	save_as_dialog.add_child(vbox)
	save_as_dialog.confirmed.connect(_on_save_as_confirmed)
	add_child(save_as_dialog)

func setup_menu():
	var popup = get_popup()
	popup.clear()
	popup.add_item("Salvar Cena", Opcoes.SAVE_AS)
	popup.add_item("Carregar Cena", Opcoes.LOAD)
	popup.add_separator()
	popup.add_item("Ajuda", Opcoes.HELP)
	
	if not popup.id_pressed.is_connected(_on_item_pressed):
		popup.id_pressed.connect(_on_item_pressed)

func _on_item_pressed(id: int):
	match id:
		Opcoes.SAVE_AS:
			save_name_input.text = "" 
			save_as_dialog.popup_centered(Vector2(350, 100))
			save_name_input.grab_focus()
			
		Opcoes.LOAD:
			if save_browser:
				save_browser.open_browser()
			else:
				Manager.emit_user_warning("Erro: Janela do navegador de saves não encontrada.")
			
		Opcoes.HELP:
			OS.shell_open("https://github.com/julioxcsf/saaris")

func _on_save_as_confirmed():
	var nome = save_name_input.text.strip_edges()
	
	if nome == "":
		Manager.emit_user_warning("O nome do projeto não pode estar vazio.")
		return
		
	nome = nome.replace("/", "").replace("\\", "").replace(":", "").replace("*", "").replace("?", "").replace("\"", "").replace("<", "").replace(">", "").replace("|", "")
	
	print("[UI] Salvando como: ", nome)
	Manager.save_project(nome)
