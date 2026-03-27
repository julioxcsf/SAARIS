# node_tx.gd
extends Node3D

func _ready():
	# Escutar o Manager
	Manager.request_add_tx.connect(_add_tx)
	Manager.request_remove_tx.connect(_remove_tx)
	Manager.request_update_tx.connect(_update_tx)
	Manager.request_get_tx_info.connect(_get_tx_info)

func _add_tx():
	var new_tx = Manager.tx_scene.instantiate()
	add_child(new_tx)
	
	# --- PADRÕES SOLICITADOS (Batismo) ---
	new_tx.position = Vector3(0, 30, 0) # Altura 30m
	new_tx.set("potencia_dbm", 40.0)    # 40 dBm
	new_tx.set("freq_mhz", 2400.0)      # 2400 MHz
	new_tx.set("ligado", true)
	
	# Nome sequencial
	new_tx.name = "TX_" + str(new_tx.get_index())
	
	print("[TX Handler] Criada antena padrão: ", new_tx.name)
	
	# Avisa a UI que criou (para aparecer na lista)
	Manager.handshake_tx_created.emit(new_tx.get_index(), new_tx.name)
	
	# Avisa quem estiver ouvindo que a antena já nasceu com dados prontos
	# (Isso força a UI a atualizar os campos se ela estiver selecionada)
	_get_tx_info(new_tx.get_index())

func _remove_tx(index: int):
	if index < get_child_count():
		get_child(index).queue_free()
		# Aguarda o frame para garantir que o índice atualize na árvore
		await get_tree().process_frame 
		Manager.handshake_tx_deleted.emit(index)

func _update_tx(index: int, params: Dictionary):
	if index < get_child_count():
		var tx = get_child(index)
		if params.has("ligado"): tx.set("ligado", params["ligado"])
		if params.has("freq"): tx.set("freq_mhz", params["freq"])
		if params.has("potencia"): tx.set("potencia_dbm", params["potencia"])
		if params.has("posicao"): tx.position = params["posicao"]
		print("[TX Handler] TX ", index, " atualizado.")

# --- Devolve o pacote de dados para a UI --- #WARNING buscar por NOVO: para tirar comentarios de IA
func _get_tx_info(index: int):
	if index >= 0 and index < get_child_count():
		var tx = get_child(index)
		var data = {
			"ligado": tx.get("ligado"),
			"freq": tx.get("freq_mhz"),
			"potencia": tx.get("potencia_dbm"),
			"posicao": tx.position
		}
		Manager.response_tx_info.emit(index, data)
