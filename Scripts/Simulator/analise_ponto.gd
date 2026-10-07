extends RefCounted
## Decomposicao analitica (CPU) do valor lido pela ponteira de potencia.
## O valor oficial vem da GPU; aqui o mesmo ponto e refeito por antena para explicar o resultado:
##   P_LOS       = P_TX - L(d3D),  L = 20*log10(f_MHz) - 27.55 + 10*n*log10(d_m)
##   penetracao  = parede/teto de entrada + interior + saida, por predio cruzado (constantes do shader v4)
##   difracao    = 3 caminhos (topo e 2 cantos) do 1o predio; knife-edge ITU-R P.526; soma ate 10 dB do melhor
##   Fresnel     = folga em relacao a 1a zona (so informativo: o shader nao aplica perda em visada livre)
## Nao inclui reflexoes nem difracao em mais de um predio; a diferenca para a GPU aparece no fim do texto.

const ESPESSURA_PAREDE_M := 0.12
const ESPESSURA_TETO_M := 0.20
const ATENUACAO_DB_POR_M := 35.0
const ESPACAMENTO_PAREDES_M := 4.0
const PERDA_PAREDE_INTERNA_DB := 2.0
const COS_INCIDENCIA_MINIMO := 0.20
const LIMIAR_CAMINHO_DB := 10.0
const PISO_DBM := -200.0


static func _log10(x: float) -> float:
	return log(x) / log(10.0)


static func _dbm_w(dbm: float) -> float:
	return pow(10.0, (dbm - 30.0) / 10.0)


static func _w_dbm(w: float) -> float:
	return 10.0 * _log10(w) + 30.0 if w > 0.0 else PISO_DBM


static func perda_percurso_db(d_m: float, f_mhz: float, n: float) -> float:
	if d_m <= 0.001:
		return 0.0
	return 20.0 * _log10(f_mhz) - 27.55 + 10.0 * n * _log10(d_m)


## Knife-edge ITU-R P.526 (a mesma aproximacao do shader): 0 dB para v <= -0,78.
static func perda_gume_itu_db(v: float) -> float:
	if v <= -0.78:
		return 0.0
	var x: float = v - 0.1
	return 6.9 + 20.0 * _log10(sqrt(x * x + 1.0) + x)


## Predios (poligono XZ, topo, base) cuja caixa toca o segmento a->b.
static func predios_no_segmento(a: Vector3, b: Vector3) -> Array:
	var out: Array = []
	var imp = Manager.importer
	if imp == null:
		return out
	var pts: Array[Vector4] = imp.obstaculos_completos_cache
	var min_x: float = minf(a.x, b.x)
	var max_x: float = maxf(a.x, b.x)
	var min_z: float = minf(a.z, b.z)
	var max_z: float = maxf(a.z, b.z)
	for o in imp.obstaculos_brutos_cache:
		var bmin: Vector3 = o.bounds_min
		var bmax: Vector3 = o.bounds_max
		if bmax.x < min_x or bmin.x > max_x or bmax.z < min_z or bmin.z > max_z:
			continue
		var off: int = int(o.vertex_offset)
		var n: int = int(o.vertex_count) - 1          # o ultimo vertice repete o primeiro
		if n < 3 or off + n > pts.size():
			continue
		var poly := PackedVector2Array()
		for k in n:
			poly.append(Vector2(pts[off + k].x, pts[off + k].z))
		var tx_dentro: bool = a.x >= bmin.x and a.x <= bmax.x and a.y >= bmin.y and a.y <= bmax.y and a.z >= bmin.z and a.z <= bmax.z
		out.append({"poly": poly, "top": bmax.y, "bottom": bmin.y, "id": int(o.id), "tx_dentro": tx_dentro})
	return out


## Trechos (parametro t in [0,1] de a->b) em que o segmento esta DENTRO do predio (planta + altura).
## Cada trecho: {t0, t1, teto0, teto1, n0, n1, rx_dentro}; n = normal 3D da superficie de entrada/saida.
static func trechos_dentro(pred: Dictionary, a: Vector3, b: Vector3) -> Array:
	var poly: PackedVector2Array = pred.poly
	var a2 := Vector2(a.x, a.z)
	var r: Vector2 = Vector2(b.x, b.z) - a2
	var cruz: Array = []
	var n: int = poly.size()
	for k in n:
		var p: Vector2 = poly[k]
		var s: Vector2 = poly[(k + 1) % n] - p
		var den: float = r.cross(s)
		if absf(den) < 1.0e-9:
			continue
		var t: float = (p - a2).cross(s) / den
		var u: float = (p - a2).cross(r) / den
		if t >= 0.0 and t <= 1.0 and u >= 0.0 and u < 1.0:
			var nm := Vector2(-s.y, s.x).normalized()
			cruz.append({"t": t, "n": Vector3(nm.x, 0.0, nm.y)})
	cruz.sort_custom(func(x, y): return x.t < y.t)
	var dentro: bool = Geometry2D.is_point_in_polygon(a2, poly)
	var intervalos: Array = []
	var t_in: float = 0.0 if dentro else -1.0
	var n_in := Vector3.UP
	for e in cruz:
		if not dentro:
			dentro = true
			t_in = e.t
			n_in = e.n
		else:
			intervalos.append({"t0": t_in, "t1": e.t, "n0": n_in, "n1": e.n, "rx_dentro": false})
			dentro = false
	if dentro:
		intervalos.append({"t0": t_in, "t1": 1.0, "n0": n_in, "n1": Vector3.UP, "rx_dentro": true})

	var out: Array = []
	var dy: float = b.y - a.y
	for iv in intervalos:
		var t0: float = iv.t0
		var t1: float = iv.t1
		var teto0: bool = false
		var teto1: bool = false
		if absf(dy) < 1.0e-9:
			if a.y > pred.top or a.y < pred.bottom:
				continue
		else:
			var ta: float = (pred.top - a.y) / dy
			var tb: float = (pred.bottom - a.y) / dy
			var tmin: float = minf(ta, tb)
			var tmax: float = maxf(ta, tb)
			if tmin > t0 + 1.0e-6:
				t0 = tmin
				teto0 = true
			if tmax < t1 - 1.0e-6:
				t1 = tmax
				teto1 = true
				iv["rx_dentro"] = false
		if t1 <= t0 + 1.0e-6:
			continue
		out.append({"t0": t0, "t1": t1, "n0": Vector3.UP if teto0 else iv.n0, "n1": Vector3.UP if teto1 else iv.n1,
			"teto0": teto0, "teto1": teto1, "rx_dentro": iv.rx_dentro})
	return out


static func _perda_superficie_db(dir: Vector3, nrm: Vector3, teto: bool) -> float:
	var c: float = maxf(absf(dir.normalized().dot(nrm.normalized())), COS_INCIDENCIA_MINIMO)
	return (ESPESSURA_TETO_M if teto else ESPESSURA_PAREDE_M) / c * ATENUACAO_DB_POR_M


## Altura do topo do que ha sob (x,z): predio mais alto ali, ou o chao.
static func _topo_em(x: float, z: float, preds: Array, chao_y: float) -> Dictionary:
	var h: float = chao_y
	var obst: String = "chão"
	var p := Vector2(x, z)
	for pr in preds:
		if pr.top > h and Geometry2D.is_point_in_polygon(p, pr.poly):
			h = pr.top
			obst = "prédio %d" % int(pr.id)
	return {"y": h, "obst": obst}


## Analise de UMA antena ate o ponto `rx`. Retorna um dicionario com todos os termos (dB e dBm).
static func analisar_antena(ant: Dictionary, rx: Vector3, chao_y: float, n_exp: float) -> Dictionary:
	var tx: Vector3 = ant.pos
	var f: float = float(ant.freq)
	var pot: float = float(ant.pot)
	var lam: float = 300.0 / maxf(f, 1.0)
	var L: float = maxf(tx.distance_to(rx), 0.001)
	var d_h: float = Vector2(tx.x - rx.x, tx.z - rx.z).length()
	var r := {"pot": pot, "freq": f, "d_h": d_h, "dh": tx.y - rx.y, "d3": L, "n": n_exp, "tx": tx, "rx": rx}
	var perc: float = perda_percurso_db(L, f, n_exp)
	r["perda_percurso"] = perc
	r["p_los_dbm"] = pot - perc

	var preds: Array = predios_no_segmento(tx, rx)

	# --- penetracao: predios cruzados pelo raio direto
	var dir: Vector3 = (rx - tx) / L
	var lista: Array = []
	var pen_total: float = 0.0
	var primeiro: Dictionary = {}
	var t_primeiro: float = 2.0
	for pr in preds:
		if pr.tx_dentro:
			continue
		for tr in trechos_dentro(pr, tx, rx):
			var dentro_m: float = (tr.t1 - tr.t0) * L
			var perda: float = _perda_superficie_db(dir, tr.n0, tr.teto0)
			var sai: float = 0.0
			if not tr.rx_dentro:
				sai = _perda_superficie_db(dir, tr.n1, tr.teto1)
			var inter: float = dentro_m * PERDA_PAREDE_INTERNA_DB / ESPACAMENTO_PAREDES_M
			lista.append({"id": int(pr.id), "dentro_m": dentro_m, "entrada_db": perda, "interior_db": inter, "saida_db": sai,
				"total_db": perda + inter + sai, "entrada_teto": tr.teto0})
			pen_total += perda + inter + sai
			if tr.t0 < t_primeiro:
				t_primeiro = tr.t0
				primeiro = pr
	r["los"] = lista.is_empty()
	r["predios"] = lista
	r["penetracao_db"] = pen_total
	r["p_transmitido_dbm"] = (pot - perc - pen_total) if not lista.is_empty() else PISO_DBM

	# --- perfil vertical (predios + chao): Fresnel / topo
	var n_am: int = clampi(int(L / 1.0), 24, 240)
	var v_max: float = -INF
	var melhor := {}
	for i in range(1, n_am):
		var t: float = float(i) / float(n_am)
		var pt: Vector3 = tx.lerp(rx, t)
		var top: Dictionary = _topo_em(pt.x, pt.z, preds, chao_y)
		var h: float = float(top.y) - pt.y
		var d1: float = t * L
		var d2: float = (1.0 - t) * L
		var v: float = h * sqrt(2.0 * L / (lam * d1 * d2))
		if v > v_max:
			v_max = v
			melhor = {"t": t, "h": h, "d1": d1, "d2": d2, "obst": top.obst, "y": top.y, "pt": pt,
				"r1": sqrt(lam * d1 * d2 / L)}
	if not melhor.is_empty():
		var folga: float = -float(melhor.h)
		r["fresnel"] = {"v": v_max, "folga_m": folga, "r1_m": melhor.r1, "pct": 100.0 * folga / maxf(melhor.r1, 1.0e-6),
			"obst": melhor.obst, "perda_teorica_db": perda_gume_itu_db(v_max), "d1": melhor.d1, "d2": melhor.d2}

	# --- difracao (so se o raio direto esta bloqueado): topo + 2 cantos laterais do 1o predio
	var caminhos: Array = []
	if not lista.is_empty() and not primeiro.is_empty():
		var qs: Array = []
		# topo: ponto do perfil (dentro do predio) com maior obstrucao, na altura do teto
		var topo_q := Vector3.ZERO
		var achou_topo: bool = false
		var v_top: float = -INF
		for i in range(1, n_am):
			var t2: float = float(i) / float(n_am)
			var pt2: Vector3 = tx.lerp(rx, t2)
			if Geometry2D.is_point_in_polygon(Vector2(pt2.x, pt2.z), primeiro.poly):
				var h2: float = float(primeiro.top) - pt2.y
				var vv: float = h2 * sqrt(2.0 * L / (lam * t2 * L * (1.0 - t2) * L))
				if vv > v_top:
					v_top = vv
					topo_q = Vector3(pt2.x, primeiro.top, pt2.z)
					achou_topo = true
		if achou_topo:
			qs.append({"nome": "topo", "q": topo_q})
		# cantos laterais: vertices mais afastados da linha, de cada lado, dentro do trecho
		var a2 := Vector2(tx.x, tx.z)
		var ab2: Vector2 = Vector2(rx.x, rx.z) - a2
		var lab: float = maxf(ab2.length(), 1.0e-6)
		var melhor_esq: float = 0.0
		var melhor_dir: float = 0.0
		var q_esq := Vector3.ZERO
		var q_dir := Vector3.ZERO
		for vtx in (primeiro.poly as PackedVector2Array):
			var rel: Vector2 = vtx - a2
			var proj: float = rel.dot(ab2) / (lab * lab)
			if proj <= 0.0 or proj >= 1.0:
				continue
			var lado: float = ab2.cross(rel) / lab          # >0 esquerda, <0 direita
			var yq: float = clampf(tx.y + (rx.y - tx.y) * proj, float(primeiro.bottom), float(primeiro.top))
			if lado > melhor_esq:
				melhor_esq = lado
				q_esq = Vector3(vtx.x, yq, vtx.y)
			elif -lado > melhor_dir:
				melhor_dir = -lado
				q_dir = Vector3(vtx.x, yq, vtx.y)
		if melhor_esq > 0.0:
			qs.append({"nome": "canto esquerdo", "q": q_esq})
		if melhor_dir > 0.0:
			qs.append({"nome": "canto direito", "q": q_dir})
		var melhor_p: float = -INF
		for e in qs:
			var q: Vector3 = e.q
			var dq1: float = tx.distance_to(q)
			var dq2: float = q.distance_to(rx)
			var delta: float = maxf(dq1 + dq2 - L, 0.0)
			var v: float = sqrt(2.0 * delta / lam)
			var kn: float = perda_gume_itu_db(v)
			var pp: float = pot - perda_percurso_db(dq1 + dq2, f, n_exp) - kn
			caminhos.append({"nome": e.nome, "d": dq1 + dq2, "v": v, "gume_db": kn, "p_dbm": pp})
			melhor_p = maxf(melhor_p, pp)
		var w_dif: float = 0.0
		for c in caminhos:
			c["conta"] = c.p_dbm >= melhor_p - LIMIAR_CAMINHO_DB
			if c.conta:
				w_dif += _dbm_w(c.p_dbm)
		r["p_difracao_dbm"] = _w_dbm(w_dif)
	r["difracao"] = caminhos

	# --- soma analitica desta antena (sem reflexoes)
	var w: float = 0.0
	if lista.is_empty():
		w = _dbm_w(r.p_los_dbm)
	else:
		w = _dbm_w(r.p_transmitido_dbm)
		if r.has("p_difracao_dbm"):
			w += _dbm_w(r.p_difracao_dbm)
	r["p_total_dbm"] = _w_dbm(w)
	return r


const C_TIT := "#ffb454"     # titulos / TX
const C_OK := "#6fe08a"      # verde: bom / sem perda
const C_RUIM := "#ff6b6b"    # vermelho: perda / bloqueio
const C_VAL := "#7fd4ff"     # ciano: valores de potencia
const C_DIM := "#8a97a8"     # cinza: notas
const C_AVISO := "#ffd866"   # amarelo: aviso


static func _f(x: float, d: int = 1) -> String:
	return ("%." + str(d) + "f") % x


static func _c(txt: String, cor: String) -> String:
	return "[color=%s]%s[/color]" % [cor, txt]


static func _dbm_txt(x: float) -> String:
	return "—" if x <= PISO_DBM + 1.0 else "%.1f dBm" % x


static func _cel(rot: String, val: String) -> String:
	return "[cell][color=%s]%s[/color][/cell][cell]%s[/cell]" % [C_DIM, rot, val]


static func _sec(nome: String) -> String:
	return "\n[color=%s][b]▸ %s[/b][/color]\n" % [C_TIT, nome]


## Texto (BBCode) da ponteira. `rx` = centro do pixel (com a altura de recepcao do shader).
static func texto(eng, rx: Vector3, chao_y: float, px: Vector2i) -> String:
	var antenas: Array = eng._coletar_antenas()
	var idx: int = px.y * eng.mapa_calor.resolution.x + px.x
	var w_gpu: float = eng.mapa_calor.power_map_watts[idx]
	var w_ris: float = 0.0
	if eng.ris_delta_watts.size() == eng.mapa_calor.power_map_watts.size():
		w_ris = eng.ris_delta_watts[idx]
	var t: String = "[color=%s]pixel (%d, %d) · RX a %s m do chão[/color]\n" % [C_DIM, px.x, px.y, _f(rx.y, 2)]
	t += "[font_size=22][b]%s[/b][/font_size]  [color=%s]mapa (GPU %s" % [_c(_dbm_txt(_w_dbm(w_gpu + w_ris)), C_VAL), C_DIM, _dbm_txt(_w_dbm(w_gpu))]
	if w_ris > 0.0:
		t += " + RIS %s" % _dbm_txt(_w_dbm(w_ris))
	t += ")[/color]\n"
	var n_exp: float = eng.exponente_efetivo()
	var w_soma: float = 0.0
	var k: int = 0
	for ant in antenas:
		k += 1
		if k > 4:
			t += "\n[color=%s]… (+%d antenas não detalhadas)[/color]" % [C_DIM, antenas.size() - 4]
			break
		var r: Dictionary = analisar_antena(ant, rx, chao_y, n_exp)
		w_soma += _dbm_w(r.p_total_dbm)
		t += "\n[color=%s][b]━━ TX %d ━━[/b][/color]  P_TX = [b]%s dBm[/b] · %s MHz\n" % [C_TIT, k, _f(r.pot), _f(r.freq, 0)]
		t += "[table=4]"
		t += _cel("Distância 3D (completa)", "[b]%s m[/b]" % _f(r.d3, 2))
		t += _cel("Dist. horizontal", "[b]%s m[/b]" % _f(r.d_h, 2))
		t += _cel("ΔH (TX − RX)", "[b]%s m[/b]" % _f(r.dh, 2))
		t += _cel("Visada (LOS)", _c("SIM", C_OK) if r.los else _c("NÃO", C_RUIM))
		t += "[/table]\n"

		t += _sec("Espaço livre")
		t += "L = 20·log₁₀(%s MHz) − 27,55 + %s·log₁₀(%s m) = %s\n" % [_f(r.freq, 0), _f(10.0 * r.n, 1), _f(r.d3, 1), _c(_f(r.perda_percurso) + " dB", C_RUIM)]
		t += "P_TX − L = %s − %s = [b]%s[/b]  [color=%s](n = %s)[/color]\n" % [_f(r.pot), _f(r.perda_percurso), _c(_dbm_txt(r.p_los_dbm), C_VAL), C_DIM, _f(r.n, 2)]

		if r.has("fresnel"):
			var fr: Dictionary = r.fresnel
			t += _sec("1ª zona de Fresnel")
			if r.los and fr.perda_teorica_db > 0.05:
				t += _c("violada", C_AVISO) + " · folga %s m = %s %% de r1 (%s m), obstruída por %s\n" % [_f(fr.folga_m, 2), _f(fr.pct, 0), _f(fr.r1_m, 2), fr.obst]
				t += "perda teórica %s  [color=%s](o shader NÃO aplica perda de Fresnel em visada livre)[/color]\n" % [_c(_f(fr.perda_teorica_db) + " dB", C_AVISO), C_DIM]
			elif r.los:
				t += _c("livre", C_OK) + " · folga mínima %s m = %s %% de r1 (%s m, %s) → 0 dB\n" % [_f(fr.folga_m, 2), _f(fr.pct, 0), _f(fr.r1_m, 2), fr.obst]
			else:
				t += "linha direta bloqueada por %s (v = %s)\n" % [fr.obst, _f(fr.v, 2)]

		if not r.los:
			t += _sec("Transmissão pelo prédio")
			for p in r.predios:
				t += "prédio %d · %s m dentro: entrada (%s) %s + interior %s + saída %s = %s\n" % [
					p.id, _f(p.dentro_m, 1), "teto" if p.entrada_teto else "parede", _f(p.entrada_db), _f(p.interior_db), _f(p.saida_db), _c(_f(p.total_db) + " dB", C_RUIM)]
			t += "P_TX − L − penetração = [b]%s[/b]  [color=%s](penetração total %s dB)[/color]\n" % [_c(_dbm_txt(r.p_transmitido_dbm), C_VAL), C_DIM, _f(r.penetracao_db)]
			t += _sec("Difração (gume de faca)")
			t += "[table=5][cell][color=%s]caminho[/color][/cell][cell][color=%s]percurso[/color][/cell][cell][color=%s]v[/color][/cell][cell][color=%s]gume[/color][/cell][cell][color=%s]chega[/color][/cell]" % [C_DIM, C_DIM, C_DIM, C_DIM, C_DIM]
			for c in r.difracao:
				var cor: String = C_VAL if c.conta else C_DIM
				t += "[cell]%s[/cell][cell]%s m[/cell][cell]%s[/cell][cell]%s[/cell][cell][color=%s]%s%s[/color][/cell]" % [
					c.nome, _f(c.d, 1), _f(c.v, 2), _c(_f(c.gume_db) + " dB", C_RUIM), cor, _dbm_txt(c.p_dbm), "" if c.conta else " (ignorado)"]
			t += "[/table]\n"
			if r.has("p_difracao_dbm"):
				t += "Difração total chegando: [b]%s[/b]\n" % _c(_dbm_txt(r.p_difracao_dbm), C_VAL)
		t += "[color=%s]Soma analítica da antena (sem reflexões):[/color] [b]%s[/b]\n" % [C_DIM, _c(_dbm_txt(r.p_total_dbm), C_VAL)]
	if antenas.size() > 0:
		var soma_dbm: float = _w_dbm(w_soma)
		var gpu_dbm: float = _w_dbm(w_gpu)
		t += _sec("Analítico × GPU")
		t += "analítico %s  ·  GPU %s" % [_c(_dbm_txt(soma_dbm), C_VAL), _c(_dbm_txt(gpu_dbm), C_VAL)]
		if soma_dbm > PISO_DBM + 1.0 and gpu_dbm > PISO_DBM + 1.0:
			var dif: float = gpu_dbm - soma_dbm
			t += "  ·  diferença %s dB [color=%s](reflexões / aproximações)[/color]" % [_c(_f(dif), C_OK if absf(dif) < 3.0 else C_AVISO), C_DIM]
		t += "\n"
	return t
