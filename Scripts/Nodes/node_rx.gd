# node_rx.gd
extends Node3D

func _ready():
	Manager.request_place_target.connect(_add_rx)
	Manager.request_remove_target.connect(_remove_rx)
	Manager.request_update_target.connect(_update_rx)
	Manager.request_get_target_info.connect(_get_rx_info)
	Manager.request_reconstruct_target.connect(_reconstruct_rx)

func _add_rx():
	var new_rx = MeshInstance3D.new()
	var mesh = BoxMesh.new()
	new_rx.mesh = mesh
	
	var material = StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.9, 0.1, 0.9, 0.2)
	new_rx.material_override = material
	
	add_child(new_rx)
	
	# --- PADRÕES INICIAIS ---
	new_rx.position = Vector3(0, 1.0, 0)
	
	# Metadata essencial para a conta de área do RIS
	new_rx.set_meta("width", 1.0)
	new_rx.set_meta("length", 1.0)
	new_rx.set_meta("rotation", 0.0)
	
	new_rx.mesh.size = Vector3(1.0, 1.0, 1.0)
	new_rx.name = "Alvo_" + str(new_rx.get_index())
	
	Manager.handshake_target_created.emit(new_rx.get_index(), new_rx.name)
	_get_rx_info(new_rx.get_index())
	
	# Notifica o RIS que um novo alvo apareceu para ele se orientar
	_notify_ris_handlers()

func _remove_rx(index: int):
	if index < get_child_count():
		get_child(index).queue_free()
		await get_tree().process_frame 
		Manager.handshake_target_deleted.emit(index)
		_notify_ris_handlers() # Notifica na remoção também

func _update_rx(index: int, params: Dictionary):
	if index >= get_child_count(): return
	var rx = get_child(index)
	
	var novo_tamanho = rx.mesh.size 
	
	if params.has("width"): 
		rx.set_meta("width", params["width"])
		novo_tamanho.x = params["width"]
		
	if params.has("length"): 
		rx.set_meta("length", params["length"])
		novo_tamanho.z = params["length"]
		
	rx.mesh.size = novo_tamanho
		
	if params.has("rotation"): 
		rx.set_meta("rotation", params["rotation"])
		rx.rotation_degrees.y = params["rotation"]
		
	if params.has("posicao"): 
		rx.position = params["posicao"]
	
	# CRÍTICO: Dispara a reatividade do sistema
	_notify_ris_handlers()

# --- Função de Notificação para Reatividade ---
func _notify_ris_handlers():
	# Busca o handler de RIS para forçar o recálculo da Razão de Área e Bissetriz
	var ris_handler = get_node_or_null("../Node_RIS")
	if ris_handler:
		# Chama a função de atualização externa que o RIS já possui
		ris_handler._on_external_update(0, {})

func _get_rx_info(index: int):
	if index >= 0 and index < get_child_count():
		var rx = get_child(index)
		var data = {
			"width": rx.get_meta("width"),
			"length": rx.get_meta("length"),
			"rotation": rx.get_meta("rotation"),
			"posicao": rx.position
		}
		Manager.response_target_info.emit(index, data)

func _reconstruct_rx(data: Dictionary):
	# Chama o método de adição padrão para criar a estrutura
	_add_rx()
	
	# Pega o último filho criado (o que acabamos de adicionar)
	var rx = get_child(get_child_count() - 1)
	
	# Aplica os dados salvos do Snapshot
	var params = {
		"width": data.get("width", 1.0),
		"length": data.get("length", 1.0),
		"rotation": data.get("rotation", 0.0),
		"posicao": data.get("pos", Vector3.ZERO)
	}
	
	# Reutiliza a sua função de update para aplicar escala, rotação e metas
	_update_rx(rx.get_index(), params)
