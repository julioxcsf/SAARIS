extends RefCounted
## Gerador do relatorio de cobertura do SAARIS.
##
## O mapa do relatorio e o ESTADO ATUAL: potencia da GPU + efeito dos RIS ligados (a regiao iluminada pelo RIS
## de cada RX muda de cor) e, ao lado, o mapa SEM RIS. Predios sao desenhados com a pegada real, preenchidos,
## e a cor de potencia so aparece no chao.
##
## Entrada : dicionario de configuracao (ver CONFIG_PADRAO) + estado atual do simulador (Manager.*)
## Saida   : {ok, erro, imagem (Image), dados (Dictionary), secoes (Array), markdown, html, bbcode, csv_rx}
##
## Tudo e calculado a partir do mapa de potencia ja simulado (engine.mapa_calor.power_map_watts):
##  - imagem do mapa na resolucao da simulacao (opcionalmente ampliada) com marcadores TX/RX/RIS e predios;
##  - caracteristicas: area, no de construcoes, relevo, resolucao;
##  - razao de cobertura = % de pixels com potencia >= limiar escolhido pelo operador;
##  - antenas (posicao, ON/OFF, freq, potencia) e observacao de que sao omnidirecionais;
##  - tabela de TODOS os RX: potencia e SNR com os RIS desligados e depois ligados, e a diferenca.

const RISModel = preload("res://Scripts/Simulator/ris_model.gd")
const MapaRIS = preload("res://Scripts/Simulator/mapa_ris.gd")

const CONFIG_PADRAO := {
	"titulo": "Relatório de cobertura SAARIS",
	"limiar_dbm": -95.0,            # razao de cobertura: % do mapa acima deste nivel
	"banda_mhz": 20.0,              # largura de banda do receptor (ruido termico)
	"figura_ruido_db": 7.0,         # figura de ruido do receptor
	"escala_imagem": 1,             # ampliacao inteira da imagem (1x, 2x, 4x...); a imagem nunca passa de LIMITE_IMAGEM_PX
	"cor_tx": Color.YELLOW,                     # antena ligada
	"cor_tx_off": Color(0.55, 0.55, 0.55),      # antena desligada
	"cor_rx": Color(1.0, 0.1, 1.0),             # caixa do RX
	"cor_ris": Color(0.9, 0.2, 0.5),            # RIS ligado
	"cor_ris_off": Color(0.9, 0.2, 0.1),        # RIS desligado
	"cor_predio": Color(0.30, 0.30, 0.34),      # preenchimento dos predios
	"cor_predio_borda": Color(0.05, 0.05, 0.07),# contorno dos predios
	"desenhar_predios": true,
	"desenhar_marcadores": true,
	"ris_desligados_contam": false, # false = estado atual da interface (so RIS ligados); true = conta tambem os desligados
}

const LIMITE_IMAGEM_PX := 4096      # lado maximo da imagem do relatorio, qualquer que seja a resolucao simulada

## Maior ampliacao inteira (1, 2, 4, 8...) que mantem a imagem <= 4096 px; sempre >= 1.
static func escala_maxima(res: Vector2i) -> int:
	var esc: int = 1
	while maxi(res.x, res.y) * esc * 2 <= LIMITE_IMAGEM_PX:
		esc *= 2
	return esc

const NOMES_SHADER := ["FSPL v1", "Reflexão v2", "Permeabilidade v3", "Difração v4", "Relevo v5"]
const LIMIARES_TABELA := [-110.0, -100.0, -95.0, -90.0, -80.0, -70.0, -60.0]

# fonte de pixels 3x5 para numerar os marcadores (digitos 0-9)
const _DIGITOS := {
	"0": ["111", "101", "101", "101", "111"], "1": ["010", "110", "010", "010", "111"],
	"2": ["111", "001", "111", "100", "111"], "3": ["111", "001", "111", "001", "111"],
	"4": ["101", "101", "111", "001", "001"], "5": ["111", "100", "111", "001", "111"],
	"6": ["111", "100", "111", "101", "111"], "7": ["111", "001", "010", "010", "010"],
	"8": ["111", "101", "111", "101", "111"], "9": ["111", "101", "111", "001", "111"],
}

var cfg: Dictionary = {}


func gerar(config: Dictionary) -> Dictionary:
	cfg = CONFIG_PADRAO.duplicate()
	cfg.merge(config, true)

	var eng = Manager.engine
	if eng == null or not eng.tem_resultado():
		return {"ok": false, "erro": "Não há resultado de simulação. Clique em Start e, quando terminar, gere o relatório."}

	var d: Dictionary = {}
	d["agora"] = Time.get_datetime_string_from_system(false, true)
	d["cena"] = Manager.current_scene_name if Manager.current_scene_name != "" else "(cenário atual)"
	d["mapa"] = _info_mapa(eng)
	var com_ris: Dictionary = eng.mapa_com_ris(cfg.ris_desligados_contam)
	d["mapa_on"] = com_ris.mapa
	d["ris_efeito"] = com_ris.por_ris
	d["cobertura"] = _info_cobertura(eng, eng.mapa_calor.power_map_watts)
	d["cobertura_on"] = _info_cobertura(eng, com_ris.mapa)
	d["antenas"] = _info_antenas()
	d["ruido_dbm"] = -174.0 + 10.0 * log(maxf(cfg.banda_mhz, 0.001) * 1.0e6) / log(10.0) + cfg.figura_ruido_db
	d["ris"] = _info_ris()
	d["rx"] = _info_rx(eng, d.ruido_dbm, com_ris.mapa)
	d["modelo"] = _info_modelo(eng)
	d["execucao"] = eng.info_execucao

	var imagem: Image = _desenhar_mapa(eng, d, com_ris.mapa, true)
	d["img_w"] = imagem.get_width()
	d["img_h"] = imagem.get_height()
	var imagem2: Image = _desenhar_mapa(eng, d, eng.mapa_calor.power_map_watts, true)
	var secoes: Array = _montar_secoes(d)

	return {
		"ok": true, "erro": "", "imagem": imagem, "imagem2": imagem2, "dados": d, "secoes": secoes,
		"markdown": _render_md(secoes),
		"html": _render_html(secoes, imagem, imagem2, eng),
		"bbcode": _render_bbcode(secoes),
		"csv_rx": _csv_rx(d),
	}


# --- COLETA ---

func _info_mapa(eng) -> Dictionary:
	var m = eng.mapa_calor
	var tam: Vector2 = m.size
	var res: Vector2i = m.resolution
	var out := {
		"tamanho_m": tam, "area_m2": tam.x * tam.y, "area_km2": tam.x * tam.y / 1.0e6,
		"resolucao": res, "pixel_m": Vector2(tam.x / maxf(1, res.x), tam.y / maxf(1, res.y)),
		"origem": m.map_offset, "construcoes": 0, "area_predios_m2": 0.0, "ocupacao_pct": 0.0,
		"altura_media_m": 0.0, "altura_max_m": 0.0,
		"relevo": false, "relevo_min": 0.0, "relevo_max": 0.0, "latlon_centro": null,
	}
	var obs: Array = Manager.importer.obstaculos_brutos_cache if Manager.importer != null else []
	out.construcoes = obs.size()
	var area: float = 0.0
	var soma_h: float = 0.0
	for o in obs:
		var dh: float = o.bounds_max.y - o.bounds_min.y
		soma_h += dh
		out.altura_max_m = maxf(out.altura_max_m, dh)
	for poly in MapaRIS.poligonos_predios():
		var P: PackedVector2Array = poly
		var a2: float = 0.0
		for k in P.size():
			var q: Vector2 = P[(k + 1) % P.size()]
			a2 += P[k].x * q.y - q.x * P[k].y
		area += absf(a2) * 0.5                   # area real do poligono (formula do cadarco)
	out.area_predios_m2 = area
	out.ocupacao_pct = 100.0 * area / maxf(1.0, out.area_m2)
	out.altura_media_m = soma_h / maxf(1, obs.size())

	if Manager.importer != null and "geo_ativo" in Manager.importer and Manager.importer.geo_ativo:
		var t: Dictionary = Manager.importer.geo_terrain
		if not t.is_empty():
			out.relevo = true
			out.relevo_min = t.hmin
			out.relevo_max = t.hmax
	if Manager.geo != null and Manager.geo.get("frame") != null:
		var c: Vector2 = m.map_offset + tam * 0.5
		out.latlon_centro = Manager.geo.frame.xz_to_latlon(c.x, c.y)
	return out


func _info_cobertura(eng, mapa: PackedFloat32Array) -> Dictionary:
	var est: Dictionary = eng.estatisticas_mapa(cfg.limiar_dbm, mapa, true)       # so pixels de chao
	var w: PackedFloat32Array = PackedFloat32Array()
	var mk: PackedByteArray = eng.mascara_predios()
	for i in mapa.size():
		if mk[i] == 0:
			w.append(mapa[i])
	w.sort()
	var n: int = w.size()
	var tabela: Array = []
	var lista: Array = LIMIARES_TABELA.duplicate()
	if not lista.has(cfg.limiar_dbm):
		lista.append(cfg.limiar_dbm)
		lista.sort()
	for lim in lista:
		var lw: float = RISModel.dbm_para_w(lim)
		tabela.append({"limiar": lim, "pct": 100.0 * float(n - w.bsearch(lw)) / float(maxi(1, n))})
	est["tabela"] = tabela
	return est


func _info_antenas() -> Array:
	var out: Array = []
	if Manager.tx_handler != null:
		for tx in Manager.tx_handler.tx_cache:
			out.append(_linha_antena(tx.name, tx.global_position, bool(tx.ligado), tx.freq_mhz, tx.potencia_dbm, "manual"))
	if Manager.geo != null and Manager.geo.has_method("antenas_para_simulacao"):
		var i: int = 0
		for a in Manager.geo.antenas_para_simulacao():
			i += 1
			out.append(_linha_antena("Real_%d" % i, a.pos, true, a.freq, a.pot, "Anatel/OSM"))
	return out

func _linha_antena(nome: String, pos: Vector3, ligado: bool, freq: float, pot: float, origem: String) -> Dictionary:
	var ll = null
	if Manager.geo != null and Manager.geo.get("frame") != null:
		ll = Manager.geo.frame.xz_to_latlon(pos.x, pos.z)
	return {"nome": nome, "pos": pos, "latlon": ll, "ligado": ligado, "freq": freq,
		"pot_dbm": pot, "pot_w": RISModel.dbm_para_w(pot), "origem": origem}


func _info_ris() -> Array:
	var out: Array = []
	var h = Manager.ris_handler
	if h == null:
		return out
	for i in h.ris_cache.size():
		var info: Dictionary = h.get_ris_info(i)
		var ris: Node3D = h.ris_cache[i]
		var rx = h.alvo_de(ris)
		var calc := {"w": 0.0, "campo_proximo": false, "detalhes": []}
		if rx != null:
			calc = h.contribuicao_w(ris, (rx as Node3D).global_position)
		info["pos_global"] = ris.global_position
		info["via_ris_w"] = calc.w
		info["via_ris_dbm"] = RISModel.w_para_dbm(calc.w)
		info["campo_proximo"] = calc.campo_proximo
		info["bloqueado"] = false
		info["perda_difracao_db"] = calc.get("perda_db", 0.0)
		info["sem_tx_na_faixa"] = (calc.detalhes as Array).is_empty()
		var inc: Dictionary = h.resumo_incidencia(calc.detalhes)
		info["theta_i_deg"] = inc.theta_i_deg
		info["cos2_db"] = inc.cos2_db
		out.append(info)
	return out


func _info_rx(eng, ruido_dbm: float, d_on: PackedFloat32Array) -> Array:
	var out: Array = []
	var h = Manager.rx_handler
	if h == null:
		return out
	for i in h.rx_cache.size():
		var rx: Node3D = h.rx_cache[i]
		var w: float = float(rx.get_meta("width"))
		var l: float = float(rx.get_meta("length"))
		var rot: float = float(rx.get_meta("rotation"))
		var reg: Dictionary = eng.potencia_na_regiao(rx.global_position, w, l, rot)
		var reg_on: Dictionary = eng.potencia_na_regiao(rx.global_position, w, l, rot, d_on)
		var p_off_w: float = RISModel.dbm_para_w(reg.dbm) if reg.dbm > -200.0 else 0.0

		var ris_do_rx: Array = Manager.ris_handler.ris_do_rx(rx) if Manager.ris_handler != null else []
		var nomes: PackedStringArray = PackedStringArray()
		var usados: int = 0
		for ris in ris_do_rx:
			var liga: bool = bool(ris.get_meta("ligado"))
			nomes.append("%s%s" % [ris.name, "" if liga else " (desl.)"])
			if liga or cfg.ris_desligados_contam:
				usados += 1
		var p_on_w: float = RISModel.dbm_para_w(reg_on.dbm) if reg_on.dbm > -200.0 else 0.0
		var p_ris_w: float = maxf(0.0, p_on_w - p_off_w)
		var p_off: float = RISModel.w_para_dbm(p_off_w)
		var p_on: float = RISModel.w_para_dbm(p_on_w)
		out.append({
			"nome": rx.name, "pos": rx.global_position, "largura": w, "comprimento": l, "area": w * l,
			"rotacao": rot, "importancia": rx.get_meta("importance", 1.0),
			"pixels": reg.pixels, "fora_do_mapa": reg.fora_do_mapa,
			"ris": nomes, "ris_usados": usados,
			"p_off_dbm": p_off, "snr_off_db": p_off - ruido_dbm,
			"p_on_dbm": p_on, "snr_on_db": p_on - ruido_dbm,
			"dp_db": (p_on - p_off) if p_off_w > 0.0 else (INF if p_on_w > 0.0 else 0.0),
			"p_ris_dbm": RISModel.w_para_dbm(p_ris_w),
		})
	return out


func _info_modelo(eng) -> Dictionary:
	var c = eng.sim_config
	var idx: int = int(eng._shader_ativo)
	return {
		"shader": NOMES_SHADER[idx] if idx >= 0 and idx < NOMES_SHADER.size() else str(idx),
		"los": c.los_ativado, "reflexao": c.reflection_ativado, "difracao": c.diffraction_ativado,
		"max_reflexoes": c.max_reflections, "perda_reflexao_db": c.reflection_loss_db,
		"expoente": c.path_loss_exponent, "altura_rx_relevo": c.altura_rx_relevo_m,
		"escala_dbm": [c.min_sinal_dbm, c.critical_sinal_dbm, c.max_sinal_dbm],
	}


# --- IMAGEM ---

## Cor do mapa de calor - mesma formula do shader do chao (azul->verde->vermelho com smoothstep).
func _cor_mapa(dbm: float, mn: float, cr: float, mx: float, c_min: Color, c_cr: Color, c_max: Color) -> Color:
	var inf: float = smoothstep(mn, cr, dbm)
	var sup: float = smoothstep(cr, mx, dbm)
	var lower: Color = c_min.lerp(c_cr, inf)
	var upper: Color = c_cr.lerp(c_max, sup)
	return upper if dbm >= cr else lower


func _desenhar_mapa(eng, d: Dictionary, w: PackedFloat32Array, marcadores: bool = true) -> Image:
	var res: Vector2i = eng.mapa_calor.resolution
	var c = eng.sim_config
	var mn: float = c.min_sinal_dbm
	var cr: float = c.critical_sinal_dbm
	var mx: float = c.max_sinal_dbm
	if mx <= mn:
		mx = mn + 1.0

	# tabela de cores (LUT) para nao calcular smoothstep por pixel
	const N := 1024
	var lut := PackedByteArray()
	lut.resize(N * 3)
	for k in N:
		var dbm: float = mn + (mx - mn) * float(k) / float(N - 1)
		var col: Color = _cor_mapa(dbm, mn, cr, mx, eng.min_sinal_color, eng.critical_sinal_color, eng.max_sinal_color)
		lut[k * 3] = int(col.r * 255.0)
		lut[k * 3 + 1] = int(col.g * 255.0)
		lut[k * 3 + 2] = int(col.b * 255.0)

	var bytes := PackedByteArray()
	bytes.resize(res.x * res.y * 3)
	var inv_log10: float = 1.0 / log(10.0)
	var escala: float = float(N - 1) / (mx - mn)
	for i in w.size():
		var watts: float = w[i]
		var dbm2: float = -200.0 if watts <= 0.0 else 10.0 * log(watts) * inv_log10 + 30.0
		var k2: int = clampi(int((dbm2 - mn) * escala), 0, N - 1)
		bytes[i * 3] = lut[k2 * 3]
		bytes[i * 3 + 1] = lut[k2 * 3 + 1]
		bytes[i * 3 + 2] = lut[k2 * 3 + 2]
	var img: Image = Image.create_from_data(res.x, res.y, false, Image.FORMAT_RGB8, bytes)

	var esc: int = clampi(int(cfg.escala_imagem), 1, escala_maxima(res))      # nunca passa de 4096 px
	cfg.escala_imagem = esc
	if maxi(img.get_width(), img.get_height()) > LIMITE_IMAGEM_PX:            # simulacao > 4096: reduz para caber
		var f: float = float(LIMITE_IMAGEM_PX) / float(maxi(img.get_width(), img.get_height()))
		img.resize(maxi(1, int(img.get_width() * f)), maxi(1, int(img.get_height() * f)), Image.INTERPOLATE_NEAREST)
	elif esc > 1:
		img.resize(res.x * esc, res.y * esc, Image.INTERPOLATE_NEAREST)

	var tam: Vector2 = d.mapa.tamanho_m
	var off: Vector2 = d.mapa.origem
	var sx: float = float(img.get_width()) / tam.x
	var sz: float = float(img.get_height()) / tam.y
	var a2p = func(x: float, z: float) -> Vector2i:
		return Vector2i(int((x - off.x) * sx), int((z - off.y) * sz))

	# predios: pegada real (vertices do topo), preenchida; a cor de potencia so fica no chao
	if cfg.desenhar_predios and Manager.importer != null:
		_pintar_predios(img, tam, off)

	if cfg.desenhar_marcadores and marcadores:
		# tamanho dos marcadores acompanha a imagem (legivel mesmo em 1024+ px)
		var ref: int = maxi(esc, int(round(float(img.get_width()) / 350.0)))
		var tam_m: int = maxi(6, 3 * ref)
		var i: int = 0
		for a in d.antenas:
			i += 1
			var p: Vector2i = a2p.call(a.pos.x, a.pos.z)
			var cor_tx: Color = cfg.cor_tx if a.ligado else cfg.cor_tx_off
			img.fill_rect(Rect2i(p - Vector2i(tam_m / 2 + 1, tam_m / 2 + 1), Vector2i(tam_m + 2, tam_m + 2)), Color.BLACK)
			img.fill_rect(Rect2i(p - Vector2i(tam_m / 2, tam_m / 2), Vector2i(tam_m, tam_m)), cor_tx)
			_numero(img, i, p + Vector2i(tam_m, -tam_m), Color.WHITE, ref)
		var j: int = 0
		for r in d.rx:
			j += 1
			var meio_x: float = (absf(r.largura * cos(deg_to_rad(r.rotacao))) + absf(r.comprimento * sin(deg_to_rad(r.rotacao)))) * 0.5
			var meio_z: float = (absf(r.largura * sin(deg_to_rad(r.rotacao))) + absf(r.comprimento * cos(deg_to_rad(r.rotacao)))) * 0.5
			var q0: Vector2i = a2p.call(r.pos.x - meio_x, r.pos.z - meio_z)
			var q1: Vector2i = a2p.call(r.pos.x + meio_x, r.pos.z + meio_z)
			var caixa := Rect2i(q0, q1 - q0).grow(maxi(2, ref))
			_retangulo(img, caixa, cfg.cor_rx, ref)
			_numero(img, j, caixa.position + Vector2i(caixa.size.x + 2, -4 * ref), cfg.cor_rx, ref)
		var k3: int = 0
		for q in d.ris:
			k3 += 1
			var pr: Vector2i = a2p.call(q.pos_global.x, q.pos_global.z)
			var cor_r: Color = cfg.cor_ris if q.ligado else cfg.cor_ris_off
			var s: int = maxi(5, 2 * ref + 3)
			img.fill_rect(Rect2i(pr - Vector2i(s / 2 + 1, s / 2 + 1), Vector2i(s + 2, s + 2)), Color.BLACK)
			img.fill_rect(Rect2i(pr - Vector2i(s / 2, s / 2), Vector2i(s, s)), cor_r)
			_numero(img, k3, pr + Vector2i(s, s / 2), cor_r, ref)
	return img


## Preenche cada predio com o poligono real (varredura por linhas, spans via fill_rect) e traca o contorno.
func _pintar_predios(img: Image, tam: Vector2, off: Vector2) -> void:
	var W: int = img.get_width()
	var H: int = img.get_height()
	var sx: float = float(W) / tam.x
	var sy: float = float(H) / tam.y
	var cor_fill: Color = cfg.cor_predio
	var cor_borda: Color = cfg.cor_predio_borda
	for poly in MapaRIS.poligonos_predios():
		var P: PackedVector2Array = poly
		var n: int = P.size()
		var f := PackedVector2Array()
		f.resize(n)
		var y_min: float = INF
		var y_max: float = -INF
		for k in n:
			f[k] = Vector2((P[k].x - off.x) * sx, (P[k].y - off.y) * sy)
			y_min = minf(y_min, f[k].y)
			y_max = maxf(y_max, f[k].y)
		for y in range(maxi(0, ceili(y_min - 0.5)), mini(H - 1, floori(y_max - 0.5)) + 1):
			var yc: float = y + 0.5
			var xs: Array = []
			for k in n:
				var a: Vector2 = f[k]
				var b: Vector2 = f[(k + 1) % n]
				if (a.y <= yc and b.y > yc) or (b.y <= yc and a.y > yc):
					xs.append(a.x + (yc - a.y) / (b.y - a.y) * (b.x - a.x))
			xs.sort()
			for k in range(0, xs.size() - 1, 2):
				var x0: int = maxi(0, ceili(xs[k] - 0.5))
				var x1: int = mini(W - 1, floori(xs[k + 1] - 0.5))
				if x1 >= x0:
					img.fill_rect(Rect2i(x0, y, x1 - x0 + 1, 1), cor_fill)
		for k in n:
			_linha_px(img, f[k], f[(k + 1) % n], cor_borda)


func _linha_px(img: Image, a: Vector2, b: Vector2, cor: Color) -> void:
	var W: int = img.get_width()
	var H: int = img.get_height()
	var passos: int = int(maxf(absf(b.x - a.x), absf(b.y - a.y))) + 1
	for t in range(passos + 1):
		var p: Vector2 = a.lerp(b, float(t) / float(passos))
		var x: int = int(p.x)
		var y: int = int(p.y)
		if x >= 0 and y >= 0 and x < W and y < H:
			img.set_pixel(x, y, cor)


func _retangulo(img: Image, r: Rect2i, cor: Color, esp: int) -> void:
	var W: int = img.get_width()
	var H: int = img.get_height()
	var r2: Rect2i = r.abs()
	if r2.end.x < 0 or r2.end.y < 0 or r2.position.x >= W or r2.position.y >= H:
		return
	for lado in [
		Rect2i(r2.position, Vector2i(r2.size.x + esp, esp)),
		Rect2i(Vector2i(r2.position.x, r2.end.y), Vector2i(r2.size.x + esp, esp)),
		Rect2i(r2.position, Vector2i(esp, r2.size.y + esp)),
		Rect2i(Vector2i(r2.end.x, r2.position.y), Vector2i(esp, r2.size.y + esp)),
	]:
		var ri: Rect2i = (lado as Rect2i).intersection(Rect2i(0, 0, W, H))
		if ri.size.x > 0 and ri.size.y > 0:
			img.fill_rect(ri, cor)


func _numero(img: Image, n: int, pos: Vector2i, cor: Color, esc: int) -> void:
	var W: int = img.get_width()
	var H: int = img.get_height()
	var x0: int = pos.x
	for ch in str(n):
		var glifo: Array = _DIGITOS[ch]
		for ly in 5:
			for lx in 3:
				if glifo[ly][lx] == "1":
					var r := Rect2i(x0 + lx * esc, pos.y + ly * esc, esc, esc).intersection(Rect2i(0, 0, W, H))
					if r.size.x > 0 and r.size.y > 0:
						img.fill_rect(r, cor)
		x0 += 4 * esc


# --- SECOES (formato neutro) ---
# cada secao: {titulo, itens:[ {tipo:"p"|"lista"|"tabela"|"imagem", ...} ]}

func _f(v: float, casas: int = 1) -> String:
	if is_inf(v):
		return "+∞"
	if is_nan(v):
		return "—"
	return ("%." + str(casas) + "f") % v

func _dbm(v: float) -> String:
	return "—" if v <= -199.0 else _f(v, 1) + " dBm"

func _montar_secoes(d: Dictionary) -> Array:
	var m: Dictionary = d.mapa
	var cob: Dictionary = d.cobertura
	var mod: Dictionary = d.modelo
	var S: Array = []

	# --- 1. Resumo
	var linhas_resumo: Array = [
		["Cenário", d.cena],
		["Gerado em", d.agora],
		["Modelo de propagação", "Shader %s — LOS %s, reflexão %s, difração %s" % [mod.shader, _onoff(mod.los), _onoff(mod.reflexao), _onoff(mod.difracao)]],
		["GPU", "%s" % _exec(d, "gpu", "indisponivel")],
		["CPU", "%s (%s threads)" % [_exec(d, "cpu", "indisponivel"), _exec(d, "cpu_threads", "?")]],
		["Tempo de simulação", _texto_tempos(d)],
		["Antenas", "%d (%d ligadas)" % [d.antenas.size(), d.antenas.filter(func(a): return a.ligado).size()]],
		["RX / RIS", "%d RX, %d RIS" % [d.rx.size(), d.ris.size()]],
	]
	S.append({"titulo": cfg.titulo, "itens": [{"tipo": "tabela", "cab": ["Item", "Valor"], "linhas": linhas_resumo}]})

	# --- 2. Mapa
	var itens_mapa: Array = [{"tipo": "imagem", "qual": 1,
		"legenda": "Estado atual do mapa%s." % (" (RIS ligados somados; a região iluminada de cada RIS aparece recolorida)" if d.ris.size() > 0 else "")}]
	var linhas_mapa: Array = [
		["Dimensões", "%s × %s m" % [_f(m.tamanho_m.x, 1), _f(m.tamanho_m.y, 1)]],
		["Área do local", "%s m²  (%s km²)" % [_f(m.area_m2, 0), _f(m.area_km2, 3)]],
		["Resolução da simulação", "%d × %d pixels" % [m.resolucao.x, m.resolucao.y]],
		["Tamanho do pixel", "%s × %s m" % [_f(m.pixel_m.x, 2), _f(m.pixel_m.y, 2)]],
		["Imagem do relatório", "%d × %d pixels (%s)" % [d.img_w, d.img_h, ("%d×" % cfg.escala_imagem) if d.img_w >= m.resolucao.x else ("reduzida ao limite de %d px" % LIMITE_IMAGEM_PX)]],
		["Construções", "%d" % m.construcoes],
		["Ocupação por construções", "%s %% da área (pegada real dos prédios)" % _f(m.ocupacao_pct, 1)],
		["Altura das construções", "média %s m, máxima %s m" % [_f(m.altura_media_m, 1), _f(m.altura_max_m, 1)]],
		["Relevo", ("ativo: %s a %s m (relativo)" % [_f(m.relevo_min, 1), _f(m.relevo_max, 1)]) if m.relevo else "terreno plano"],
	]
	if m.latlon_centro != null:
		linhas_mapa.append(["Centro do mapa", "%s, %s (lat, lon)" % [_f(m.latlon_centro.x, 5), _f(m.latlon_centro.y, 5)]])
	itens_mapa.append({"tipo": "tabela", "cab": ["Característica", "Valor"], "linhas": linhas_mapa})
	S.append({"titulo": "Mapa de potência e características do local", "itens": itens_mapa})

	# --- 3. Cobertura (so pixels de chao; predios ficam de fora)
	var cob_on: Dictionary = d.cobertura_on
	var linhas_cob: Array = []
	for t_i in cob.tabela.size():
		var t: Dictionary = cob.tabela[t_i]
		var marca: String = "  ◄ limiar do relatório" if is_equal_approx(t.limiar, cfg.limiar_dbm) else ""
		linhas_cob.append(["≥ %s dBm" % _f(t.limiar, 0), "%s %%" % _f(t.pct, 2), "%s %%%s" % [_f(cob_on.tabela[t_i].pct, 2), marca]])
	S.append({"titulo": "Razão de cobertura", "itens": [
		{"tipo": "p", "texto": "Limiar definido pelo operador: **%s dBm**. Razão de cobertura (somente pixels de chão) = **%s %%** sem RIS e **%s %%** no estado atual (%d de %d pixels de chão)."
			% [_f(cfg.limiar_dbm, 1), _f(cob.cobertura_pct, 2), _f(cob_on.cobertura_pct, 2), cob_on.acima, cob_on.pixels]},
		{"tipo": "p", "texto": "Potência no mapa atual: mínima %s, média %s, máxima %s." % [_dbm(cob_on.min_dbm), _dbm(cob_on.media_dbm), _dbm(cob_on.max_dbm)]},
		{"tipo": "tabela", "cab": ["Nível", "% do chão acima (sem RIS)", "% do chão acima (estado atual)"], "linhas": linhas_cob},
	]})

	# --- 3b. Efeito dos RIS na iluminacao
	if d.ris.size() > 0:
		var linhas_ef: Array = []
		for e in d.ris_efeito:
			linhas_ef.append([e.nome, ("ON" if e.ligado else "OFF") + ("" if e.contado else " (não contado)"),
				e.alvo if e.alvo != "" else "—",
				"%d px" % e.pixels, "%s m²" % _f(e.area_m2, 0), "%s %%" % _f(e.pct, 2),
				_dbm(e.pico_dbm) if e.contado and e.pixels > 0 else "—"])
		S.append({"titulo": "Efeito dos RIS na iluminação", "itens": [
			{"tipo": "imagem", "qual": 2, "legenda": "Mesmo mapa SEM RIS, para comparação."},
			{"tipo": "p", "texto": "Cada RIS ligado ilumina a região do seu RX alvo (eq. 19 do artigo; modo “feixe fixo” opcional). “Região iluminada” = pixels de chão onde o RIS soma ≥ 3 dB sobre o mapa sem RIS. Cobertura: **%s %% → %s %%** (Δ = %s p.p.)."
				% [_f(cob.cobertura_pct, 2), _f(cob_on.cobertura_pct, 2), _f(cob_on.cobertura_pct - cob.cobertura_pct, 2)]},
			{"tipo": "tabela", "cab": ["RIS", "Status", "RX alvo", "Pixels iluminados", "Área iluminada", "% do mapa", "Pico via RIS"], "linhas": linhas_ef},
		]})

	# --- 4. Antenas
	var linhas_ant: Array = []
	var i: int = 0
	for a in d.antenas:
		i += 1
		var pos_txt: String = "(%s, %s, %s)" % [_f(a.pos.x, 1), _f(a.pos.y, 1), _f(a.pos.z, 1)]
		if a.latlon != null:
			pos_txt += "  [%s, %s]" % [_f(a.latlon.x, 5), _f(a.latlon.y, 5)]
		linhas_ant.append([str(i), a.nome, a.origem, pos_txt, "ON" if a.ligado else "OFF",
			"%s MHz" % _f(a.freq, 0), "%s dBm (%s W)" % [_f(a.pot_dbm, 1), _f(a.pot_w, 2)]])
	var itens_ant: Array = []
	if linhas_ant.is_empty():
		itens_ant.append({"tipo": "p", "texto": "Nenhuma antena no cenário."})
	else:
		itens_ant.append({"tipo": "tabela", "cab": ["#", "Antena", "Origem", "Posição x, y, z (m)", "Status", "Frequência", "Potência"], "linhas": linhas_ant})
	itens_ant.append({"tipo": "p", "texto": "**Todas as antenas são omnidirecionais** (diagrama isotrópico no plano horizontal, sem azimute nem inclinação); a potência informada é a EIRP."})
	S.append({"titulo": "Antenas transmissoras", "itens": itens_ant})

	# --- 5. RX
	var linhas_rx: Array = []
	var j: int = 0
	for r in d.rx:
		j += 1
		var dp: String = "—" if r.ris_usados == 0 else ("+∞ dB" if is_inf(r.dp_db) else "%s%s dB" % ["+" if r.dp_db >= 0.0 else "", _f(r.dp_db, 2)])
		var dsnr: String = "—" if r.ris_usados == 0 else ("+∞ dB" if is_inf(r.dp_db) else "%s%s dB" % ["+" if r.dp_db >= 0.0 else "", _f(r.snr_on_db - r.snr_off_db, 2)])
		linhas_rx.append([str(j), r.nome,
			"(%s, %s, %s)" % [_f(r.pos.x, 1), _f(r.pos.y, 1), _f(r.pos.z, 1)],
			"%s × %s m" % [_f(r.largura, 1), _f(r.comprimento, 1)],
			", ".join(r.ris) if not r.ris.is_empty() else "—",
			_dbm(r.p_off_dbm), _f(r.snr_off_db, 1) + " dB" if r.p_off_dbm > -199.0 else "—",
			_dbm(r.p_on_dbm) if r.ris_usados > 0 else "—", (_f(r.snr_on_db, 1) + " dB") if r.ris_usados > 0 and r.p_on_dbm > -199.0 else "—",
			dp, dsnr])
	var itens_rx: Array = []
	if linhas_rx.is_empty():
		itens_rx.append({"tipo": "p", "texto": "Nenhum RX definido. Adicione RX em “Gerenciar RX” para ver potência e SNR por região de interesse."})
	else:
		itens_rx.append({"tipo": "p", "texto": "Cada RX é uma região de cobertura de interesse. Potência = média (em Watts) dos pixels dentro da região; SNR = potência − ruído (%s dBm; B = %s MHz, NF = %s dB)."
			% [_f(d.ruido_dbm, 1), _f(cfg.banda_mhz, 1), _f(cfg.figura_ruido_db, 1)]})
		itens_rx.append({"tipo": "tabela",
			"cab": ["#", "RX", "Posição (m)", "Tamanho", "RIS alvo", "P (RIS off)", "SNR (RIS off)", "P (RIS on)", "SNR (RIS on)", "ΔP", "ΔSNR"],
			"linhas": linhas_rx})
	S.append({"titulo": "Regiões de interesse (RX): RIS desligado × ligado", "itens": itens_rx})

	# --- 6. RIS
	var linhas_ris: Array = []
	var k: int = 0
	for q in d.ris:
		k += 1
		var aviso: Array = []
		if q.alvo_nome == "": aviso.append("sem alvo")
		if q.sem_tx_na_faixa and q.alvo_nome != "": aviso.append("nenhum TX na faixa do RIS")
		if q.perda_difracao_db > 0.5: aviso.append("difração em gume de faca: −%s dB nos trechos TX→RIS→RX" % _f(q.perda_difracao_db, 1))
		if q.campo_proximo: aviso.append("campo próximo")
		linhas_ris.append([str(k), q.nome, "ON" if q.ligado else "OFF",
			"(%s, %s, %s)" % [_f(q.pos_global.x, 1), _f(q.pos_global.y, 1), _f(q.pos_global.z, 1)],
			"%d × %d" % [q.cell_n, q.cell_m], "%s × %s m (%s m²)" % [_f(q.tamanho_m.x, 2), _f(q.tamanho_m.y, 2), _f(q.area_real, 2)],
			"%s MHz" % _f(q.freq_mhz, 0), q.alvo_nome if q.alvo_nome != "" else "—",
			("%s° (%s dB)" % [_f(q.theta_i_deg, 1), _f(q.cos2_db, 1)]) if q.theta_i_deg >= 0.0 else "—",
			_dbm(q.via_ris_dbm) if q.via_ris_w > 0.0 else "—", "; ".join(aviso) if not aviso.is_empty() else "ok"])
	var itens_ris: Array = []
	if linhas_ris.is_empty():
		itens_ris.append({"tipo": "p", "texto": "Nenhum RIS no cenário."})
	else:
		itens_ris.append({"tipo": "tabela", "cab": ["#", "RIS", "Status", "Posição (m)", "Células N×M", "Painel", "Freq.", "RX alvo", "θi (cos²θi)", "Potência só via RIS no alvo", "Avisos"], "linhas": linhas_ris})
	S.append({"titulo": "Superfícies refletoras inteligentes (RIS)", "itens": itens_ris})

	# --- 7. Observacoes
	var obs: Array = [
		"Todas as antenas são omnidirecionais; antenas desligadas (OFF) não contribuem para o mapa.",
		"O mapa de potência soma, em Watts, a contribuição de todas as antenas ligadas (shader %s: LOS, reflexão, difração, penetração%s)." % [mod.shader, " e relevo" if m.relevo else ""],
		"A razão de cobertura e as estatísticas consideram só pixels de chão; os prédios são desenhados com a pegada real e preenchidos, sem cor de potência.",
		"Ruído térmico: N = −174 dBm/Hz + 10·log10(B) + NF = %s dBm (B = %s MHz, NF = %s dB)." % [_f(d.ruido_dbm, 1), _f(cfg.banda_mhz, 1), _f(cfg.figura_ruido_db, 1)],
		"Efeito do RIS (artigo Özdogan–Björnson–Larsson, arXiv 1911.03359): o motor GPU não modela RIS; a contribuição é calculada na CPU por Pr = Pt·Gt·Gr·η·(A/(4π·d1·d2))²·cos²θi (eq. 19; A = área do painel, d1 = TX→RIS, d2 = RIS→ponto; TX e receptor isotrópicos) e SOMADA à potência do mapa (soma incoerente). Modos por RIS: “região do RX, energia espalhada” (padrão) divide a energia focalizada pela área do RX (mancha ≈ (λ·d2)²/A dividida pela área do RX, no máximo 1), mostrando o efeito médio na região; “região do RX, energia concentrada” aplica a TODO ponto da região a potência do lóbulo principal (eq. 19 no centro do RX, o máximo que o painel entrega); nenhum ponto recebe mais que isso (só obstáculos RIS→ponto o reduzem). Nos dois modos de região, um ponto nunca passa do pico do lóbulo. No modo “feixe fixo” há um único lóbulo apontado ao centro do RX, com o fator sinc² da eq. 15. Só entram TX na faixa de ±2 % da frequência do RIS e obstáculos nos trechos TX→RIS e RIS→ponto entram como perda de difração em gume de faca (aproximação de Lee, 1ª zona de Fresnel; só no plano vertical). Regime de campo distante; “campo próximo” é só alerta.",
		"Mapa do relatório: %s." % ("RIS ligados e desligados contam como ligados" if cfg.ris_desligados_contam else "estado atual da interface (somente RIS ligados)"),
		"“Campo próximo” indica distância menor que 2·D²/λ: a estimativa do RIS é menos confiável.",
		"θi = ângulo entre a normal do painel e a direção do TX dominante; cos²θi (em dB) é a perda da eq. 19 por incidência oblíqua. Quanto menor θi, mais eficiente o RIS: posicione-o para reduzir θi.",
	]
	if m.relevo:
		obs.append("Receptores do mapa a %s m acima do terreno (modelo de relevo)." % _f(mod.altura_rx_relevo, 2))
	S.append({"titulo": "Observações", "itens": [{"tipo": "lista", "linhas": obs}]})
	return S


func _exec(d: Dictionary, chave: String, padrao: String) -> String:
	var e: Dictionary = d.get("execucao", {})
	var v = e.get(chave, "")
	return str(v) if str(v) != "" else padrao


func _texto_tempos(d: Dictionary) -> String:
	var e: Dictionary = d.get("execucao", {})
	if e.is_empty() or not e.has("tempo_gpu_ms"):
		return "simule o mapa antes de gerar o relatório"
	var t: String = "GPU %s ms em %d despachos (maior %s ms)" % [_f(e.tempo_gpu_ms, 0), int(e.get("despachos", 1)), _f(e.get("maior_despacho_ms", 0.0), 0)]
	if e.has("tempo_total_ms"):
		t += "; total com preparo e leitura %s ms" % _f(e.tempo_total_ms, 0)
	return t


func _onoff(v: bool) -> String:
	return "on" if v else "off"


# --- RENDER: Markdown / HTML / BBCode ---

func _render_md(secoes: Array) -> String:
	var t: String = ""
	for s_i in secoes.size():
		var s: Dictionary = secoes[s_i]
		t += ("# " if s_i == 0 else "## ") + s.titulo + "\n\n"
		for it in s.itens:
			match it.tipo:
				"p": t += it.texto + "\n\n"
				"imagem": t += "![%s](%s)\n\n_%s_ Marcadores: TX %s (desligada %s), RX %s, RIS %s (desligado %s), prédios %s.\n\n" % ["Mapa de potência", "mapa.png" if it.qual == 1 else "mapa_sem_ris.png", it.legenda, _hex(cfg.cor_tx), _hex(cfg.cor_tx_off), _hex(cfg.cor_rx), _hex(cfg.cor_ris), _hex(cfg.cor_ris_off), _hex(cfg.cor_predio)]
				"lista":
					for l in it.linhas: t += "- " + l + "\n"
					t += "\n"
				"tabela":
					t += "| " + " | ".join(it.cab) + " |\n|" + "---|".repeat(it.cab.size()) + "\n"
					for l in it.linhas: t += "| " + " | ".join(PackedStringArray(l.map(func(c): return str(c).replace("|", "/")))) + " |\n"
					t += "\n"
	return t


func _hex(c: Color) -> String:
	return "#" + c.to_html(false)

## Legenda dos marcadores com as MESMAS cores configuradas para o desenho.
func _legenda_html() -> String:
	return "<p class='mk'>" \
		+ "<span><b style='color:%s'>■</b> TX ligada (nº = linha da tabela)</span>" % _hex(cfg.cor_tx) \
		+ "<span><b style='color:%s'>■</b> TX desligada</span>" % _hex(cfg.cor_tx_off) \
		+ "<span><b style='color:%s'>▭</b> RX (região de interesse)</span>" % _hex(cfg.cor_rx) \
		+ "<span><b style='color:%s'>■</b> RIS ligado</span>" % _hex(cfg.cor_ris) \
		+ "<span><b style='color:%s'>■</b> RIS desligado</span>" % _hex(cfg.cor_ris_off) \
		+ "<span><b style='color:%s;background:%s;padding:0 3px'>■</b> prédios</span></p>" % [_hex(cfg.cor_predio), _hex(cfg.cor_predio_borda)]

func _legenda_bbcode() -> String:
	return "[color=%s]■[/color] TX ligada   [color=%s]■[/color] TX desligada   [color=%s]▭[/color] RX   [color=%s]■[/color] RIS ligado   [color=%s]■[/color] RIS desligado   [color=%s]■[/color] prédios\n" % [
		_hex(cfg.cor_tx), _hex(cfg.cor_tx_off), _hex(cfg.cor_rx), _hex(cfg.cor_ris), _hex(cfg.cor_ris_off), _hex(cfg.cor_predio)]

func _html_inline(txt: String) -> String:
	var s: String = txt.xml_escape()
	var partes: PackedStringArray = s.split("**")
	var out: String = ""
	for i in partes.size():
		out += ("<b>" + partes[i] + "</b>") if i % 2 == 1 else partes[i]
	return out


func _render_html(secoes: Array, img: Image, img2: Image, eng) -> String:
	var b64: String = Marshalls.raw_to_base64(img.save_png_to_buffer())
	var b64_2: String = Marshalls.raw_to_base64(img2.save_png_to_buffer())
	var c = eng.sim_config
	var css_grad: String = "linear-gradient(to right, #%s, #%s, #%s)" % [eng.min_sinal_color.to_html(false), eng.critical_sinal_color.to_html(false), eng.max_sinal_color.to_html(false)]
	var h: String = "<!doctype html><html lang='pt-BR'><head><meta charset='utf-8'><title>%s</title><style>" % cfg.titulo.xml_escape()
	h += "body{font-family:Segoe UI,Arial,sans-serif;max-width:1100px;margin:24px auto;padding:0 16px;color:#1b1f24}"
	h += "h1{font-size:26px;border-bottom:3px solid #1f6feb;padding-bottom:6px}h2{font-size:19px;margin-top:30px;color:#1f3b63}"
	h += "table{border-collapse:collapse;margin:10px 0;font-size:13px;width:100%}th,td{border:1px solid #ccd;padding:5px 8px;text-align:left}th{background:#eef2f8}"
	h += "tr:nth-child(even) td{background:#fafbfd}img.mapa{width:100%;max-width:900px;image-rendering:pixelated;border:1px solid #889}"
	h += ".leg{height:16px;width:360px;background:%s;border:1px solid #556}.legt{display:flex;justify-content:space-between;width:360px;font-size:12px}" % css_grad
	h += ".mk span{display:inline-block;margin-right:14px;font-size:12px}li{margin:4px 0}"
	h += "</style></head><body>"
	for s_i in secoes.size():
		var s: Dictionary = secoes[s_i]
		h += "<%s>%s</%s>" % ["h1" if s_i == 0 else "h2", s.titulo.xml_escape(), "h1" if s_i == 0 else "h2"]
		for it in s.itens:
			match it.tipo:
				"p": h += "<p>" + _html_inline(it.texto) + "</p>"
				"imagem":
					h += "<img class='mapa' src='data:image/png;base64,%s' alt='Mapa de potência'>" % (b64 if it.qual == 1 else b64_2)
					h += "<p><i>%s</i></p>" % it.legenda.xml_escape()
					h += "<div class='leg'></div><div class='legt'><span>%d dBm</span><span>%d dBm</span><span>%d dBm</span></div>" % [int(c.min_sinal_dbm), int(c.critical_sinal_dbm), int(c.max_sinal_dbm)]
					h += _legenda_html()
				"lista":
					h += "<ul>" + "".join(PackedStringArray(it.linhas.map(func(l): return "<li>" + _html_inline(l) + "</li>"))) + "</ul>"
				"tabela":
					h += "<table><tr>" + "".join(PackedStringArray(it.cab.map(func(x): return "<th>" + str(x).xml_escape() + "</th>"))) + "</tr>"
					for l in it.linhas:
						h += "<tr>" + "".join(PackedStringArray(l.map(func(x): return "<td>" + str(x).xml_escape() + "</td>"))) + "</tr>"
					h += "</table>"
	h += "</body></html>"
	return h


func _bb_inline(txt: String) -> String:
	var partes: PackedStringArray = txt.replace("[", "[lb]").split("**")
	var out: String = ""
	for i in partes.size():
		out += ("[b]" + partes[i] + "[/b]") if i % 2 == 1 else partes[i]
	return out


func _render_bbcode(secoes: Array) -> String:
	var t: String = ""
	for s_i in secoes.size():
		var s: Dictionary = secoes[s_i]
		t += "[font_size=%d][b]%s[/b][/font_size]\n" % [22 if s_i == 0 else 17, s.titulo.replace("[", "[lb]")]
		for it in s.itens:
			match it.tipo:
				"p": t += _bb_inline(it.texto) + "\n\n"
				"imagem": t += "[center]{{IMAGEM%d}}[/center]\n[center]%s[i]%s[/i][/center]\n\n" % [it.qual, _legenda_bbcode(), it.legenda.replace("[", "[lb]")]
				"lista":
					for l in it.linhas: t += "• " + _bb_inline(l) + "\n"
					t += "\n"
				"tabela":
					t += "[table=%d]" % it.cab.size()
					for x in it.cab: t += "[cell][b] %s [/b][/cell]" % str(x).replace("[", "[lb]")
					for l in it.linhas:
						for x in l: t += "[cell] %s [/cell]" % str(x).replace("[", "[lb]")
					t += "[/table]\n\n"
	return t


func _csv_rx(d: Dictionary) -> String:
	var t: String = "rx;x_m;y_m;z_m;largura_m;comprimento_m;ris_alvo;p_off_dbm;snr_off_db;p_on_dbm;snr_on_db;delta_p_db;delta_snr_db\n"
	for r in d.rx:
		t += "%s;%.2f;%.2f;%.2f;%.2f;%.2f;%s;%.2f;%.2f;%.2f;%.2f;%s;%s\n" % [
			r.nome, r.pos.x, r.pos.y, r.pos.z, r.largura, r.comprimento, "|".join(r.ris),
			r.p_off_dbm, r.snr_off_db, r.p_on_dbm, r.snr_on_db,
			("%.2f" % r.dp_db) if not is_inf(r.dp_db) else "inf",
			("%.2f" % (r.snr_on_db - r.snr_off_db)) if not is_inf(r.dp_db) else "inf"]
	return t


# --- SALVAR ---

## Grava mapa.png, relatorio.md, relatorio.html e rx.csv em <Saves>/Relatorios/<nome>_<data>/ e devolve a pasta.
func salvar(res: Dictionary) -> String:
	var base: String = Manager.save_base_dir.path_join("Relatorios")
	var nome: String = String(cfg.titulo).validate_filename().replace(" ", "_")
	if nome == "":
		nome = "relatorio"
	var carimbo: String = Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	var pasta: String = base.path_join("%s_%s" % [nome, carimbo])
	DirAccess.make_dir_recursive_absolute(pasta)
	(res.imagem as Image).save_png(pasta.path_join("mapa.png"))
	(res.imagem2 as Image).save_png(pasta.path_join("mapa_sem_ris.png"))
	_gravar(pasta.path_join("relatorio.md"), res.markdown)
	_gravar(pasta.path_join("relatorio.html"), res.html)
	_gravar(pasta.path_join("rx.csv"), res.csv_rx)
	return pasta

func _gravar(caminho: String, texto: String) -> void:
	var f := FileAccess.open(caminho, FileAccess.WRITE)
	if f:
		f.store_string(texto)
		f.close()
