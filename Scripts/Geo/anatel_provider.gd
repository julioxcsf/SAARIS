extends Node
## Base de estacoes da Anatel (dados abertos) -> indice compacto em disco.
##
## O arquivo publico "estacoes_licenciadas.zip" e grande (centenas de MB) e pode
## ter nomes de coluna diferentes entre versoes. Por isso:
##   1) a importacao roda em uma Thread e detecta as colunas pelo CABECALHO
##      (latitude, longitude, prestadora, frequencia, ...);
##   2) o resultado e salvo em GeoCache/anatel/index_v1.bin (arrays compactos),
##      e as consultas por regiao sao instantaneas depois disso.
## O mesmo leitor serve para QUALQUER csv com colunas de latitude/longitude.

const GeoUtils = preload("res://Scripts/Geo/geo_utils.gd")

const DEFAULT_URL := "https://www.anatel.gov.br/dadosabertos/paineis_de_dados/outorga_e_licenciamento/estacoes_licenciadas.zip"
const INDEX_VERSION := 1

signal import_progress(msg: String)
signal import_finished(ok: bool, msg: String)

var index: Dictionary = {}        # arrays compactos (ver _empty_index)
var loaded: bool = false
var somente_telefonia_movel: bool = true
var _thread: Thread = null


func index_path() -> String:
	return GeoUtils.cache_dir("anatel").path_join("index_v%d.bin" % INDEX_VERSION)


func raw_dir() -> String:
	return GeoUtils.cache_dir("anatel/raw")


func has_index() -> bool:
	return FileAccess.file_exists(index_path())


func _empty_index() -> Dictionary:
	return {
		"version": INDEX_VERSION,
		"fonte": "",
		"importado_em": "",
		"ops": PackedStringArray(),     # nomes (marca) unicos
		"techs": PackedStringArray(),   # tecnologias unicas
		"lat": PackedFloat64Array(),
		"lon": PackedFloat64Array(),
		"freq": PackedFloat32Array(),   # MHz (0 = desconhecida)
		"op": PackedInt32Array(),
		"tech": PackedInt32Array(),
		"alt": PackedFloat32Array(),    # altura da antena (m); -1 = desconhecida
		"az": PackedFloat32Array(),     # azimute (graus); -1 = desconhecido
		"stid": PackedStringArray(),
	}


func load_index() -> bool:
	if loaded:
		return true
	if not has_index():
		return false
	var f: FileAccess = FileAccess.open(index_path(), FileAccess.READ)
	if f == null:
		return false
	var v: Variant = f.get_var(false)
	f.close()
	if typeof(v) != TYPE_DICTIONARY or int((v as Dictionary).get("version", 0)) != INDEX_VERSION:
		return false
	index = v
	loaded = true
	return true


func count() -> int:
	if not loaded:
		return 0
	return (index["lat"] as PackedFloat64Array).size()


func resumo() -> String:
	if not loaded:
		return "Base Anatel: não carregada"
	return "Base Anatel: %d registros (%s)" % [count(), str(index.get("importado_em", "?"))]


## Consulta por caixa lat/lon. Retorna Array de Dictionary (campos brutos).
func query_bbox(bbox: Dictionary) -> Array:
	var out: Array = []
	if not loaded:
		return out
	var lat: PackedFloat64Array = index["lat"]
	var lon: PackedFloat64Array = index["lon"]
	var freq: PackedFloat32Array = index["freq"]
	var op: PackedInt32Array = index["op"]
	var tech: PackedInt32Array = index["tech"]
	var alt: PackedFloat32Array = index["alt"]
	var az: PackedFloat32Array = index["az"]
	var stid: PackedStringArray = index["stid"]
	var ops: PackedStringArray = index["ops"]
	var techs: PackedStringArray = index["techs"]

	var s: float = bbox.south
	var n: float = bbox.north
	var w: float = bbox.west
	var e: float = bbox.east
	for i in lat.size():
		var la: float = lat[i]
		if la < s or la > n:
			continue
		var lo: float = lon[i]
		if lo < w or lo > e:
			continue
		out.append({
			"lat": la, "lon": lo, "freq": freq[i],
			"op": ops[op[i]], "tech": techs[tech[i]] if tech[i] >= 0 else "",
			"alt": alt[i], "az": az[i], "stid": stid[i],
		})
	return out


# IMPORTACAO (Thread)

func import_async(path: String) -> void:
	if _thread != null and _thread.is_alive():
		import_progress.emit("Já existe uma importação em andamento.")
		return
	if _thread != null:
		_thread.wait_to_finish()
	_thread = Thread.new()
	_thread.start(_import_worker.bind(path, somente_telefonia_movel))


func _exit_tree() -> void:
	if _thread != null:
		_thread.wait_to_finish()


func _progress(msg: String) -> void:
	import_progress.emit.call_deferred(msg)


func _finish(ok: bool, msg: String) -> void:
	_finish_main.call_deferred(ok, msg)


func _finish_main(ok: bool, msg: String) -> void:
	if ok:
		loaded = false
		load_index()
	import_finished.emit(ok, msg)


func _import_worker(path: String, so_smp: bool) -> void:
	var csv_paths: PackedStringArray = PackedStringArray()

	if path.get_extension().to_lower() == "zip":
		_progress("Abrindo ZIP…")
		var zr: ZIPReader = ZIPReader.new()
		if zr.open(path) != OK:
			_finish(false, "Não consegui abrir o ZIP: %s" % path)
			return
		for name in zr.get_files():
			var ext: String = name.get_extension().to_lower()
			if ext != "csv" and ext != "txt":
				continue
			_progress("Extraindo %s (pode demorar)…" % name)
			var data: PackedByteArray = zr.read_file(name)
			var out_path: String = raw_dir().path_join(name.get_file())
			var fw: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
			if fw == null:
				zr.close()
				_finish(false, "Sem permissão para gravar em %s" % out_path)
				return
			fw.store_buffer(data)
			fw.close()
			data = PackedByteArray()
			csv_paths.append(out_path)
		zr.close()
	else:
		csv_paths.append(path)

	if csv_paths.is_empty():
		_finish(false, "Nenhum CSV encontrado em %s" % path)
		return

	var idx: Dictionary = _empty_index()
	idx["fonte"] = path.get_file()
	idx["importado_em"] = Time.get_datetime_string_from_system()
	var vistos: Dictionary = {}
	var ops_map: Dictionary = {}
	var techs_map: Dictionary = {}
	var ops_arr: PackedStringArray = PackedStringArray()
	var techs_arr: PackedStringArray = PackedStringArray()

	var lat_a: PackedFloat64Array = PackedFloat64Array()
	var lon_a: PackedFloat64Array = PackedFloat64Array()
	var freq_a: PackedFloat32Array = PackedFloat32Array()
	var op_a: PackedInt32Array = PackedInt32Array()
	var tech_a: PackedInt32Array = PackedInt32Array()
	var alt_a: PackedFloat32Array = PackedFloat32Array()
	var az_a: PackedFloat32Array = PackedFloat32Array()
	var stid_a: PackedStringArray = PackedStringArray()

	var log_cols: String = ""
	var total_lidas: int = 0
	var total_ok: int = 0

	for csv in csv_paths:
		var f: FileAccess = FileAccess.open(csv, FileAccess.READ)
		if f == null:
			continue
		# Detecta o delimitador pela 1a linha
		var first: String = f.get_line()
		var delim: String = ";"
		if first.count(";") < first.count(",") and first.count(";") < first.count("\t"):
			delim = "," if first.count(",") >= first.count("\t") else "\t"
		f.seek(0)
		var header: PackedStringArray = f.get_csv_line(delim)
		var cols: Dictionary = _detect_columns(header)
		log_cols += "%s -> %s\n" % [csv.get_file(), JSON.stringify(cols)]

		if cols.lat < 0 or cols.lon < 0:
			_progress("%s: sem colunas de latitude/longitude, ignorado." % csv.get_file())
			f.close()
			continue

		var usa_filtro_servico: bool = so_smp and cols.servico >= 0
		var ncols: int = header.size()

		while not f.eof_reached():
			var row: PackedStringArray = f.get_csv_line(delim)
			if row.size() < ncols - 2:
				continue
			total_lidas += 1
			if total_lidas % 50000 == 0:
				_progress("Lendo… %d linhas, %d estações válidas" % [total_lidas, total_ok])

			if usa_filtro_servico:
				var sv: String = GeoUtils.norm_header(row[cols.servico])
				if not (sv.contains("smp") or sv.contains("movelpessoal") or sv.contains("telefoniamovel")):
					continue

			var la: float = GeoUtils.parse_coord(row[cols.lat])
			var lo: float = GeoUtils.parse_coord(row[cols.lon])
			if is_nan(la) or is_nan(lo) or absf(la) > 90.0 or absf(lo) > 180.0 or (la == 0.0 and lo == 0.0):
				continue

			var freq: float = 0.0
			if cols.freq >= 0:
				var fv: float = GeoUtils.parse_num(row[cols.freq])
				if not is_nan(fv):
					# Heuristica de unidade: kHz / Hz -> MHz
					if fv > 1.0e7:
						fv = fv / 1.0e6
					elif fv > 20000.0:
						fv = fv / 1000.0
					freq = fv

			var op_raw: String = row[cols.op] if cols.op >= 0 else "Desconhecida"
			var marca: String = GeoUtils.marca_operadora(op_raw)
			var stid: String = row[cols.stid].strip_edges() if cols.stid >= 0 else ""
			var key: String = "%s|%.1f|%.5f|%.5f|%s" % [stid, freq, la, lo, marca]
			if vistos.has(key):
				continue
			vistos[key] = true

			if not ops_map.has(marca):
				ops_map[marca] = ops_arr.size()
				ops_arr.append(marca)
			var tech_name: String = row[cols.tech].strip_edges() if cols.tech >= 0 else ""
			var tech_i: int = -1
			if tech_name != "":
				if not techs_map.has(tech_name):
					techs_map[tech_name] = techs_arr.size()
					techs_arr.append(tech_name)
				tech_i = techs_map[tech_name]

			var altv: float = -1.0
			if cols.alt >= 0:
				var av: float = GeoUtils.parse_num(row[cols.alt])
				if not is_nan(av) and av > 0.0 and av < 400.0:
					altv = av
			var azv: float = -1.0
			if cols.az >= 0:
				var zv: float = GeoUtils.parse_num(row[cols.az])
				if not is_nan(zv) and zv >= 0.0 and zv <= 360.0:
					azv = zv

			lat_a.append(la)
			lon_a.append(lo)
			freq_a.append(freq)
			op_a.append(ops_map[marca])
			tech_a.append(tech_i)
			alt_a.append(altv)
			az_a.append(azv)
			stid_a.append(stid)
			total_ok += 1
		f.close()

	if total_ok == 0:
		_finish(false, "Nenhum registro válido. Colunas detectadas:\n%s\nSe os nomes forem diferentes, me envie a 1ª linha do CSV." % log_cols)
		return

	idx["ops"] = ops_arr
	idx["techs"] = techs_arr
	idx["lat"] = lat_a
	idx["lon"] = lon_a
	idx["freq"] = freq_a
	idx["op"] = op_a
	idx["tech"] = tech_a
	idx["alt"] = alt_a
	idx["az"] = az_a
	idx["stid"] = stid_a

	var fo: FileAccess = FileAccess.open(index_path(), FileAccess.WRITE)
	if fo == null:
		_finish(false, "Não consegui gravar o índice em %s" % index_path())
		return
	fo.store_var(idx)
	fo.close()
	_finish(true, "Importação concluída: %d estações/frequências (de %d linhas).\nColunas:\n%s" % [total_ok, total_lidas, log_cols])


## Detecta colunas pelo cabecalho (tolerante a acentos, maiusculas e variacoes).
func _detect_columns(header: PackedStringArray) -> Dictionary:
	var cols: Dictionary = {"lat": -1, "lon": -1, "op": -1, "freq": -1, "tech": -1, "alt": -1, "az": -1, "stid": -1, "servico": -1}
	var norm: PackedStringArray = PackedStringArray()
	for h in header:
		norm.append(GeoUtils.norm_header(h))

	for i in norm.size():
		var h: String = norm[i]
		if cols.lat < 0 and (h == "lat" or h.contains("latitude")):
			cols.lat = i
		elif cols.lon < 0 and (h == "lon" or h == "long" or h.contains("longitude")):
			cols.lon = i
		elif cols.servico < 0 and (h == "servico" or h == "codservico" or h.contains("nomeservico") or h.contains("tiposervico")):
			cols.servico = i
		elif cols.alt < 0 and h.contains("altura") and (h.contains("antena") or h.contains("torre")):
			cols.alt = i
		elif cols.az < 0 and h.contains("azimute"):
			cols.az = i
		elif cols.tech < 0 and (h.contains("tecnologia") or h == "tech"):
			cols.tech = i
		elif cols.stid < 0 and (h.contains("numestacao") or h.contains("numerodaestacao") or h.contains("idestacao") or h == "estacao" or h.contains("numeroestacao")):
			cols.stid = i

	# Operadora: preferencia por nomes mais especificos
	for pref in ["nomeentidade", "prestadora", "operadora", "entidade", "razaosocial", "nomefantasia"]:
		for i in norm.size():
			if norm[i].contains(pref):
				cols.op = i
				break
		if cols.op >= 0:
			break

	# Frequencia: prefere TX
	for i in norm.size():
		var h: String = norm[i]
		if h.contains("freq") and (h.contains("tx") or h.contains("transm")):
			cols.freq = i
			break
	if cols.freq < 0:
		for i in norm.size():
			if norm[i].contains("freq"):
				cols.freq = i
				break
	return cols
