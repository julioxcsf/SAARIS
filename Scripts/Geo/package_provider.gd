extends RefCounted
## Pacote SAARIS Data Source: relevo + OSM casados, gerados pela pagina
## SAARIS_DataSource/index.html. Substitui a rede do simulador (opcional).
##
## Estrutura (pasta ou .zip):
##   manifesto.json   origem lat/lon, bbox, grade do relevo, lista de celulas OSM
##   relevo.bin       float32 little-endian, nz linhas (norte->sul) x nx colunas (oeste->leste),
##                    alturas em metros RELATIVAS a elev0 (ja no quadro y=0 do simulador)
##   osm/c_<i>_<j>.osm  celulas de 0,01 graus (mesmo formato do cache do simulador)
##
## Quadro local (igual ao geo_frame.gd): x leste, z sul, origem = manifesto.origem.

const GeoUtils = preload("res://Scripts/Geo/geo_utils.gd")

var ok: bool = false
var erro: String = ""
var dir: String = ""
var nome: String = ""
var manifesto: Dictionary = {}

var lat0: float = 0.0
var lon0: float = 0.0
var largura_m: float = 0.0
var altura_m: float = 0.0
var nx: int = 0
var nz: int = 0
var sx: float = 8.0
var sz: float = 8.0
var x0: float = 0.0
var z0: float = 0.0
var elev0: float = 0.0
var hmin: float = 0.0
var hmax: float = 0.0
var alturas: PackedFloat32Array = PackedFloat32Array()
var celulas: Dictionary = {}     # Vector2i(i,j) -> caminho absoluto do .osm
var celula_graus: float = 0.01


## Abre um manifesto.json (pasta ao lado) ou um .zip. Retorna true se OK (ver `erro`).
func abrir(caminho: String) -> bool:
	ok = false
	erro = ""
	var pasta: String = ""
	if caminho.to_lower().ends_with(".zip"):
		pasta = _extrair_zip(caminho)
		if pasta == "":
			return false
	else:
		pasta = caminho.get_base_dir()
	dir = pasta

	var mpath: String = pasta.path_join("manifesto.json")
	if caminho.to_lower().ends_with(".json"):
		mpath = caminho
	if not FileAccess.file_exists(mpath):
		erro = "manifesto.json não encontrado em " + pasta
		return false
	var m: Variant = JSON.parse_string(FileAccess.get_file_as_string(mpath))
	if typeof(m) != TYPE_DICTIONARY or (m as Dictionary).get("formato", "") != "saaris-datasource":
		erro = "Arquivo não é um manifesto do SAARIS Data Source."
		return false
	manifesto = m
	if int(manifesto.get("versao", 0)) != 1:
		erro = "Versão de pacote não suportada: %s" % str(manifesto.get("versao"))
		return false

	nome = str(manifesto.get("nome", "pacote"))
	lat0 = float(manifesto.origem.lat)
	lon0 = float(manifesto.origem.lon)
	largura_m = float(manifesto.largura_m)
	altura_m = float(manifesto.altura_m)

	var r: Dictionary = manifesto.relevo
	nx = int(r.nx)
	nz = int(r.nz)
	sx = float(r.passo_x_m)
	sz = float(r.passo_z_m)
	x0 = float(r.offset_x_m)
	z0 = float(r.offset_z_m)
	elev0 = float(r.elev0_m)
	hmin = float(r.hmin_m)
	hmax = float(r.hmax_m)
	var rel_path: String = pasta.path_join(str(r.arquivo))
	if not FileAccess.file_exists(rel_path):
		erro = "relevo.bin não encontrado."
		return false
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(rel_path)
	if bytes.size() != nx * nz * 4:
		erro = "relevo.bin com tamanho inesperado (%d bytes; esperado %d)." % [bytes.size(), nx * nz * 4]
		return false
	alturas = bytes.to_float32_array()

	var o: Dictionary = manifesto.osm
	celula_graus = float(o.get("celula_graus", 0.01))
	celulas.clear()
	for c in o.celulas:
		var p: String = pasta.path_join(str(c.arquivo))
		if FileAccess.file_exists(p):
			celulas[Vector2i(int(c.i), int(c.j))] = p
	ok = true
	return true


func resumo() -> String:
	if not ok:
		return "(nenhum pacote)"
	var falhas: int = (manifesto.osm.get("falhas", []) as Array).size()
	return "%s — %.1f × %.1f km, relevo %d×%d (%.0f…%.0f m), %d célula(s) OSM%s" % [
		nome, largura_m / 1000.0, altura_m / 1000.0, nx, nz, hmin, hmax, celulas.size(),
		"" if falhas == 0 else " ⚠ %d falharam no download" % falhas]


## Maior lado de janela que cabe no pacote.
func lado_maximo() -> float:
	return minf(largura_m, altura_m)


## Mantem a janela (centro, lado) inteiramente dentro do pacote.
func clamp_centro(centro: Vector2, lado: float) -> Vector2:
	var h: float = lado * 0.5
	var cx: float = clampf(centro.x, x0 + h, x0 + largura_m - h) if largura_m > lado else x0 + largura_m * 0.5
	var cz: float = clampf(centro.y, z0 + h, z0 + altura_m - h) if altura_m > lado else z0 + altura_m * 0.5
	return Vector2(cx, cz)


## Heightfield de uma janela quadrada, no MESMO formato de terrain_provider.build_heightfield.
func heightfield(centro: Vector2, lado: float, res: int) -> Dictionary:
	var half: float = lado * 0.5
	var step: float = lado / float(res - 1)
	var ox: float = centro.x - half
	var oz: float = centro.y - half
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(res * res)
	var hmn: float = INF
	var hmx: float = -INF
	for iz in res:
		var fz: float = clampf((oz + iz * step - z0) / sz, 0.0, float(nz - 1))
		var j0: int = mini(int(floor(fz)), nz - 2)
		var wz: float = fz - float(j0)
		for ix in res:
			var fx: float = clampf((ox + ix * step - x0) / sx, 0.0, float(nx - 1))
			var i0: int = mini(int(floor(fx)), nx - 2)
			var wx: float = fx - float(i0)
			var a: float = alturas[j0 * nx + i0]
			var b: float = alturas[j0 * nx + i0 + 1]
			var c: float = alturas[(j0 + 1) * nx + i0]
			var d: float = alturas[(j0 + 1) * nx + i0 + 1]
			var h: float = lerpf(lerpf(a, b, wx), lerpf(c, d, wx), wz)
			out[iz * res + ix] = h
			if h < hmn: hmn = h
			if h > hmx: hmx = h
	return {
		"ok": true, "heights": out, "res": res, "step": step,
		"offset": Vector2(ox, oz), "size": Vector2(lado, lado),
		"hmin": hmn, "hmax": hmx, "error": "",
	}


## Arquivos .osm do pacote que cobrem uma caixa lat/lon {south,north,west,east}.
func osm_paths(bbox: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var i0: int = int(floor(float(bbox.south) / celula_graus))
	var i1: int = int(floor(float(bbox.north) / celula_graus))
	var j0: int = int(floor(float(bbox.west) / celula_graus))
	var j1: int = int(floor(float(bbox.east) / celula_graus))
	for i in range(i0, i1 + 1):
		for j in range(j0, j1 + 1):
			var k: Vector2i = Vector2i(i, j)
			if celulas.has(k):
				out.append(celulas[k])
	return out


## Extrai o .zip para GeoCache/pacotes/<raiz>/ e devolve a pasta (ou "" em caso de erro).
func _extrair_zip(zip_path: String) -> String:
	var zr: ZIPReader = ZIPReader.new()
	if zr.open(zip_path) != OK:
		erro = "Não consegui abrir o .zip."
		return ""
	var arquivos: PackedStringArray = zr.get_files()
	var raiz: String = ""
	for f in arquivos:
		if f.ends_with("manifesto.json"):
			raiz = f.get_base_dir()
			break
	if not arquivos.has(raiz.path_join("manifesto.json") if raiz != "" else "manifesto.json"):
		zr.close()
		erro = "O .zip não contém manifesto.json."
		return ""
	var nome_pasta: String = raiz.get_file() if raiz != "" else zip_path.get_file().get_basename()
	var destino: String = GeoUtils.cache_dir("pacotes/" + nome_pasta)
	for f in arquivos:
		if f.ends_with("/"):
			continue
		if raiz != "" and not f.begins_with(raiz + "/"):
			continue
		var rel: String = f.substr(raiz.length() + 1) if raiz != "" else f
		var alvo: String = destino.path_join(rel)
		DirAccess.make_dir_recursive_absolute(alvo.get_base_dir())
		var fa: FileAccess = FileAccess.open(alvo, FileAccess.WRITE)
		if fa == null:
			zr.close()
			erro = "Não consegui gravar " + alvo
			return ""
		fa.store_buffer(zr.read_file(f))
		fa.close()
	zr.close()
	return destino
