extends Node
## OpenStreetMap via Overpass API (sem chave). Trabalha em CELULAS fixas de
## 0,01 graus (~1,1 km): cada celula e baixada uma unica vez e guardada em
## GeoCache/osm/. Regioes que se sobrepoem reaproveitam as mesmas celulas.

const GeoUtils = preload("res://Scripts/Geo/geo_utils.gd")

const CELL_DEG := 0.01
const ENDPOINTS: Array[String] = [
	"https://overpass-api.de/api/interpreter",
	"https://overpass.kumi.systems/api/interpreter",
]

signal status(msg: String)

var http: Node = null   # GeoHttp
var _endpoint_idx: int = 0


# Celulas

func cells_for_bbox(bbox: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var i0: int = int(floor(float(bbox.south) / CELL_DEG))
	var i1: int = int(floor(float(bbox.north) / CELL_DEG))
	var j0: int = int(floor(float(bbox.west) / CELL_DEG))
	var j1: int = int(floor(float(bbox.east) / CELL_DEG))
	for i in range(i0, i1 + 1):
		for j in range(j0, j1 + 1):
			out.append(Vector2i(i, j))
	return out


func _cell_bbox_str(cell: Vector2i) -> String:
	var s: float = float(cell.x) * CELL_DEG
	var w: float = float(cell.y) * CELL_DEG
	return "%.5f,%.5f,%.5f,%.5f" % [s, w, s + CELL_DEG, w + CELL_DEG]


func osm_cell_path(cell: Vector2i) -> String:
	return GeoUtils.cache_dir("osm").path_join("c_%d_%d.osm" % [cell.x, cell.y])


func towers_cell_path(cell: Vector2i) -> String:
	return GeoUtils.cache_dir("osm").path_join("t_%d_%d.json" % [cell.x, cell.y])


# Download com fallback entre servidores

func _overpass(query: String) -> Dictionary:
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/x-www-form-urlencoded"])
	var body: String = "data=" + query.uri_encode()
	var last_err: String = ""
	for attempt in range(ENDPOINTS.size() * 2):
		var url: String = ENDPOINTS[(_endpoint_idx + attempt) % ENDPOINTS.size()]
		var r: Dictionary = await http.request_bytes(url, HTTPClient.METHOD_POST, headers, body, 120.0)
		if r.ok:
			_endpoint_idx = (_endpoint_idx + attempt) % ENDPOINTS.size()
			return r
		last_err = r.error
		# 429 / 504 = servidor ocupado: espera um pouco e tenta o outro
		await get_tree().create_timer(2.0 + attempt).timeout
	return {"ok": false, "error": last_err, "body": PackedByteArray()}


## Garante o arquivo .osm de cada celula. Retorna {ok, paths, failed}
func ensure_osm_cells(cells: Array[Vector2i]) -> Dictionary:
	var paths: PackedStringArray = PackedStringArray()
	var failed: int = 0
	var idx: int = 0
	for cell in cells:
		idx += 1
		var path: String = osm_cell_path(cell)
		if FileAccess.file_exists(path):
			paths.append(path)
			continue

		status.emit("OSM: baixando célula %d/%d (Overpass)…" % [idx, cells.size()])
		var bb: String = _cell_bbox_str(cell)
		var q: String = """[out:xml][timeout:90];
(
  way["building"](%s);
  relation["building"](%s);
  way["highway"]["highway"!~"footway|path|steps|cycleway|pedestrian|corridor|track|bridleway"](%s);
);
(._;>;);
out body;""" % [bb, bb, bb]

		var r: Dictionary = await _overpass(q)
		if not r.ok:
			failed += 1
			push_warning("[OSM] Falha na célula %s: %s" % [str(cell), r.error])
			continue

		var txt: String = (r.body as PackedByteArray).get_string_from_utf8()
		var tail: String = txt.substr(maxi(0, txt.length() - 64)).strip_edges()
		if not txt.contains("<osm") or not tail.ends_with("</osm>") or txt.contains("runtime error"):
			failed += 1
			push_warning("[OSM] Resposta incompleta na célula %s (servidor sobrecarregado?)." % str(cell))
			continue

		var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_string(txt)
			f.close()
			paths.append(path)
		else:
			failed += 1

	return {"ok": failed == 0, "paths": paths, "failed": failed}


## Torres de comunicacao mapeadas no OSM (nem sempre tem operadora/frequencia).
## Retorna Array de Dictionary {id, lat, lon, tags}
func fetch_towers(cells: Array[Vector2i]) -> Array:
	var out: Array = []
	for cell in cells:
		var path: String = towers_cell_path(cell)
		var json_txt: String = ""
		if FileAccess.file_exists(path):
			json_txt = FileAccess.get_file_as_string(path)
		else:
			status.emit("OSM: procurando torres de telecom…")
			var bb: String = _cell_bbox_str(cell)
			var q: String = """[out:json][timeout:60];
(
  node["man_made"="mast"]["tower:type"="communication"](%s);
  node["man_made"="tower"]["tower:type"="communication"](%s);
  node["man_made"="communications_tower"](%s);
  node["communication:mobile_phone"="yes"](%s);
);
out body;""" % [bb, bb, bb, bb]
			var r: Dictionary = await _overpass(q)
			if not r.ok:
				break   # offline/Overpass ocupado: nao insiste nas demais celulas (torres sao opcionais)
			json_txt = (r.body as PackedByteArray).get_string_from_utf8()
			if not json_txt.contains("\"elements\""):
				continue
			var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
			if f:
				f.store_string(json_txt)
				f.close()

		var parsed: Variant = JSON.parse_string(json_txt)
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		var elems: Array = (parsed as Dictionary).get("elements", [])
		for e in elems:
			var ed: Dictionary = e
			if ed.has("lat") and ed.has("lon"):
				out.append({
					"id": str(ed.get("id", 0)),
					"lat": float(ed.lat),
					"lon": float(ed.lon),
					"tags": ed.get("tags", {}),
				})
	return out
