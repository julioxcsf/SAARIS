# node_rx.gd - handler dos RX (regioes de cobertura de interesse do projetista).
# Sem sinais: a UI chama direto  Manager.rx_handler.add_rx() / update_rx(i, {...}) / ...
# Varios RX sao permitidos; cada RIS escolhe o seu RX alvo (ver node_ris.gd).
extends Node3D

var rx_cache: Array = []      # nos MeshInstance3D, na ordem de criacao
var _contador: int = 0        # numeracao monotonica dos nomes (RX_1, RX_2, ...)

func _ready():
	Manager.rx_handler = self


## Cria um RX. `params` opcional: width, length, rotation, posicao, importance.
## Retorna {index, name, data} (a UI se atualiza com isso, sem sinal).
func add_rx(params: Dictionary = {}) -> Dictionary:
	var novo = MeshInstance3D.new()
	novo.mesh = BoxMesh.new()

	var material = StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.9, 0.1, 0.9, 0.2)
	novo.material_override = material

	add_child(novo)
	rx_cache.append(novo)
	_contador += 1
	novo.name = "RX_%d" % _contador

	# Etiqueta flutuante para distinguir varios RX na cena
	var etiqueta = Label3D.new()
	etiqueta.name = "Etiqueta"
	etiqueta.text = novo.name
	etiqueta.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	etiqueta.no_depth_test = true
	etiqueta.pixel_size = 0.02
	etiqueta.position = Vector3(0, 1.2, 0)
	novo.add_child(etiqueta)

	novo.set_meta("width", 1.0)
	novo.set_meta("length", 1.0)
	novo.set_meta("rotation", 0.0)
	novo.set_meta("importance", 1.0)

	var pos = Vector3(0, 1.0, 0)
	if Manager.geo != null and Manager.geo.has_method("posicao_padrao_tx") and Manager.importer != null:
		var c: Vector3 = Manager.geo.posicao_padrao_tx()
		pos = Vector3(c.x, Manager.importer.terrain_height_at(c.x, c.z) + 1.5, c.z)
	novo.position = pos

	var indice = rx_cache.size() - 1
	update_rx(indice, params)
	return {"index": indice, "name": novo.name, "data": get_rx_info(indice)}


func remove_rx(index: int) -> bool:
	if index < 0 or index >= rx_cache.size():
		return false
	var rx = rx_cache[index]
	rx_cache.remove_at(index)
	if Manager.ris_handler != null:
		Manager.ris_handler.alvo_removido(rx)      # RIS que apontavam para ele ficam sem alvo
	remove_child(rx)
	rx.queue_free()
	_atualizar_ris()
	return true


func update_rx(index: int, params: Dictionary) -> void:
	if index < 0 or index >= rx_cache.size():
		return
	var rx: MeshInstance3D = rx_cache[index]
	var tamanho: Vector3 = rx.mesh.size

	if params.has("width"):
		rx.set_meta("width", maxf(0.1, float(params["width"])))
		tamanho.x = rx.get_meta("width")
	if params.has("length"):
		rx.set_meta("length", maxf(0.1, float(params["length"])))
		tamanho.z = rx.get_meta("length")
	rx.mesh.size = tamanho

	if params.has("rotation"):
		rx.set_meta("rotation", params["rotation"])
		rx.rotation_degrees.y = params["rotation"]
	if params.has("posicao"):
		rx.position = params["posicao"]
	elif params.has("pos"):                        # formato antigo de save
		rx.position = params["pos"]
	if params.has("importance"):
		rx.set_meta("importance", params["importance"])

	_atualizar_ris()


func get_rx_info(index: int) -> Dictionary:
	if index < 0 or index >= rx_cache.size():
		return {}
	var rx = rx_cache[index]
	return {
		"nome": rx.name,
		"width": rx.get_meta("width"),
		"length": rx.get_meta("length"),
		"rotation": rx.get_meta("rotation"),
		"importance": rx.get_meta("importance", 1.0),
		"posicao": rx.position,
	}


func index_of(rx: Node) -> int:
	return rx_cache.find(rx)


func nomes() -> PackedStringArray:
	var out := PackedStringArray()
	for rx in rx_cache:
		out.append(rx.name)
	return out


func clear_all() -> void:
	for rx in rx_cache:
		if is_instance_valid(rx):
			rx.queue_free()
	rx_cache.clear()


## Raio/area do RX (m^2), usado nas contas do RIS e do relatorio.
static func area_de(rx: Node) -> float:
	return float(rx.get_meta("width")) * float(rx.get_meta("length"))


func _atualizar_ris() -> void:
	if Manager.ris_handler != null:
		Manager.ris_handler.recalcular_todos()
