# resolucao_config.gd

extends HBoxContainer

# referencia para entradas de resolucao
@onready var opt_resolution: OptionButton = $ResolucaoOptionButton
@onready var spin_res_x: SpinBox = $ResolucaoOptionButton/AcceptDialog/ContainerDasSpinBoxes/SpinBoxX
@onready var spin_res_y: SpinBox = $ResolucaoOptionButton/AcceptDialog/ContainerDasSpinBoxes/SpinBoxY
@onready var janela_resolution: AcceptDialog = $ResolucaoOptionButton/AcceptDialog

func _ready() -> void:
	setup_resolution_ui()

# Dicionario de Presets (ID -> Vector2i)
var resolution_presets = {
	0: Vector2i(128, 128),
	1: Vector2i(256, 256),
	2: Vector2i(512, 512),
	3: Vector2i(1024, 1024),
	4: Vector2i(2048, 2048),
	5: Vector2i(4096, 4096)
}

func setup_resolution_ui():
	opt_resolution.clear()
	opt_resolution.add_item("128 x 128 (Rápido)") # ID 0
	opt_resolution.add_item("256 x 256 (Padrão)") # ID 1
	opt_resolution.add_item("512 x 512 (Alta)")   # ID 2
	opt_resolution.add_item("1024 x 1024 (Ultra)")# ID 3
	opt_resolution.add_item("2048 x 2048 (Ultra)")# ID 3
	opt_resolution.add_item("4096 x 4096 (Ultra)")# ID 3

	opt_resolution.item_selected.connect(_on_resolution_selected)
	janela_resolution.confirmed.connect(_on_janela_res_confirmed)
	Manager.ui_resolucao = self

	opt_resolution.select(1)
	spin_res_x.value = 256
	spin_res_y.value = 256

	# Inicia com o padrao (256x256)
	opt_resolution.select(1)

func _on_resolution_selected(index: int):
	if resolution_presets.has(index):
		var res = resolution_presets[index]

		spin_res_x.set_value_no_signal(res.x)
		spin_res_y.set_value_no_signal(res.y)

		Manager.engine.mapa_calor.resolution = res

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
	Manager.engine.mapa_calor.resolution = nova_res      # direto, sem sinal

## Chamado pelo simulador ao carregar um save: espelha a resolucao nos controles.
func refletir_resolucao(res: Vector2i):
	var index_encontrado = -1
	for key in resolution_presets:
		if resolution_presets[key] == res:
			index_encontrado = key
			break
	if index_encontrado >= 0:
		opt_resolution.select(index_encontrado)
	spin_res_x.set_value_no_signal(res.x)
	spin_res_y.set_value_no_signal(res.y)
