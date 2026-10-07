# node_tx.gd
extends Node3D

var tx_cache : Array = []
var _contador: int = 0

func _ready():
	# Registra a si mesmo no autoload para acesso direto global
	Manager.tx_handler = self

func add_tx():
	var new_tx = Manager.tx_scene.instantiate()
	add_child(new_tx)

	# --- PADROES SOLICITADOS (Batismo) ---
	new_tx.position = Vector3(0, 30, 0) # Altura 30m
	if Manager.geo != null and Manager.geo.has_method("posicao_padrao_tx"):
		new_tx.position = Manager.geo.posicao_padrao_tx()   # centro da regiao, 30 m sobre o terreno
	new_tx.set("potencia_dbm", 40.0)    # 40 dBm
	new_tx.set("freq_mhz", 2400.0)      # 2.4 GHz
	new_tx.set("ligado", true)

	tx_cache.append(new_tx)

	# Nome sequencial (monotonico: nao repete nome apos remocoes)
	_contador += 1
	var idx = tx_cache.size() - 1
	new_tx.name = "TX_" + str(_contador)

	print("[TX Handler] Criada antena padrão: ", new_tx.name)
	_atualizar_ris()

	# Retorna um pacote contendo o indice e os dados iniciais para a UI se atualizar na hora
	return {
		"index": idx,
		"name": new_tx.name,
		"data": get_tx_info(idx)
	}


func remove_tx(index: int) -> bool:
	if index >= 0 and index < tx_cache.size():
		var tx_para_remover = tx_cache[index]
		tx_para_remover.queue_free()
		tx_cache.remove_at(index)
		print("[TX Handler] Antena removida do índice: ", index)
		_atualizar_ris()
		return true # Confirmacao de sucesso
	return false

func update_tx(index: int, params: Dictionary) -> void:
	if index >= 0 and index < tx_cache.size():
		var tx = tx_cache[index]
		if params.has("ligado"): tx.set("ligado", params["ligado"])
		if params.has("freq"): tx.set("freq_mhz", params["freq"])
		if params.has("potencia"): tx.set("potencia_dbm", params["potencia"])
		if params.has("posicao"): tx.position = params["posicao"]
		_atualizar_ris()

## Remove todos os TX (usado ao carregar um save).
func clear_all() -> void:
	for tx in tx_cache:
		if is_instance_valid(tx):
			tx.queue_free()
	tx_cache.clear()

func get_tx_info(index: int) -> Dictionary:
	if index >= 0 and index < tx_cache.size():
		var tx = tx_cache[index]
		return {
			"ligado": tx.get("ligado"),
			"freq": tx.get("freq_mhz"),
			"potencia": tx.get("potencia_dbm"),
			"posicao": tx.position
		}
	return {}

## TX mudou (posicao/potencia/liga-desliga): os RIS reorientam e o diagnostico se atualiza.
func _atualizar_ris() -> void:
	if Manager.ris_handler != null:
		Manager.ris_handler.recalcular_todos()
