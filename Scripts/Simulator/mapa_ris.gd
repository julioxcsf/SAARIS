extends RefCounted
## Efeito dos RIS no mapa (pixel a pixel) e pegada real das construcoes.
##
## - poligonos_predios() / rasterizar_predios(): contorno real dos predios (nao AABB).
## - delta_ris(): potencia (W) que cada RIS ligado soma em cada pixel de chao; cada RIS atende o seu RX alvo.
##   Modos (meta "modo_feixe"):
##   "regiao" (padrao): energia espalhada pela area do RX (fator_regiao, <= 1).
##   "regiao_focada": toda a regiao recebe a potencia do lobulo principal (pico, nunca mais que isso).
##   "fixo": feixe fixo no centro do RX, com o fator sinc^2 da eq. 15.
##   Visada RIS->pixel por raio de fisica; os predios ficam de fora.

const RISModel = preload("res://Scripts/Simulator/ris_model.gd")

const LIMITE_FEIXE := 1.0e-3        # ignora pixels onde o fator de feixe e < -30 dB
const PISO_W := 1.0e-15             # ignora contribuicoes < -120 dBm


## Poligonos (XZ em metros) de todos os predios do importador.
static func poligonos_predios() -> Array:
	var out: Array = []
	var imp = Manager.importer
	if imp == null:
		return out
	var pts: Array[Vector4] = imp.obstaculos_completos_cache
	for o in imp.obstaculos_brutos_cache:
		var off: int = int(o.vertex_offset)
		var n: int = int(o.vertex_count) - 1          # o ultimo vertice repete o primeiro (fechamento)
		if n < 3 or off + n > pts.size():
			continue
		var poly := PackedVector2Array()
		for k in n:
			poly.append(Vector2(pts[off + k].x, pts[off + k].z))
		out.append(poly)
	return out


## Mascara (1 = dentro de um predio) em uma grade WxH que cobre o mapa [off, off+size].
static func rasterizar_predios(w: int, h: int, size: Vector2, off: Vector2) -> PackedByteArray:
	var m := PackedByteArray()
	m.resize(w * h)
	if size.x <= 0.0 or size.y <= 0.0:
		return m
	var sx: float = float(w) / size.x
	var sy: float = float(h) / size.y
	for poly in poligonos_predios():
		var P: PackedVector2Array = poly
		var n: int = P.size()
		var f := PackedVector2Array()
		f.resize(n)
		var y_min: float = INF
		var y_max: float = -INF
		var cx: float = 0.0
		var cy: float = 0.0
		for k in n:
			f[k] = Vector2((P[k].x - off.x) * sx, (P[k].y - off.y) * sy)
			y_min = minf(y_min, f[k].y)
			y_max = maxf(y_max, f[k].y)
			cx += f[k].x
			cy += f[k].y
		var preencheu: bool = false
		for y in range(maxi(0, ceili(y_min - 0.5)), mini(h - 1, floori(y_max - 0.5)) + 1):
			var yc: float = y + 0.5
			var xs: Array = []
			for k in n:
				var a: Vector2 = f[k]
				var b: Vector2 = f[(k + 1) % n]
				if (a.y <= yc and b.y > yc) or (b.y <= yc and a.y > yc):
					xs.append(a.x + (yc - a.y) / (b.y - a.y) * (b.x - a.x))
			xs.sort()
			for k in range(0, xs.size() - 1, 2):
				for x in range(maxi(0, ceili(xs[k] - 0.5)), mini(w - 1, floori(xs[k + 1] - 0.5)) + 1):
					m[y * w + x] = 1
					preencheu = true
		if not preencheu:           # predio menor que um pixel: marca o pixel do centro
			var px: int = int(cx / n)
			var py: int = int(cy / n)
			if px >= 0 and px < w and py >= 0 and py < h:
				m[py * w + px] = 1
	return m


## Soma da potencia (W) dos RIS em cada pixel.
## `incluir_desligados`: conta tambem os RIS desligados na interface.
## Retorna {total: PackedFloat32Array, por_ris: [ {nome, alvo, ligado, contado, pixels, pct, area_m2, pico_dbm} ]}
## `base` (W, sem RIS) serve para contar os pixels onde o RIS aumenta a potencia em >= 3 dB.
static func delta_ris(eng, base: PackedFloat32Array, mascara: PackedByteArray, incluir_desligados: bool = false) -> Dictionary:
	var res: Vector2i = eng.mapa_calor.resolution
	var tam: Vector2 = eng.mapa_calor.size
	var off: Vector2 = eng.mapa_calor.map_offset
	var total := PackedFloat32Array()
	total.resize(res.x * res.y)
	var por_ris: Array = []
	var h = Manager.ris_handler
	if h == null or tam.x <= 0.0 or tam.y <= 0.0:
		return {"total": total, "por_ris": por_ris}

	var espaco: PhysicsDirectSpaceState3D = h.get_world_3d().direct_space_state if h.is_inside_tree() else null
	var excluir: Array[RID] = []
	for r in h.ris_cache:
		for corpo in r.find_children("*", "CollisionObject3D", true, false):
			excluir.append((corpo as CollisionObject3D).get_rid())

	var antenas: Array = eng._coletar_antenas()
	var px_x: float = tam.x / float(res.x)
	var px_z: float = tam.y / float(res.y)
	var area_px: float = px_x * px_z

	for ris in h.ris_cache:
		var ligado: bool = bool(ris.get_meta("ligado"))
		var rx = h.alvo_de(ris)
		var linha := {"nome": ris.name, "alvo": rx.name if rx != null else "", "ligado": ligado,
			"contado": ligado or incluir_desligados, "pixels": 0, "pct": 0.0, "area_m2": 0.0, "pico_dbm": -200.0}
		por_ris.append(linha)
		if rx == null or not linha.contado:
			continue

		var p: Vector3 = ris.global_position
		var alvo: Vector3 = (rx as Node3D).global_position
		var n: Vector3 = h.normal_de(ris)
		var bx: Vector3 = ris.global_transform.basis.x.normalized()
		var by: Vector3 = ris.global_transform.basis.y.normalized()
		var dim: Vector2 = h.tamanho_de(ris)
		var area: float = h.area_real_de(ris)
		var ef: float = float(ris.get_meta("eficiencia"))
		var freq: float = float(ris.get_meta("freq_mhz"))
		var lam: float = 300.0 / freq
		var u_alvo: Vector3 = (alvo - p).normalized()
		var ax: float = u_alvo.dot(bx)
		var ay: float = u_alvo.dot(by)

		# fontes que iluminam o RIS: K = Pt*eta*(A/(4*pi*d1))^2*cos^2(theta_i); potencia no pixel = K / d2^2 * F
		var fontes: Array = []
		for a in antenas:
			if not RISModel.freq_compativel(a.freq, freq):
				continue
			var v1: Vector3 = (a.pos as Vector3) - p
			var d1: float = maxf(v1.length(), 0.01)
			var cos_i: float = n.dot(v1 / d1)
			if cos_i <= 0.0:
				continue
			var perda_tx: float = 0.0
			if espaco != null:
				perda_tx = perda_gume_db(espaco, a.pos, p, lam, excluir, 64)       # TX->RIS: gume de faca
			var pt: float = RISModel.dbm_para_w(a.pot)
			var raz: float = area / (4.0 * PI * d1)
			var atenua_tx: float = pow(10.0, -perda_tx / 10.0)
			fontes.append({"k": pt * ef * raz * raz * cos_i * cos_i * atenua_tx,
				"cap": pt * area * cos_i / (4.0 * PI * d1 * d1) * ef, "pt": pt})
		if fontes.is_empty():
			continue

		# Potencia do LOBULO PRINCIPAL por fonte: eq. 19 no centro do RX (alvo do feixe). Nenhum ponto da regiao pode
		# receber mais que isso; no modo "regiao_focada" e exatamente esse valor que vale para toda a regiao.
		var d2c: float = maxf((alvo - p).length(), 0.3)
		var ok_centro: bool = n.dot((alvo - p) / d2c) > 0.0
		for fs in fontes:
			fs["pico"] = minf(minf(fs.k / (d2c * d2c), fs.cap), fs.pt) if ok_centro else 0.0

		var modo: String = String(ris.get_meta("modo_feixe", "regiao"))
		var regiao: bool = (modo != "fixo")            # "regiao" (espalhada) ou "regiao_focada"
		var meio := Vector2(float(rx.get_meta("width")), float(rx.get_meta("length"))) * 0.5
		var ang: float = deg_to_rad(float(rx.get_meta("rotation")))
		var cs: float = cos(ang)
		var sn: float = sin(ang)
		var u0: int = 0
		var u1: int = res.x - 1
		var v0: int = 0
		var v1: int = res.y - 1
		if regiao:
			var raio: float = meio.length()
			u0 = maxi(0, floori((alvo.x - raio - off.x) / px_x))
			u1 = mini(res.x - 1, floori((alvo.x + raio - off.x) / px_x))
			v0 = maxi(0, floori((alvo.z - raio - off.y) / px_z))
			v1 = mini(res.y - 1, floori((alvo.z + raio - off.y) / px_z))

		var dil: float = 1.0
		if modo == "regiao":
			dil = fator_regiao(area, lam, (alvo - p).length(), 4.0 * meio.x * meio.y)
		var pixels: int = 0
		var pico: float = 0.0
		for v in range(v0, v1 + 1):
			var z: float = off.y + (v + 0.5) * px_z
			for u in range(u0, u1 + 1):
				var i: int = v * res.x + u
				if mascara[i] == 1:
					continue
				if regiao:
					var ddx: float = off.x + (u + 0.5) * px_x - alvo.x
					var ddz: float = z - alvo.z
					if absf(ddx * cs - ddz * sn) > meio.x or absf(ddx * sn + ddz * cs) > meio.y:
						continue
				var pos := Vector3(off.x + (u + 0.5) * px_x, alvo.y, z)
				var v2: Vector3 = pos - p
				var d2: float = v2.length()
				if d2 < 0.3:
					continue
				var dir: Vector3 = v2 / d2
				if n.dot(dir) <= 0.0:
					continue
				var f: float = dil           # modo "regiao": feixe acompanha o usuario, energia diluida na regiao
				if not regiao:
					f = RISModel.fator_feixe(dim.x, dim.y, lam, dir.dot(bx) - ax, dir.dot(by) - ay)
					if f < LIMITE_FEIXE:
						continue
				var w: float = 0.0
				for s in fontes:
					var wp: float = minf(minf(s.k / (d2 * d2) * f, s.cap), s.pt)
					if modo == "regiao_focada":
						wp = s.pico                          # potencia do lobulo principal em toda a regiao
					elif modo == "regiao":
						wp = minf(wp, s.pico * dil)          # nenhum ponto passa do pico (ja diluido)
					w += wp
				if w < PISO_W:
					continue
				if espaco != null:
					w *= pow(10.0, -perda_gume_db(espaco, p, pos, lam, excluir, 40 if regiao else 10) / 10.0)   # RIS->ponto
					if w < PISO_W:
						continue
				total[i] += w
				if w >= base[i]:
					pixels += 1
				pico = maxf(pico, w)
		linha.pixels = pixels
		linha.pct = 100.0 * float(pixels) / float(res.x * res.y)
		linha.area_m2 = pixels * area_px
		linha.pico_dbm = RISModel.w_para_dbm(pico)
	return {"total": total, "por_ris": por_ris}


## Diluicao do feixe no modo "regiao": a mancha do lobulo principal tem area ~ (lambda*d2)^2 / A.
## Se ela e menor que a area do RX, a energia e espalhada: fator = A_mancha / A_rx (<= 1). Usa areas em m^2.
static func fator_regiao(area_ris: float, lam: float, d2: float, area_rx: float) -> float:
	if area_ris <= 0.0 or area_rx <= 0.0:
		return 1.0
	var mancha: float = (lam * d2) * (lam * d2) / area_ris
	return clampf(mancha / area_rx, 0.0, 1.0)


static func _livre(espaco: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3, excluir: Array[RID]) -> bool:
	var dir: Vector3 = b - a
	var dist: float = dir.length()
	if dist < 0.5:
		return true
	dir /= dist
	var q := PhysicsRayQueryParameters3D.create(a + dir * 0.25, b - dir * 0.1)
	q.exclude = excluir
	return espaco.intersect_ray(q).is_empty()


## Perda por difracao em gume de faca (dB, >= 0) entre `a` e `b`, pelo perfil vertical de topos (predio ou chao).
## v = h * sqrt(2*(d1+d2) / (lambda*d1*d2)), com h = topo - altura da linha de visada; vale o maior v.
## Perda por RFMath.calculate_knife_edge_loss_db (aproximacao de Lee). So plano vertical (sem cantos laterais).
static func perda_gume_db(espaco: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3, lam: float,
		excluir: Array[RID], n_max: int = 40) -> float:
	var L: float = a.distance_to(b)
	if L < 1.0:
		return 0.0
	var n: int = clampi(int(L / 4.0), 4, n_max)
	var topo_ref: float = maxf(a.y, b.y) + 300.0
	var v_max: float = -INF
	for i in range(1, n):
		var t: float = float(i) / float(n)
		var pt: Vector3 = a.lerp(b, t)
		var q := PhysicsRayQueryParameters3D.create(Vector3(pt.x, topo_ref, pt.z), Vector3(pt.x, -100.0, pt.z))
		q.exclude = excluir
		var hit: Dictionary = espaco.intersect_ray(q)
		if hit.is_empty():
			continue
		var h: float = (hit.position as Vector3).y - pt.y
		var d1: float = t * L
		var d2: float = (1.0 - t) * L
		var v: float = h * sqrt(2.0 * L / (lam * d1 * d2))
		v_max = maxf(v_max, v)
	if not _livre(espaco, a, b, excluir) and v_max < 0.0:
		v_max = 0.0                         # o raio central bate em algo que o perfil nao captou: pelo menos ~6 dB
	if v_max == -INF:
		return 0.0
	return RFMath.calculate_knife_edge_loss_db(v_max)
