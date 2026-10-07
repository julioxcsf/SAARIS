extends Node
## Estacoes radio-base via API RMF (Redes Moveis e Fixas - dados do Mosaico/Anatel).
## Docs: https://redesmoveisfixas.com/createapi   (token Bearer gratuito, vale 90 dias)
##
## GET https://api.redesmoveisfixas.com/api/estacoes?lat=&lon=&limite=&offset=
##   - raio FIXO de 5 km em torno do ponto, ordenado por distancia
##   - cota: 500 consultas/dia (20/min) -> TUDO e guardado em disco (GeoCache/rmf/)
##   - resposta: {status, dados:{tem_mais, erbs:[{id, operadora, tecnologias[], bandas[],
##                coordenadas{lat,lon}, endereco{...}, estacao{infraestrutura,...}}]}}
## A API NAO informa altura da torre, potencia nem azimute: usamos os padroes do painel.

const GeoUtils = preload("res://Scripts/Geo/geo_utils.gd")

const BASE_URL := "https://api.redesmoveisfixas.com"
const PAGE := 1000
const MAX_PAGES := 6            # ate 6000 estacoes por consulta (5 km em cidade grande)
const CACHE_DIAS := 30
const SNAP_DEG := 0.01          # consultas agrupadas em ~1,1 km (reaproveita cache)

signal status(msg: String)

var http: Node = null
var token: String = ""
var ultimo_erro: String = ""

## Banda 3GPP (LTE "3" / NR "n78" -> sempre como numero em texto) -> frequencia central de DL (MHz).
## Mapeia para as faixas usadas no Brasil. Bandas desconhecidas ficam sem frequencia (0).
const BANDA_MHZ := {
	"1": 2140.0, "2": 1960.0, "3": 1840.0, "5": 880.0, "7": 2650.0, "8": 950.0, "20": 800.0,
	"28": 780.0, "38": 2600.0, "40": 2350.0, "41": 2600.0,
	"77": 3700.0, "78": 3500.0, "79": 4700.0,
	"257": 28000.0, "258": 26000.0, "260": 39000.0, "261": 28000.0,
}


func tem_token() -> bool:
	return token.strip_edges() != ""


func _cache_path(lat: float, lon: float) -> String:
	var i: int = int(round(lat / SNAP_DEG))
	var j: int = int(round(lon / SNAP_DEG))
	return GeoUtils.cache_dir("rmf").path_join("e_%d_%d.json" % [i, j])


func _snap_center(lat: float, lon: float) -> Vector2:
	return Vector2(round(lat / SNAP_DEG) * SNAP_DEG, round(lon / SNAP_DEG) * SNAP_DEG)


## Estacoes num raio de 5 km (do ponto agrupado). Retorna
## {ok, erbs: Array(Dictionary crus da API), error, cache: bool}
func fetch_around(lat: float, lon: float) -> Dictionary:
	var c: Vector2 = _snap_center(lat, lon)
	var path: String = _cache_path(c.x, c.y)

	if FileAccess.file_exists(path):
		var idade_d: float = (Time.get_unix_time_from_system() - float(FileAccess.get_modified_time(path))) / 86400.0
		if idade_d <= CACHE_DIAS:
			var cached: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if typeof(cached) == TYPE_ARRAY:
				return {"ok": true, "erbs": cached, "error": "", "cache": true}

	if not tem_token():
		ultimo_erro = "Sem token da API RMF (gere um em redesmoveisfixas.com/createapi e cole no painel)."
		return {"ok": false, "erbs": [], "error": ultimo_erro, "cache": false}

	var todas: Array = []
	var offset: int = 0
	for pagina in MAX_PAGES:
		status.emit("RMF: baixando estações (página %d)…" % (pagina + 1))
		var url: String = "%s/api/estacoes?lat=%.6f&lon=%.6f&limite=%d&offset=%d" % [BASE_URL, c.x, c.y, PAGE, offset]
		var r: Dictionary = await http.request_bytes(url, HTTPClient.METHOD_GET,
			PackedStringArray(["Authorization: Bearer " + token.strip_edges(), "Accept: application/json"]), "", 40.0)
		if not r.ok:
			ultimo_erro = _erro_http(int(r.code), str(r.error))
			return {"ok": false, "erbs": todas, "error": ultimo_erro, "cache": false}

		var parsed: Variant = JSON.parse_string((r.body as PackedByteArray).get_string_from_utf8())
		if typeof(parsed) != TYPE_DICTIONARY or not (parsed as Dictionary).has("dados"):
			ultimo_erro = "Resposta inesperada da API RMF (sem campo 'dados')."
			return {"ok": false, "erbs": todas, "error": ultimo_erro, "cache": false}
		var dados: Dictionary = (parsed as Dictionary).dados
		todas.append_array(dados.get("erbs", []))
		if not bool(dados.get("tem_mais", false)):
			break
		offset += PAGE

	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(todas))
		f.close()
	return {"ok": true, "erbs": todas, "error": "", "cache": false}


func _erro_http(code: int, base: String) -> String:
	match code:
		400: return "RMF: parâmetros inválidos (400)."
		403: return "RMF: token inválido ou expirado (403). Gere outro em redesmoveisfixas.com/createapi."
		429: return "RMF: cota diária/por minuto excedida (429). O que já foi baixado fica em cache."
		503: return "RMF: serviço temporariamente indisponível (503)."
		0: return "RMF: sem conexão (%s)." % base
	return "RMF: erro HTTP %d." % code


## Teste rapido de conexao/token (1 consulta de 1 estacao; NAO usa cache).
func testar() -> Dictionary:
	if not tem_token():
		return {"ok": false, "msg": "sem token"}
	var url: String = "%s/api/estacoes?lat=-22.8558&lon=-43.2256&limite=1" % BASE_URL
	var r: Dictionary = await http.request_bytes(url, HTTPClient.METHOD_GET,
		PackedStringArray(["Authorization: Bearer " + token.strip_edges()]), "", 20.0)
	if r.ok:
		return {"ok": true, "msg": "token válido"}
	return {"ok": false, "msg": _erro_http(int(r.code), str(r.error))}


## Converte "erbs" da API em registros planos {stid, op, freq, banda_3gpp, tech, lat, lon, infra, endereco}.
## Uma linha por (estacao, banda). Estacoes sem banda conhecida geram 1 linha com freq 0.
static func registros(erbs: Array) -> Array:
	var out: Array = []
	for e in erbs:
		var ed: Dictionary = e
		var co: Variant = ed.get("coordenadas", null)
		if typeof(co) != TYPE_DICTIONARY:
			continue
		var lat: float = float((co as Dictionary).get("lat", 0.0))
		var lon: float = float((co as Dictionary).get("lon", 0.0))
		if lat == 0.0 and lon == 0.0:
			continue
		var op: String = GeoUtils.marca_operadora(str(ed.get("operadora", "")))
		var techs: Array = ed.get("tecnologias", [])
		var tech_txt: String = "/".join(PackedStringArray(techs.map(func(t): return str(t))))
		var infra: String = ""
		var est: Variant = ed.get("estacao", null)
		if typeof(est) == TYPE_DICTIONARY:
			infra = str((est as Dictionary).get("infraestrutura", ""))
		var end_txt: String = ""
		var en: Variant = ed.get("endereco", null)
		if typeof(en) == TYPE_DICTIONARY:
			end_txt = str((en as Dictionary).get("logradouro", ""))
		var bandas: Array = ed.get("bandas", [])
		if bandas.is_empty():
			bandas = [""]
		var vistas: Dictionary = {}
		for b in bandas:
			var bs: String = str(b).to_lower().trim_prefix("n").strip_edges()
			if vistas.has(bs):
				continue
			vistas[bs] = true
			out.append({
				"stid": str(ed.get("id", "")),
				"op": op,
				"freq": float(BANDA_MHZ.get(bs, 0.0)),
				"banda3gpp": bs,
				"tech": ("NR" if bs in ["77", "78", "79", "257", "258", "260", "261"] else tech_txt),
				"lat": lat, "lon": lon,
				"infra": infra, "endereco": end_txt,
			})
	return out
