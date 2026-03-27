# resolucao_config.gd

extends HBoxContainer

# referencia para entradas de resolucao
@onready var opt_resolution: OptionButton = $ResolucaoOptionButton
@onready var spin_res_x: SpinBox = $ResolucaoOptionButton/AcceptDialog/ContainerDasSpinBoxes/SpinBoxX
@onready var spin_res_y: SpinBox = $ResolucaoOptionButton/AcceptDialog/ContainerDasSpinBoxes/SpinBoxY
@onready var janela_resolution: AcceptDialog = $ResolucaoOptionButton/AcceptDialog

func _ready() -> void:
	setup_resolution_ui()

# Dicionário de Presets (ID -> Vector2i)
var resolution_presets = {
	0: Vector2i(128, 128),
	1: Vector2i(256, 256),
	2: Vector2i(512, 512),
	3: Vector2i(1024, 1024)
}

func setup_resolution_ui():
	opt_resolution.clear()
	opt_resolution.add_item("128 x 128 (Rápido)") # ID 0
	opt_resolution.add_item("256 x 256 (Padrão)") # ID 1
	opt_resolution.add_item("512 x 512 (Alta)")   # ID 2
	opt_resolution.add_item("1024 x 1024 (Ultra)")# ID 3
	opt_resolution.add_item("Personalizado")      # ID 4
	
	opt_resolution.item_selected.connect(_on_resolution_selected)
	janela_resolution.confirmed.connect(_on_janela_res_confirmed)
	Manager.request_load_scene_ui.connect(_on_scene_loaded)
	
	opt_resolution.select(1)
	spin_res_x.value = 256
	spin_res_y.value = 256
	
	# Inicia com o padrão (256x256)
	opt_resolution.select(1) 

func _on_resolution_selected(index: int):
	if resolution_presets.has(index):
		var res = resolution_presets[index]
		
		spin_res_x.set_value_no_signal(res.x)
		spin_res_y.set_value_no_signal(res.y)
		
		Manager.emit_resolution_update(res)
		
	else:
		janela_resolution.popup_centered()
		spin_res_x.editable = true
		spin_res_y.editable = true
		spin_res_x.grab_focus()

func _on_janela_res_confirmed():
	# Agora sim, lemos os valores finais
	var x = int(spin_res_x.value)
	var y = int(spin_res_y.value)
	var nova_res = Vector2i(x, y)
	
	print("Resolução Personalizada Confirmada: ", nova_res)
	Manager.emit_resolution_update(nova_res)

func _on_scene_loaded(_nome: String, _path: String, snapshot: Dictionary):
	if snapshot.has("resolution"):
		var res = snapshot["resolution"]
		var index_encontrado = 4 # Padrão para 'Personalizado'
		
		# Varre os presets para ver se a resolução salva é uma das opções padrões
		for key in resolution_presets:
			if resolution_presets[key] == res:
				index_encontrado = key
				break
				
		opt_resolution.select(index_encontrado)
		spin_res_x.set_value_no_signal(res.x)
		spin_res_y.set_value_no_signal(res.y)
