extends Node
## GeoManager: orquestra o mundo real no SAARIS.
##
## Fluxo:
##   1. Ao abrir, carrega uma REGIAO (padrao 2x2 km) centrada na origem lat/lon
##      (Ilha do Fundao): relevo + OSM + antenas.
##   2. Enquanto "Seguir camera" esta ligado, a regiao acompanha o que o usuario ve
##      (foco = ponto do chao no centro da tela). Cada regiao e baixada UMA vez e
##      fica em disco (GeoCache/); revisitar e instantaneo e funciona offline.
##   3. Ao apertar "Simular": se a camera aponta para fora da regiao, a regiao do
##      foco e carregada primeiro; depois a regiao e FIXADA (manifesto em
##      GeoCache/regions/) e o simulador usa terreno + predios + antenas dela.
##
## Quadro de coordenadas: ver geo_frame.gd (x leste, z sul, y altura; origem fixa).

const GeoFrame = preload("res://Scripts/Geo/geo_frame.gd")
const GeoUtils = preload("res://Scripts/Geo/geo_utils.gd")
const GeoHttp = preload("res://Scripts/Geo/geo_http.gd")
const TerrainProvider = preload("res://Scripts/Geo/terrain_provider.gd")
const OsmProvider = preload("res://Scripts/Geo/osm_provider.gd")
const AnatelProvider = preload("res://Scripts/Geo/anatel_provider.gd")
const RmfProvider = preload("res://Scripts/Geo/rmf_provider.gd")
const GeoUI = preload("res://Scripts/Geo/geo_ui.gd")
const GeoHud = preload("res://Scripts/Geo/geo_hud.gd")
const PackageProvider = preload("res://Scripts/Geo/package_provider.gd")

signal status_changed(msg: String)
signal region_loaded(info: Dictionary)
signal antennas_changed
signal settings_changed
signal log_line(msg: String)
signal camera_latlon_changed(lat: float, lon: float)
signal package_changed

enum FonteAntenas { RMF_API, ANATEL_CSV, RMF_E_ANATEL, SO_TORRES_OSM }

# Configuracao (editavel no Inspetor e no painel "Mapa real")
@export_group("Origem e região")
## Centro da Ilha do Fundao (centro do arquivo Toda_ilha_fundao.osm)
@export var lat_inicial: float = -22.8558
@export var lon_inicial: float = -43.2256
@export var tamanho_regiao_m: float = 2000.0
## Espacamento da grade de relevo (m). Menor = mais detalhe e mais VRAM/tempo.
@export var passo_terreno_m: float = 8.0
@export var carregar_ao_iniciar: bool = true

@export_group("Streaming do mapa (chunks)")
## Tamanho do chunk (m). A regiao recarrega "saltando" de chunk em chunk quando a camera anda.
@export var tamanho_chunk_m: float = 500.0
## Quantos chunks AO REDOR da regiao sao baixados em segundo plano (relevo + OSM + antenas)
## em cada direcao, para a troca de regiao nao esperar a internet. 0 = desliga o pre-carregamento.
@export_range(0, 6) var chunks_pre_carregados: int = 2
## So leitura (atualiza sozinho com a camera): lat/lon do ponto do chao no centro da tela.
@export var lat_camera: float = 0.0
@export var lon_camera: float = 0.0

@export_group("Pacote SAARIS Data Source (opcional)")
## manifesto.json ou .zip gerado pela pagina SAARIS_DataSource/index.html. Se vazio, usa o ultimo
## pacote importado pelo painel (se houver). O pacote traz relevo + predios casados e dispensa a rede.
@export_file("*.json", "*.zip") var pacote_inicial: String = ""
## Ao abrir, reabre o ultimo pacote importado pelo painel.
@export var reabrir_ultimo_pacote: bool = true

@export_group("Camadas")
@export var usar_relevo: bool = true
@export var usar_osm: bool = true
@export var usar_antenas: bool = true
@export var seguir_camera: bool = true

@export_group("Antenas reais")
@export var fonte_antenas: FonteAntenas = FonteAntenas.RMF_E_ANATEL
## Token da API RMF (https://redesmoveisfixas.com/createapi). Prefira colar no painel "Mapa real"
## (fica em GeoCache/geo_settings.cfg) ou na variavel de ambiente RMF_TOKEN. NAO suba isto pro Git.
@export var rmf_token: String = ""
@export var antenas_margem_m: float = 500.0     # inclui antenas ate X m fora da regiao (interferencia/cobertura)
@export var altura_padrao_antena_m: float = 30.0
@export var freq_padrao_mhz: float = 2100.0     # usada quando o registro nao traz frequencia
@export var potencia_padrao_dbm: float = 40.0   # EIRP omni usada na simulacao (a base Anatel nao traz EIRP confiavel)

# Estado
var frame = null                 # GeoFrame
var http: Node = null
var terrain: Node = null
var osm: Node = null
var anatel: Node = null
var rmf: Node = null
var _prefetch_id: int = 0
var prefetch_estado: String = ""
var conexao: Dictionary = {}
var pacote = null                # PackageProvider (null = modo online)
var _lado_atual: float = 0.0
var _ultimo_pacote: String = ""
var ui: Control = null

var regiao: Dictionary = {}      # {id, center: Vector2, half, bbox, terrain, osm_paths}
var antenas_regiao: Array = []   # Array[Dictionary] (ver _mk_antena)
var selecionadas: Dictionary = {}  # id -> true
var carregando: bool = false
var regiao_fixada: bool = false

var _pendente: Variant = null
var _marcadores: MultiMeshInstance3D = null
var _acc: float = 0.0
var _candidato: Vector2 = Vector2.INF
var _candidato_t: float = 0.0
var _status: String = ""

const OP_CORES := {
	"Vivo": Color(0.62, 0.18, 0.75),
	"Claro": Color(0.90, 0.15, 0.15),
	"TIM": Color(0.15, 0.35, 0.90),
	"Oi": Color(0.95, 0.75, 0.10),
	"Algar": Color(0.10, 0.65, 0.35),
	"OSM": Color(0.85, 0.85, 0.85),
}


func _ready() -> void:
	Manager.geo = self
	_carregar_config()
	frame = GeoFrame.new(lat_inicial, lon_inicial)

	http = GeoHttp.new()
	http.name = "GeoHttp"
	add_child(http)

	terrain = TerrainProvider.new()
	terrain.name = "TerrainProvider"
	terrain.http = http
	terrain.status.connect(_status_prog)
	add_child(terrain)

	osm = OsmProvider.new()
	osm.name = "OsmProvider"
	osm.http = http
	osm.status.connect(_status_prog)
	add_child(osm)

	anatel = AnatelProvider.new()
	anatel.name = "AnatelProvider"
	anatel.load_index()
	anatel.import_progress.connect(_status_prog)
	anatel.import_finished.connect(_on_anatel_import_finished)
	add_child(anatel)

	rmf = RmfProvider.new()
	rmf.name = "RmfProvider"
	rmf.http = http
	rmf.status.connect(_status_prog)
	var tok_env: String = OS.get_environment("RMF_TOKEN")
	rmf.token = rmf_token if rmf_token != "" else tok_env
	add_child(rmf)
	rmf_token = rmf.token if rmf.token != "" else rmf_token

	# Painel de UI (criado por codigo para nao mexer no gui.tscn)
	var canvas: Node = get_node_or_null("../../CanvasLayer")
	if canvas == null:
		canvas = CanvasLayer.new()
		add_child(canvas)
	ui = GeoUI.new()
	ui.geo = self
	canvas.add_child(ui)
	var hud: Control = GeoHud.new()
	hud.name = "GeoHud"
	hud.geo = self
	canvas.add_child(hud)

	# Espera o resto da cena (importer, engine, camera) terminar o _ready
	for i in 3:
		await get_tree().process_frame
	_log("🌍 GeoManager iniciado. Origem %.5f, %.5f | região %.1f km | chunk %d m | pré-carga %d chunk(s)/direção" % [lat_inicial, lon_inicial, tamanho_regiao_m / 1000.0, int(tamanho_chunk_m), chunks_pre_carregados])
	_log("Cache em: " + GeoUtils.cache_root())
	if carregar_ao_iniciar:
		var pk: String = pacote_inicial
		if pk == "" and reabrir_ultimo_pacote:
			pk = _ultimo_pacote
		if pk != "" and FileAccess.file_exists(pk):
			if await importar_pacote(pk):
				return
			_log("⚠ Não consegui abrir o pacote; seguindo no modo online.")
		testar_conexao()   # em paralelo com a primeira carga (nao espera)
		await carregar_regiao(Vector2.ZERO)


func _exit_tree() -> void:
	if Manager.geo == self:
		Manager.geo = null


# Status / config
## Mensagem de andamento (barra de status; nao vai para o log, para nao poluir)
func _status_prog(msg: String) -> void:
	_status = msg
	status_changed.emit(msg)


## Marco importante: aparece na barra de status E no log (F3) E no console do Godot.
func _set_status(msg: String) -> void:
	_status = msg
	status_changed.emit(msg)
	_log(msg)


func _log(msg: String) -> void:
	print("[geo] ", msg)
	log_line.emit(msg)


func status() -> String:
	return _status


func _config_path() -> String:
	return GeoUtils.cache_root().path_join("geo_settings.cfg")


## O Inspetor do no e a fonte da verdade para origem, regiao, chunks e fonte de antenas;
## o arquivo guarda so token, camadas e padroes de antena.
func _carregar_config() -> void:
	var c: ConfigFile = ConfigFile.new()
	if c.load(_config_path()) != OK:
		return
	if rmf_token == "":
		rmf_token = str(c.get_value("rmf", "token", ""))
	_ultimo_pacote = str(c.get_value("pacote", "ultimo", ""))
	usar_relevo = c.get_value("geo", "relevo", usar_relevo)
	usar_osm = c.get_value("geo", "osm", usar_osm)
	usar_antenas = c.get_value("geo", "antenas", usar_antenas)
	freq_padrao_mhz = c.get_value("geo", "freq_padrao", freq_padrao_mhz)
	potencia_padrao_dbm = c.get_value("geo", "pot_padrao", potencia_padrao_dbm)
	altura_padrao_antena_m = c.get_value("geo", "alt_padrao", altura_padrao_antena_m)


func salvar_config() -> void:
	var c: ConfigFile = ConfigFile.new()
	c.set_value("geo", "lat", frame.lat0 if frame else lat_inicial)
	c.set_value("geo", "lon", frame.lon0 if frame else lon_inicial)
	c.set_value("geo", "tamanho_m", tamanho_regiao_m)
	c.set_value("geo", "chunk_m", tamanho_chunk_m)
	c.set_value("geo", "pre_chunks", chunks_pre_carregados)
	c.set_value("geo", "fonte_antenas", int(fonte_antenas))
	c.set_value("rmf", "token", rmf.token if rmf else rmf_token)
	c.set_value("pacote", "ultimo", _ultimo_pacote)
	c.set_value("geo", "relevo", usar_relevo)
	c.set_value("geo", "osm", usar_osm)
	c.set_value("geo", "antenas", usar_antenas)
	c.set_value("geo", "freq_padrao", freq_padrao_mhz)
	c.set_value("geo", "pot_padrao", potencia_padrao_dbm)
	c.set_value("geo", "alt_padrao", altura_padrao_antena_m)
	DirAccess.make_dir_recursive_absolute(GeoUtils.cache_root())
	c.save(_config_path())


# Foco da camera

## Ponto do chao (x, z locais) no centro da tela; null se a camera nao olha para baixo.
func foco_da_camera() -> Variant:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return null
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var o: Vector3 = cam.project_ray_origin(vp * 0.5)
	var d: Vector3 = cam.project_ray_normal(vp * 0.5)
	if d.y > -0.02:
		return null
	var h: float = 0.0
	var hit: Vector3 = o
	for i in 3:   # itera: plano -> altura do terreno no ponto -> plano...
		var t: float = (h - o.y) / d.y
		hit = o + d * t
		if Manager.importer and Manager.importer.geo_ativo:
			h = Manager.importer.terrain_height_at(hit.x, hit.z)
	if hit.distance_to(o) > 30000.0:
		return null
	return Vector2(hit.x, hit.z)


func _snap(p: Vector2) -> Vector2:
	return Vector2(round(p.x / tamanho_chunk_m) * tamanho_chunk_m, round(p.y / tamanho_chunk_m) * tamanho_chunk_m)


func _fora_da_regiao(p: Vector2, folga_rel: float = 1.0) -> bool:
	if regiao.is_empty():
		return true
	var c: Vector2 = regiao.center
	var lim: float = float(regiao.half) * folga_rel
	return absf(p.x - c.x) > lim or absf(p.y - c.y) > lim


func _process(delta: float) -> void:
	_acc += delta
	if _acc < 0.3:
		return
	var dt: float = _acc
	_acc = 0.0

	var foco: Variant = foco_da_camera()
	if foco != null and frame != null:
		var ll: Vector2 = frame.xz_to_latlon(Vector2(foco).x, Vector2(foco).y)
		lat_camera = ll.x
		lon_camera = ll.y
		camera_latlon_changed.emit(lat_camera, lon_camera)

	if not seguir_camera or carregando or regiao_fixada_em_uso():
		return
	if foco == null:
		return
	var f: Vector2 = foco
	# Histerese: so recarrega quando o foco sai da metade central da regiao
	if not _fora_da_regiao(f, 0.5):
		_candidato = Vector2.INF
		return
	var alvo: Vector2 = _snap(f)
	if pacote != null:
		alvo = pacote.clamp_centro(alvo, minf(tamanho_regiao_m, pacote.lado_maximo()))
		if not regiao.is_empty() and alvo.distance_to(Vector2(regiao.center)) < 1.0:
			_candidato = Vector2.INF
			return
	if alvo != _candidato:
		_candidato = alvo
		_candidato_t = 0.0
	else:
		_candidato_t += dt
		if _candidato_t >= 0.9:   # a camera parou: carrega
			_candidato = Vector2.INF
			carregar_regiao(alvo)


## Enquanto uma simulacao esta rodando, a regiao nao pode trocar.
func regiao_fixada_em_uso() -> bool:
	return Manager.is_simulating


# Carregamento de regiao

## Carrega (ou recarrega) a regiao centrada em center_xz (m, quadro local).
func carregar_regiao(center_xz: Vector2) -> bool:
	if carregando:
		_pendente = center_xz
		return false
	carregando = true
	var ok: bool = await _carregar_regiao_interno(center_xz)
	carregando = false

	if _pendente != null:
		var p: Vector2 = _pendente
		_pendente = null
		if regiao.is_empty() or (p - Vector2(regiao.center)).length() > 1.0:
			return await carregar_regiao(p)
	return ok


func _carregar_regiao_interno(center_xz: Vector2) -> bool:
	if Manager.importer == null or Manager.engine == null:
		_set_status("⚠ Importador/simulador ainda não prontos.")
		return false

	# Janela efetiva: com pacote, nao pode passar do que o pacote cobre e fica dentro dele
	var lado: float = tamanho_regiao_m
	if pacote != null:
		lado = minf(lado, pacote.lado_maximo())
		center_xz = pacote.clamp_centro(center_xz, lado)
	_lado_atual = lado
	var half: float = lado * 0.5
	var res: int = clampi(int(round(lado / passo_terreno_m)) + 1, 33, 513)
	_prefetch_id += 1   # cancela pre-carga em andamento (a regiao atual tem prioridade)
	var ll_c: Vector2 = frame.xz_to_latlon(center_xz.x, center_xz.y)
	_set_status("Carregando região %.1f km em %.5f, %.5f %s…" % [lado / 1000.0, ll_c.x, ll_c.y, "(pacote)" if pacote != null else ""])

	# 1) RELEVO
	var hf: Dictionary
	if pacote != null and usar_relevo:
		hf = pacote.heightfield(center_xz, lado, res)
		_log("Relevo: do pacote (%.0f…%.0f m)" % [hf.hmin, hf.hmax])
	elif usar_relevo:
		var _t0 := Time.get_ticks_msec()
		hf = await terrain.build_heightfield(frame, center_xz, lado, res)
		_log("Relevo: %s (%d ms)" % ["OK" if hf.ok else "FALHOU", Time.get_ticks_msec() - _t0])
		if not hf.ok:
			_set_status("⚠ %s Usando terreno plano." % hf.error)
			hf = terrain.flat_heightfield(center_xz, lado, res)
	else:
		hf = terrain.flat_heightfield(center_xz, lado, res)

	# 2) OSM (celulas de ~1 km em cache)
	var paths: PackedStringArray = PackedStringArray()
	var falhas: int = 0
	if usar_osm and pacote != null:
		paths = pacote.osm_paths(frame.bbox_latlon(center_xz, half, 60.0))
		_log("OSM: %d célula(s) do pacote" % paths.size())
	elif usar_osm:
		var cells: Array[Vector2i] = osm.cells_for_bbox(frame.bbox_latlon(center_xz, half, 60.0))
		var _t2 := Time.get_ticks_msec()
		var r: Dictionary = await osm.ensure_osm_cells(cells)
		_log("OSM: %d/%d células (%d ms)%s" % [r.paths.size(), cells.size(), Time.get_ticks_msec() - _t2, "" if r.failed == 0 else "  ⚠ %d falharam" % r.failed])
		paths = r.paths
		falhas = r.failed

	# 3) CENA 3D (sincrono; pesado em regioes densas)
	_set_status("Construindo cena 3D…")
	await get_tree().process_frame
	Manager.engine.limpar_resultados()
	var _t1 := Time.get_ticks_msec()
	Manager.importer.generate_geo(paths, frame, hf, {"center": center_xz, "half": half})
	_log("Cena 3D gerada (%d ms)" % (Time.get_ticks_msec() - _t1))

	var bbox: Dictionary = frame.bbox_latlon(center_xz, half)
	regiao = {
		"id": "R_%d_%d_%d" % [int(center_xz.x), int(center_xz.y), int(lado)],
		"lado": lado,
		"center": center_xz, "half": half, "bbox": bbox,
		"terrain": hf, "osm_paths": paths,
	}
	regiao_fixada = false

	# 4) ANTENAS
	var _t3 := Time.get_ticks_msec()
	await _carregar_antenas()
	_log("Antenas: %d (%d ms)" % [antenas_regiao.size(), Time.get_ticks_msec() - _t3])

	var msg: String = "Região %.1f x %.1f km carregada: %d prédios, relevo %.0f–%.0f m, %d antenas." % [
		lado / 1000.0, lado / 1000.0,
		Manager.importer.obstaculos_brutos_cache.size(),
		hf.hmin, hf.hmax, antenas_regiao.size()]
	if falhas > 0:
		msg += " ⚠ %d célula(s) OSM não baixaram (offline/Overpass ocupado); tente \"Carregar aqui\" de novo." % falhas
	if usar_relevo and hf.get("flat", false):
		msg += " ⚠ sem relevo."
	_set_status(msg)
	region_loaded.emit(regiao)
	_prefetch_async(center_xz)
	return true


# Antenas

func _mk_antena(src: String, op: String, freq: float, lat: float, lon: float, alt: float, az: float, stid: String, tech: String) -> Dictionary:
	var xz: Vector2 = frame.latlon_to_xz(lat, lon)
	var gy: float = Manager.importer.terrain_height_at(xz.x, xz.y)
	var agl: float = alt if alt > 0.0 else altura_padrao_antena_m
	return {
		"id": "%s|%s|%s|%.1f|%.5f|%.5f" % [src, op, stid, freq, lat, lon],
		"src": src, "op": op, "freq": freq,
		"banda": GeoUtils.faixa_de_freq(freq),
		"tech": tech, "stid": stid if stid != "" else "-",
		"lat": lat, "lon": lon, "x": xz.x, "z": xz.y,
		"gy": gy, "agl": agl, "az": az,
	}


func _carregar_antenas() -> void:
	antenas_regiao.clear()
	if usar_antenas and not regiao.is_empty():
		var center: Vector2 = regiao.center
		var half: float = regiao.half
		var bbox: Dictionary = frame.bbox_latlon(center, half, antenas_margem_m)

		var usa_rmf: bool = fonte_antenas == FonteAntenas.RMF_API or fonte_antenas == FonteAntenas.RMF_E_ANATEL
		var usa_anatel: bool = fonte_antenas == FonteAntenas.ANATEL_CSV or fonte_antenas == FonteAntenas.RMF_E_ANATEL

		if usa_rmf:
			var llc: Vector2 = frame.xz_to_latlon(center.x, center.y)
			var rr: Dictionary = await rmf.fetch_around(llc.x, llc.y)
			if rr.ok:
				var n_rmf: int = 0
				for rec in RmfProvider.registros(rr.erbs):
					if rec.lat < bbox.south or rec.lat > bbox.north or rec.lon < bbox.west or rec.lon > bbox.east:
						continue
					var a: Dictionary = _mk_antena("RMF", rec.op, rec.freq, rec.lat, rec.lon, 0.0, -1.0, "%s/b%s" % [rec.stid, rec.banda3gpp], rec.tech)
					a["infra"] = rec.infra
					a["endereco"] = rec.endereco
					antenas_regiao.append(a)
					n_rmf += 1
				_log("RMF: %d estações no raio de 5 km (%s) → %d registros estação×banda na região" % [rr.erbs.size(), "cache" if rr.cache else "internet", n_rmf])
			else:
				_set_status("⚠ " + rmf.ultimo_erro)

		if usa_anatel and anatel.loaded:
			for rec in anatel.query_bbox(bbox):
				antenas_regiao.append(_mk_antena("Anatel", rec.op, rec.freq, rec.lat, rec.lon, rec.alt, rec.az, rec.stid, rec.tech))

		# Torres mapeadas no OSM (geralmente sem operadora/frequencia)
		var cells: Array[Vector2i] = osm.cells_for_bbox(bbox)
		var torres: Array = await osm.fetch_towers(cells)
		for t in torres:
			var la: float = t.lat
			var lo: float = t.lon
			if la < bbox.south or la > bbox.north or lo < bbox.west or lo > bbox.east:
				continue
			var tags: Dictionary = t.tags
			var op: String = GeoUtils.marca_operadora(str(tags.get("operator", "OSM (sem operadora)")))
			var h: float = 0.0
			if tags.has("height") and str(tags.height).is_valid_float():
				h = float(tags.height)
			antenas_regiao.append(_mk_antena("OSM", op, 0.0, la, lo, h, -1.0, str(t.id), ""))

	# Mantem so selecoes que ainda existem na lista
	var ids: Dictionary = {}
	for a in antenas_regiao:
		ids[a.id] = true
	for k in selecionadas.keys():
		if not ids.has(k):
			selecionadas.erase(k)

	_atualizar_marcadores()
	antennas_changed.emit()


## Recarrega so a lista de antenas (ex.: depois de importar a base Anatel).
func recarregar_antenas() -> void:
	await _carregar_antenas()
	_set_status("Antenas atualizadas: %d na região (+%d m de margem)." % [antenas_regiao.size(), int(antenas_margem_m)])


func definir_selecao(ids: Array, marcado: bool) -> void:
	for id in ids:
		if marcado:
			selecionadas[id] = true
		else:
			selecionadas.erase(id)
	_atualizar_marcadores()
	antennas_changed.emit()


func limpar_selecao() -> void:
	selecionadas.clear()
	_atualizar_marcadores()
	antennas_changed.emit()


## Chamado pelo simulador: antenas reais marcadas na tabela.
## Cada item: {pos: Vector3, freq: MHz, pot: dBm}
func antenas_para_simulacao() -> Array:
	var out: Array = []
	for a in antenas_regiao:
		if not selecionadas.has(a.id):
			continue
		var f: float = a.freq if a.freq > 0.0 else freq_padrao_mhz
		out.append({
			"pos": Vector3(a.x, a.gy + a.agl, a.z),
			"freq": f,
			"pot": potencia_padrao_dbm,
		})
	return out


## Posicao inicial para um TX novo: centro da regiao, 30 m acima do terreno.
func posicao_padrao_tx() -> Vector3:
	if regiao.is_empty():
		return Vector3(0, 30, 0)
	var c: Vector2 = regiao.center
	var gy: float = Manager.importer.terrain_height_at(c.x, c.y) if Manager.importer else 0.0
	return Vector3(c.x, gy + 30.0, c.y)


func _on_anatel_import_finished(ok: bool, msg: String) -> void:
	_set_status(("✅ " if ok else "❌ ") + msg.get_slice("\n", 0))
	print("[Anatel] ", msg)
	if ok:
		recarregar_antenas()
	settings_changed.emit()


# Marcadores 3D das antenas (MultiMesh: 1 draw call para centenas de torres)
func _atualizar_marcadores() -> void:
	if is_instance_valid(_marcadores):
		_marcadores.get_parent().remove_child(_marcadores)
		_marcadores.queue_free()
		_marcadores = null
	if antenas_regiao.is_empty() or Manager.importer == null or Manager.importer.container_cena == null:
		return

	var mm: MultiMesh = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var mesh: CylinderMesh = CylinderMesh.new()
	mesh.top_radius = 0.5
	mesh.bottom_radius = 1.0
	mesh.height = 1.0
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = mat
	mm.mesh = mesh
	mm.instance_count = antenas_regiao.size()

	for i in antenas_regiao.size():
		var a: Dictionary = antenas_regiao[i]
		var sel: bool = selecionadas.has(a.id)
		var raio: float = 2.2 if sel else 1.2
		var altura: float = maxf(float(a.agl), 8.0) + (30.0 if sel else 10.0)  # exagero visual para enxergar de longe
		var b: Basis = Basis.from_scale(Vector3(raio, altura, raio))
		mm.set_instance_transform(i, Transform3D(b, Vector3(a.x, a.gy + altura * 0.5, a.z)))
		var cor: Color = OP_CORES.get(a.op, Color(0.6, 0.6, 0.6))
		cor.a = 1.0 if sel else 0.6
		mm.set_instance_color(i, cor)

	_marcadores = MultiMeshInstance3D.new()
	_marcadores.name = "AntenasReais"
	_marcadores.multimesh = mm
	Manager.importer.container_cena.add_child(_marcadores)


func focar_antena(id: String) -> void:
	for a in antenas_regiao:
		if a.id != id:
			continue
		var cam: Camera3D = get_viewport().get_camera_3d()
		if cam == null:
			return
		var alvo: Vector3 = Vector3(a.x, a.gy + a.agl, a.z)
		cam.global_position = alvo + Vector3(0.0, 120.0, 220.0)
		cam.look_at(alvo, Vector3.UP)
		if "_pitch" in cam:
			cam.set("_pitch", cam.rotation.x)
		return


# Simulacao: fixar a regiao

## Chamado pelo botao "Simular" ANTES do simulador. Retorna false para cancelar.
func preparar_para_simular() -> bool:
	if carregando:
		_set_status("Aguarde o carregamento da região terminar…")
		return false

	# "E so apertar simular": se a camera aponta para outra regiao, carrega ela antes.
	var foco: Variant = foco_da_camera()
	if foco != null and _fora_da_regiao(Vector2(foco), 1.0):
		var alvo_sim: Vector2 = _snap(Vector2(foco))
		if pacote != null:
			alvo_sim = pacote.clamp_centro(alvo_sim, minf(tamanho_regiao_m, pacote.lado_maximo()))
		if regiao.is_empty() or alvo_sim.distance_to(Vector2(regiao.center)) >= 1.0:
			await carregar_regiao(alvo_sim)
	if regiao.is_empty():
		_set_status("⚠ Nenhuma região carregada.")
		return false

	_fixar_regiao()
	return true


func _fixar_regiao() -> void:
	regiao_fixada = true
	seguir_camera = false      # mantem o mapa de calor na tela; "Seguir camera" volta a navegar
	settings_changed.emit()

	var sel: Array = []
	for a in antenas_regiao:
		if selecionadas.has(a.id):
			sel.append({"id": a.id, "op": a.op, "freq": a.freq, "banda": a.banda, "lat": a.lat, "lon": a.lon, "agl": a.agl})

	var hf: Dictionary = regiao.terrain
	var manifesto: Dictionary = {
		"id": regiao.id,
		"salvo_em": Time.get_datetime_string_from_system(),
		"origem": {"lat": frame.lat0, "lon": frame.lon0, "elev0_m": frame.elev0},
		"centro_xz": [regiao.center.x, regiao.center.y],
		"tamanho_m": regiao.get("lado", tamanho_regiao_m),
		"pacote": (pacote.nome if pacote != null else ""),
		"bbox": regiao.bbox,
		"relevo": {"fonte": "AWS Terrain Tiles (terrarium)", "zoom": terrain.zoom, "grade": hf.res, "passo_m": hf.step, "hmin": hf.hmin, "hmax": hf.hmax, "plano": hf.get("flat", false)},
		"osm_celulas": Array(regiao.osm_paths),
		"antenas_selecionadas": sel,
		"altura_rx_m": Manager.engine.sim_config.altura_rx_relevo_m,
		"potencia_padrao_dbm": potencia_padrao_dbm,
		"freq_padrao_mhz": freq_padrao_mhz,
	}
	var dir: String = GeoUtils.cache_dir("regions")
	var f: FileAccess = FileAccess.open(dir.path_join(regiao.id + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(manifesto, "\t"))
		f.close()
	_set_status("🔒 Região %s fixada (cache em GeoCache/). Marque \"Seguir câmera\" para explorar outras áreas." % regiao.id)


# API para a UI

## Move a origem (lat/lon) e recarrega. ATENCAO: muda o quadro local (x,z) de tudo;
## TX manuais ficam onde estao em x,z locais.
func ir_para(lat: float, lon: float) -> void:
	if pacote != null:
		_log("Mudando a origem: saindo do pacote (a origem do pacote é fixa).")
		pacote = null
		_ultimo_pacote = ""
		package_changed.emit()
	frame.set_origin(lat, lon)
	frame.elev0 = NAN          # a proxima regiao redefine o zero vertical
	regiao = {}
	salvar_config()
	await carregar_regiao(Vector2.ZERO)
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam:
		cam.global_position = Vector3(0.0, 350.0, 450.0)
		cam.rotation = Vector3(deg_to_rad(-35.0), 0.0, 0.0)
		if "_pitch" in cam:
			cam.set("_pitch", cam.rotation.x)


func recarregar_aqui() -> void:
	var foco: Variant = foco_da_camera()
	var alvo: Vector2 = _snap(Vector2(foco)) if foco != null else (regiao.center if not regiao.is_empty() else Vector2.ZERO)
	await carregar_regiao(alvo)


func aplicar_tamanho_regiao(m: float) -> void:
	tamanho_regiao_m = clampf(m, 500.0, 6000.0)
	salvar_config()


# Pre-carga em segundo plano (chunks ao redor da regiao) e teste de conexao

## Baixa para o disco, em segundo plano, a faixa de `chunks_pre_carregados` chunks ao redor
## da regiao atual (relevo + celulas OSM + torres). Cancelada se outra regiao comecar a carregar.
func _prefetch_async(center: Vector2) -> void:
	if pacote != null:
		prefetch_estado = ""
		return
	if chunks_pre_carregados <= 0:
		prefetch_estado = "pré-carga desligada"
		return
	_prefetch_id += 1
	var meu: int = _prefetch_id
	var cancel: Callable = func() -> bool: return _prefetch_id != meu or carregando
	var anel: float = float(chunks_pre_carregados) * tamanho_chunk_m
	var lado: float = tamanho_regiao_m + 2.0 * anel
	prefetch_estado = "pré-carregando %.1f km ao redor…" % (lado / 1000.0)
	_log("Pré-carga: %d chunk(s) de %d m em cada direção (área %.1f x %.1f km)" % [chunks_pre_carregados, int(tamanho_chunk_m), lado / 1000.0, lado / 1000.0])

	var falhas: int = 0
	if usar_relevo:
		falhas += await terrain.prefetch(frame, center, lado, cancel)
		if cancel.call():
			return
	if usar_osm:
		var cells: Array[Vector2i] = osm.cells_for_bbox(frame.bbox_latlon(center, lado * 0.5, 0.0))
		for cell in cells:
			if cancel.call():
				return
			if not FileAccess.file_exists(osm.osm_cell_path(cell)):
				var one: Array[Vector2i] = [cell]
				var r: Dictionary = await osm.ensure_osm_cells(one)
				falhas += int(r.failed)
		if usar_antenas:
			if cancel.call():
				return
			await osm.fetch_towers(cells)
	prefetch_estado = "pré-carga concluída" if falhas == 0 else "pré-carga parcial (%d falhas)" % falhas
	_log("Pré-carga: " + prefetch_estado)


## Testa terreno (AWS), OSM (Overpass) e API RMF e escreve o resultado no log.
func testar_conexao() -> Dictionary:
	_log("— Teste de conexão —")
	var res: Dictionary = {}
	var px: float = GeoUtils.lon_to_pixel_x(frame.lon0, terrain.zoom)
	var py: float = GeoUtils.lat_to_pixel_y(frame.lat0, terrain.zoom)
	var url_t: String = terrain.URL_TEMPLATE % [terrain.zoom, int(px / 256.0), int(py / 256.0)]
	var r1: Dictionary = await http.request_bytes(url_t, HTTPClient.METHOD_GET, PackedStringArray(), "", 15.0)
	res["relevo"] = r1.ok
	_log("%s Relevo (AWS Terrain Tiles): %s" % ["✅" if r1.ok else "❌", "ok" if r1.ok else r1.error])

	var r2: Dictionary = await http.request_bytes("https://overpass-api.de/api/status", HTTPClient.METHOD_GET, PackedStringArray(), "", 15.0)
	res["osm"] = r2.ok
	_log("%s Prédios/ruas (Overpass): %s" % ["✅" if r2.ok else "❌", "ok" if r2.ok else r2.error])

	if rmf.tem_token():
		var r3: Dictionary = await rmf.testar()
		res["rmf"] = r3.ok
		_log("%s Antenas (API RMF): %s" % ["✅" if r3.ok else "❌", r3.msg])
	else:
		res["rmf"] = false
		_log("⚠ Antenas (API RMF): sem token. Gere um grátis em redesmoveisfixas.com/createapi e cole no painel 'Mapa real'.")
	conexao = res
	return res


# Pacote SAARIS Data Source (relevo + predios casados, sem rede)

## Abre um manifesto.json / .zip e passa a usar o pacote como fonte de relevo e predios.
func importar_pacote(caminho: String) -> bool:
	if carregando:
		_set_status("Aguarde o carregamento atual terminar para importar o pacote.")
		return false
	var pk = PackageProvider.new()
	if not pk.abrir(caminho):
		_set_status("❌ Pacote inválido: " + pk.erro)
		return false
	pacote = pk
	_ultimo_pacote = caminho
	# O pacote define a origem e a referencia vertical (todas as regioes usam o mesmo quadro)
	frame.set_origin(pk.lat0, pk.lon0)
	frame.elev0 = pk.elev0
	regiao = {}
	regiao_fixada = false
	selecionadas.clear()
	salvar_config()
	_log("📦 Pacote '%s' aberto: %s" % [pk.nome, pk.resumo()])
	package_changed.emit()
	settings_changed.emit()
	var ok: bool = await carregar_regiao(Vector2.ZERO)
	_posicionar_camera_no_centro()
	return ok


## Volta ao modo online (relevo e OSM baixados pelo simulador, em cache).
func sair_do_pacote() -> void:
	if pacote == null:
		return
	pacote = null
	_ultimo_pacote = ""
	salvar_config()
	_log("🌐 Voltando ao modo online (sem pacote).")
	package_changed.emit()
	settings_changed.emit()
	if not regiao.is_empty():
		frame.elev0 = NAN
		var c: Vector2 = regiao.center
		regiao = {}
		await carregar_regiao(c)


func _posicionar_camera_no_centro() -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null or regiao.is_empty():
		return
	var c: Vector2 = regiao.center
	cam.global_position = Vector3(c.x, 350.0, c.y + 450.0)
	cam.rotation = Vector3(deg_to_rad(-35.0), 0.0, 0.0)
	if "_pitch" in cam:
		cam.set("_pitch", cam.rotation.x)
