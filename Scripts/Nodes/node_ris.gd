# node_ris.gd - handler dos RIS (superficies refletoras inteligentes).
# Sem sinais: a UI chama direto  Manager.ris_handler.add_ris() / update_ris(i, {...}) / ...
#
# Varios RIS sao permitidos e CADA RIS tem o seu RX alvo (meta "alvo" = no do RX).
# O painel e orientado como um espelho: a normal fica na bissetriz entre
#   (RIS->TX de referencia) e (RIS->RX alvo).
# TX de referencia = a antena ligada que mais ilumina o RIS (maior potencia/d^2), preferindo as que estao
# na faixa de frequencia do RIS.
extends Node3D

const RISModel = preload("res://Scripts/Simulator/ris_model.gd")
const MapaRIS = preload("res://Scripts/Simulator/mapa_ris.gd")

var ris_cache: Array = []     # nos RIS, na ordem de criacao
var _contador: int = 0

func _ready():
	Manager.ris_handler = self


## Meta opcional: no Godot, set_meta(k, null) APAGA a chave e get_meta(k, null) da erro - por isso o helper.
func _meta_o_nulo(no: Object, chave: String):
	return no.get_meta(chave) if no.has_meta(chave) else null


# --- CRUD ---

## Cria um RIS. `params` opcional: freq_mhz, ligado, eficiencia, cell_n, cell_m, posicao, alvo (no RX) ou alvo_index.
func add_ris(params: Dictionary = {}) -> Dictionary:
	var novo = Manager.ris_scene.instantiate()
	add_child(novo)
	ris_cache.append(novo)
	_contador += 1
	novo.name = "RIS_%d" % _contador
	novo.add_to_group("reflectors")

	novo.set_meta("freq_mhz", 2400.0)
	novo.set_meta("ligado", false)          # nasce desligado
	novo.set_meta("ganho_fixo", false)
	novo.set_meta("eficiencia", 0.9)
	novo.set_meta("cell_n", 16)
	novo.set_meta("cell_m", 16)
	# ganho: ausente ate haver alvo
	novo.set_meta("area_real", 0.0)
	# alvo: ausente ate ser escolhido

	var pos = Vector3(0, 5.0, 0)
	if Manager.geo != null and Manager.geo.has_method("posicao_padrao_tx") and Manager.importer != null:
		var c: Vector3 = Manager.geo.posicao_padrao_tx()
		pos = Vector3(c.x + 10.0, Manager.importer.terrain_height_at(c.x, c.z) + 5.0, c.z)
	novo.position = pos

	# alvo padrao: primeiro RX existente
	if Manager.rx_handler != null and not Manager.rx_handler.rx_cache.is_empty():
		novo.set_meta("alvo", Manager.rx_handler.rx_cache[0])

	var indice = ris_cache.size() - 1
	update_ris(indice, params)
	return {"index": indice, "name": novo.name, "data": get_ris_info(indice)}


func remove_ris(index: int) -> bool:
	if index < 0 or index >= ris_cache.size():
		return false
	var ris = ris_cache[index]
	ris_cache.remove_at(index)
	remove_child(ris)
	ris.queue_free()
	_atualizar_mapa()
	return true


func clear_all() -> void:
	for ris in ris_cache:
		if is_instance_valid(ris):
			ris.queue_free()
	ris_cache.clear()


## Atualiza parametros. Chaves aceitas: posicao, ligado, freq_mhz, eficiencia, cell_n, cell_m,
## ganho_fixo, ganho (razao area RIS / area RX), alvo (no RX ou null) e alvo_index (indice em rx_cache, -1 = nenhum).
func update_ris(index: int, params: Dictionary) -> void:
	if index < 0 or index >= ris_cache.size():
		return
	var ris: Node3D = ris_cache[index]

	var mudou_n: bool = params.has("cell_n") and int(params["cell_n"]) != int(ris.get_meta("cell_n"))
	var mudou_m: bool = params.has("cell_m") and int(params["cell_m"]) != int(ris.get_meta("cell_m"))

	if params.has("posicao"): ris.position = params["posicao"]
	if params.has("ligado"): ris.set_meta("ligado", bool(params["ligado"]))
	if params.has("freq_mhz"): ris.set_meta("freq_mhz", maxf(1.0, float(params["freq_mhz"])))
	if params.has("eficiencia"): ris.set_meta("eficiencia", clampf(float(params["eficiencia"]), 0.01, 1.0))
	if params.has("modo_feixe"):
		var mf: String = String(params["modo_feixe"])
		ris.set_meta("modo_feixe", mf if mf in ["regiao", "regiao_focada", "fixo"] else "regiao")
	if params.has("ganho_fixo"): ris.set_meta("ganho_fixo", bool(params["ganho_fixo"]))
	if params.has("cell_n"): ris.set_meta("cell_n", maxi(1, int(params["cell_n"])))
	if params.has("cell_m"): ris.set_meta("cell_m", maxi(1, int(params["cell_m"])))

	if params.has("alvo_index"):
		var i: int = int(params["alvo_index"])
		var cache: Array = Manager.rx_handler.rx_cache if Manager.rx_handler != null else []
		ris.set_meta("alvo", cache[i] if i >= 0 and i < cache.size() else null)
	if params.has("alvo"):
		ris.set_meta("alvo", params["alvo"])

	# --- dimensionamento em funcao da area do RX alvo ---
	var rx = alvo_de(ris)
	var lado_celula: float = _lado_celula(ris)
	var area_celula: float = lado_celula * lado_celula
	if rx != null:
		var area_rx: float = maxf(0.01, Manager.rx_handler.area_de(rx))
		if params.has("ganho"):
			var area_alvo: float = area_rx * float(params["ganho"])
			var nm: Array = menor_area_possivel_com_celulas_RIS(area_alvo, area_celula)
			ris.set_meta("cell_n", nm[0])
			ris.set_meta("cell_m", nm[1])
		elif bool(ris.get_meta("ganho_fixo")) and _meta_o_nulo(ris, "ganho") != null:
			var area_alvo2: float = area_rx * float(_meta_o_nulo(ris, "ganho"))
			if mudou_n:
				ris.set_meta("cell_m", maxi(1, ceili(area_alvo2 / (int(ris.get_meta("cell_n")) * area_celula))))
			elif mudou_m:
				ris.set_meta("cell_n", maxi(1, ceili(area_alvo2 / (int(ris.get_meta("cell_m")) * area_celula))))

	recalcular(ris)
	_atualizar_mapa()


## O RIS mudou (ligou/desligou, moveu, trocou de alvo...): recolore o mapa na regiao que ele ilumina.
func _atualizar_mapa() -> void:
	if Manager.engine != null and Manager.engine.has_method("agendar_mapa_ris"):
		Manager.engine.agendar_mapa_ris()


## Reaplica escala, razao de area e orientacao (chamado quando TX/RX/RIS mudam).
func recalcular(ris: Node3D) -> void:
	_aplicar_fisica(ris)
	_alinhar(ris)

func recalcular_todos() -> void:
	for ris in ris_cache:
		recalcular(ris)
	if Manager.ui_ris != null:
		Manager.ui_ris.atualizar_diagnostico()
	_atualizar_mapa()


# --- alvo ---

## No RX alvo do RIS (ou null se nao tem / foi removido).
func alvo_de(ris: Node) -> Node:
	var rx = _meta_o_nulo(ris, "alvo")
	if rx != null and is_instance_valid(rx) and Manager.rx_handler != null and Manager.rx_handler.rx_cache.has(rx):
		return rx
	return null

## RX removido: os RIS que apontavam para ele ficam sem alvo.
func alvo_removido(rx: Node) -> void:
	for ris in ris_cache:
		if _meta_o_nulo(ris, "alvo") == rx:
			ris.set_meta("alvo", null)

## RIS que miram um dado RX.
func ris_do_rx(rx: Node) -> Array:
	var out: Array = []
	for ris in ris_cache:
		if alvo_de(ris) == rx:
			out.append(ris)
	return out


# --- fisica/geometria ---

func _lado_celula(ris: Node) -> float:
	return (300.0 / float(ris.get_meta("freq_mhz"))) / 2.0        # lambda/2

func area_real_de(ris: Node) -> float:
	var l: float = _lado_celula(ris)
	return float(ris.get_meta("cell_n")) * float(ris.get_meta("cell_m")) * l * l

## Largura x altura do painel em metros.
func tamanho_de(ris: Node) -> Vector2:
	var l: float = _lado_celula(ris)
	return Vector2(float(ris.get_meta("cell_n")) * l, float(ris.get_meta("cell_m")) * l)

func _aplicar_fisica(ris: Node3D) -> void:
	var l: float = _lado_celula(ris)
	var area: float = area_real_de(ris)
	ris.set_meta("area_real", area)
	var rx = alvo_de(ris)
	if rx != null:
		ris.set_meta("ganho", area / maxf(0.01, Manager.rx_handler.area_de(rx)))
	else:
		ris.remove_meta("ganho")
	ris.scale = Vector3(float(ris.get_meta("cell_n")) * l, float(ris.get_meta("cell_m")) * l, 0.05)


## Normal do painel (aponta para a frente: -Z local apos o look_at).
func normal_de(ris: Node3D) -> Vector3:
	return (-ris.global_transform.basis.z).normalized()

## Antena de referencia: a que mais ilumina o RIS.
func _tx_referencia(ris: Node3D) -> Dictionary:
	var antenas: Array = _antenas()
	var melhor: Dictionary = {}
	var melhor_score: float = -INF
	var freq: float = float(ris.get_meta("freq_mhz"))
	for a in antenas:
		var d2: float = maxf(1.0, (a.pos as Vector3).distance_squared_to(ris.global_position))
		var score: float = RISModel.dbm_para_w(a.pot) / d2
		if RISModel.freq_compativel(a.freq, freq):
			score *= 1.0e6          # prefere as que estao na faixa do RIS
		if score > melhor_score:
			melhor_score = score
			melhor = a
	return melhor

func _antenas() -> Array:
	if Manager.engine != null and Manager.engine.has_method("_coletar_antenas"):
		return Manager.engine._coletar_antenas()
	return []

func _alinhar(ris: Node3D) -> void:
	var rx = alvo_de(ris)
	if rx == null:
		return
	var tx: Dictionary = _tx_referencia(ris)
	if tx.is_empty():
		return
	var p: Vector3 = ris.global_position
	var v_tx: Vector3 = ((tx.pos as Vector3) - p).normalized()
	var v_rx: Vector3 = ((rx as Node3D).global_position - p).normalized()
	var bis: Vector3 = v_tx + v_rx
	if bis.length() < 0.1:
		return                      # TX e RX em lados opostos: nao ha geometria de reflexao
	bis = bis.normalized()
	var cima: Vector3 = Vector3.UP if absf(bis.dot(Vector3.UP)) < 0.999 else Vector3.FORWARD
	ris.look_at(p + bis, cima)


# --- dimensionamento ---

## Configuracao mais quadrada (NxM) que atinge a area alvo.
func menor_area_possivel_com_celulas_RIS(area_alvo: float, area_celula: float) -> Array:
	var total_celulas: float = ceil(area_alvo / area_celula)
	if total_celulas <= 1:
		return [1, 1]
	var n: int = maxi(1, int(round(sqrt(total_celulas))))
	var m: int = int(ceil(total_celulas / float(n)))
	return [n, m]


# --- informacao para UI / relatorio ---

func get_ris_info(index: int) -> Dictionary:
	if index < 0 or index >= ris_cache.size():
		return {}
	var ris: Node3D = ris_cache[index]
	var ef: float = float(ris.get_meta("eficiencia"))
	var razao = _meta_o_nulo(ris, "ganho")
	var ganho_db = null
	if razao != null and float(razao) * ef > 0.0:
		ganho_db = 10.0 * log(float(razao) * ef) / log(10.0)
	var rx = alvo_de(ris)
	return {
		"nome": ris.name,
		"ligado": bool(ris.get_meta("ligado")),
		"freq_mhz": ris.get_meta("freq_mhz"),
		"ganho_fixo": ris.get_meta("ganho_fixo"),
		"modo_feixe": String(ris.get_meta("modo_feixe", "regiao")),
		"ganho": razao,
		"eficiencia": ef,
		"cell_n": ris.get_meta("cell_n"),
		"cell_m": ris.get_meta("cell_m"),
		"area_real": area_real_de(ris),
		"tamanho_m": tamanho_de(ris),
		"ganho_real_db": ganho_db,
		"posicao": ris.position,
		"rotation": ris.rotation_degrees.y,
		"alvo_index": Manager.rx_handler.index_of(rx) if rx != null else -1,
		"alvo_nome": rx.name if rx != null else "",
	}


# --- calculo do efeito do RIS ---


## Potencia (W) que UM RIS entrega ao ponto `rx_pos`, somando todas as antenas ligadas compativeis.
## Obstaculos nos dois trechos (TX->RIS e RIS->ponto) entram como perda de difracao em gume de faca (nao zeram a potencia).
## Retorna {w, perda_db (maior perda total TX->RIS->ponto), detalhes:[{tx_pos, w, d1, d2, perda_db}], campo_proximo}.
func contribuicao_w(ris: Node3D, rx_pos: Vector3, verificar_los: bool = true) -> Dictionary:
	var total: float = 0.0
	var detalhes: Array = []
	var perto: bool = false
	var perda_max: float = 0.0
	var area: float = area_real_de(ris)
	var ef: float = float(ris.get_meta("eficiencia"))
	var freq: float = float(ris.get_meta("freq_mhz"))
	var lam: float = 300.0 / freq
	var n: Vector3 = normal_de(ris)
	var espaco: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state if (verificar_los and is_inside_tree()) else null
	var excluir: Array[RID] = []
	if espaco != null:
		for r2 in ris_cache:
			for corpo in r2.find_children("*", "CollisionObject3D", true, false):
				excluir.append((corpo as CollisionObject3D).get_rid())
	var regiao_area: float = 0.0
	var rx_alvo = alvo_de(ris)
	if rx_alvo != null and String(ris.get_meta("modo_feixe", "regiao")) == "regiao":
		regiao_area = float(rx_alvo.get_meta("width")) * float(rx_alvo.get_meta("length"))
	for a in _antenas():
		if not RISModel.freq_compativel(a.freq, freq):
			continue
		var r: Dictionary = RISModel.potencia_via_ris(a.pot, a.pos, ris.global_position, n, rx_pos, area, ef, freq)
		var perda: float = 0.0
		if regiao_area > 0.0:
			r.w *= MapaRIS.fator_regiao(area, lam, r.d2, regiao_area)
		if r.w > 0.0 and espaco != null:
			perda = MapaRIS.perda_gume_db(espaco, a.pos, ris.global_position, lam, excluir, 64) \
				+ MapaRIS.perda_gume_db(espaco, ris.global_position, rx_pos, lam, excluir, 40)
			r.w *= pow(10.0, -perda / 10.0)
		total += r.w
		perda_max = maxf(perda_max, perda)
		perto = perto or r.campo_proximo
		detalhes.append({"tx_pos": a.pos, "w": r.w, "d1": r.d1, "d2": r.d2, "perda_db": perda, "cos_i": r.cos_i})
	return {"w": total, "perda_db": perda_max, "detalhes": detalhes, "campo_proximo": perto}


## Angulo de incidencia thetai (graus) e cos^2thetai (dB) do TX dominante (o que mais contribui) em `detalhes`.
## cos^2thetai e o fator da eq. 19 que penaliza a incidencia obliqua: quanto menor thetai, mais eficiente o RIS.
func resumo_incidencia(detalhes: Array) -> Dictionary:
	var melhor: Dictionary = {}
	for d in detalhes:
		if melhor.is_empty() or float(d.w) > float(melhor.w):
			melhor = d
	if melhor.is_empty():
		return {"theta_i_deg": -1.0, "cos2_db": 0.0, "d1": 0.0}
	var c: float = clampf(float(melhor.cos_i), -1.0, 1.0)
	var c2: float = c * c
	return {"theta_i_deg": rad_to_deg(acos(c)), "cos2_db": (10.0 * log(c2) / log(10.0)) if c2 > 1.0e-6 else -60.0, "d1": float(melhor.d1)}


## Texto de diagnostico mostrado no painel do RIS.
func diagnostico(index: int) -> String:
	if index < 0 or index >= ris_cache.size():
		return ""
	var ris: Node3D = ris_cache[index]
	var info: Dictionary = get_ris_info(index)
	var rx = alvo_de(ris)
	var t: String = ""
	if rx == null:
		return "Sem RX alvo.\nEscolha um RX para o RIS atuar."
	var tam: Vector2 = info.tamanho_m
	t += "Alvo: %s\n" % rx.name
	t += "Painel: %.2f × %.2f m (%.2f m²)\n" % [tam.x, tam.y, info.area_real]
	if info.ganho != null:
		t += "Área RIS / RX: %.2f×" % float(info.ganho)
		if info.ganho_real_db != null:
			t += "  (%.1f dB)" % float(info.ganho_real_db)
		t += "\n"
	var c: Dictionary = contribuicao_w(ris, (rx as Node3D).global_position)
	if (c.detalhes as Array).is_empty():
		t += "Nenhuma antena ligada na faixa do RIS (±2 %)."
	else:
		t += "Via RIS no RX: %.1f dBm" % RISModel.w_para_dbm(c.w)
		var k: int = 0
		for d in (c.detalhes as Array):
			k += 1
			if k > 4:
				t += "\n… (+%d TX)" % ((c.detalhes as Array).size() - 4)
				break
			var cd: float = clampf(float(d.cos_i), -1.0, 1.0)
			if cd <= 0.0:
				t += "\nTX %d: atrás do painel (sem efeito)" % k
			else:
				t += "\nTX %d: θi = %.1f°  ·  cos²θi = %.2f (%.1f dB)  ·  d1 = %.0f m" % [k, rad_to_deg(acos(cd)), cd * cd, 10.0 * log(cd * cd) / log(10.0), float(d.d1)]
		if String(ris.get_meta("modo_feixe", "regiao")) == "regiao":
			var area_rx: float = float(rx.get_meta("width")) * float(rx.get_meta("length"))
			var d2c: float = float((c.detalhes as Array)[0].d2)
			var fd: float = MapaRIS.fator_regiao(info.area_real, 300.0 / float(info.freq_mhz), d2c, area_rx)
			t += "\nEnergia espalhada pela área do RX: %.1f dB (RX %.0f m²)" % [10.0 * log(maxf(fd, 1.0e-9)) / log(10.0), area_rx]
		t += "\nPosicione o RIS para reduzir θi (0° = TX de frente ao painel): menos perda em cos²θi."
		if c.get("perda_db", 0.0) > 0.5:
			t += "\nObstáculo no caminho: difração −%.1f dB" % c.perda_db
		if c.campo_proximo:
			t += "\n⚠ campo próximo: estimativa pouco confiável"
	return t
