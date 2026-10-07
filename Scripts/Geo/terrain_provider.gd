extends Node
## Relevo: baixa tiles "Terrarium" (AWS Open Data, SEM chave de API), guarda em
## disco e converte para uma grade de alturas (heightfield) alinhada ao quadro
## local do SAARIS.
##
## Codificacao Terrarium:  elevacao_m = R*256 + G + B/256 - 32768
## Fonte dos dados: SRTM/Copernicus/etc. (~30 m). Resolucao real ~30 m, mesmo
## que o zoom seja maior; o zoom 14 (~9 m/pixel no Rio) so suaviza a amostragem.

const GeoUtils = preload("res://Scripts/Geo/geo_utils.gd")

const URL_TEMPLATE := "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/%d/%d/%d.png"
const TILE_PX := 256

signal status(msg: String)

var http: Node = null            # GeoHttp
var zoom: int = 14
var _tiles: Dictionary = {}      # "z/x/y" -> PackedFloat32Array(256*256)
var _tiles_order: Array = []     # LRU simples
const MAX_TILES_RAM := 64


func _tile_path(z: int, x: int, y: int) -> String:
	return GeoUtils.cache_dir("terrain/%d/%d" % [z, x]).path_join("%d.png" % y)


## Garante que o tile esta em RAM (baixando se preciso). Retorna true se OK.
func _load_tile(z: int, x: int, y: int) -> bool:
	var key: String = "%d/%d/%d" % [z, x, y]
	if _tiles.has(key):
		return true

	var path: String = _tile_path(z, x, y)
	var bytes: PackedByteArray = PackedByteArray()
	if FileAccess.file_exists(path):
		bytes = FileAccess.get_file_as_bytes(path)

	if bytes.is_empty():
		var r: Dictionary = await http.request_bytes(URL_TEMPLATE % [z, x, y])
		if not r.ok:
			push_warning("[Terrain] Falha ao baixar tile %s: %s" % [key, r.error])
			return false
		bytes = r.body
		var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_buffer(bytes)
			f.close()

	var img: Image = Image.new()
	if img.load_png_from_buffer(bytes) != OK or img.get_width() != TILE_PX or img.get_height() != TILE_PX:
		push_warning("[Terrain] Tile inválido (%s); removendo do cache." % key)
		DirAccess.remove_absolute(path)
		return false

	img.convert(Image.FORMAT_RGB8)
	var d: PackedByteArray = img.get_data()
	var n: int = TILE_PX * TILE_PX
	var elev: PackedFloat32Array = PackedFloat32Array()
	elev.resize(n)
	for i in n:
		elev[i] = float(d[i * 3]) * 256.0 + float(d[i * 3 + 1]) + float(d[i * 3 + 2]) / 256.0 - 32768.0

	_tiles[key] = elev
	_tiles_order.append(key)
	while _tiles_order.size() > MAX_TILES_RAM:
		var old: String = _tiles_order.pop_front()
		_tiles.erase(old)
	return true


## Constroi o heightfield de um quadrado local.
##   frame     : GeoFrame
##   center_xz : centro da regiao (m, quadro local)
##   size_m    : aresta (m)
##   res       : no de vertices por lado (grade res x res; passo = size/(res-1))
## Retorna {ok, heights(PackedFloat32Array, ja relativas a frame.elev0), res, step,
##          offset(Vector2: canto x,z minimo), size(Vector2), hmin, hmax, error}
func build_heightfield(frame, center_xz: Vector2, size_m: float, res: int) -> Dictionary:
	var half: float = size_m * 0.5
	var x0: float = center_xz.x - half
	var z0: float = center_xz.y - half
	var step: float = size_m / float(res - 1)

	# Faixa de pixels globais necessaria
	var ll_nw: Vector2 = frame.xz_to_latlon(x0, z0)
	var ll_se: Vector2 = frame.xz_to_latlon(x0 + size_m, z0 + size_m)
	var gx_min: float = GeoUtils.lon_to_pixel_x(ll_nw.y, zoom) - 2.0
	var gx_max: float = GeoUtils.lon_to_pixel_x(ll_se.y, zoom) + 2.0
	var gy_min: float = GeoUtils.lat_to_pixel_y(ll_nw.x, zoom) - 2.0
	var gy_max: float = GeoUtils.lat_to_pixel_y(ll_se.x, zoom) + 2.0
	var tx_min: int = int(floor(gx_min / TILE_PX))
	var tx_max: int = int(floor(gx_max / TILE_PX))
	var ty_min: int = int(floor(gy_min / TILE_PX))
	var ty_max: int = int(floor(gy_max / TILE_PX))
	var ncols: int = tx_max - tx_min + 1

	var grid: Array = []
	var total: int = (tx_max - tx_min + 1) * (ty_max - ty_min + 1)
	var done: int = 0
	for ty in range(ty_min, ty_max + 1):
		for tx in range(tx_min, tx_max + 1):
			status.emit("Relevo: tile %d/%d…" % [done + 1, total])
			var ok: bool = await _load_tile(zoom, tx, ty)
			if not ok:
				return {"ok": false, "error": "Não foi possível obter o tile de relevo %d/%d/%d (sem internet?)." % [zoom, tx, ty]}
			grid.append(_tiles["%d/%d/%d" % [zoom, tx, ty]])
			done += 1

	# Coordenadas de pixel por coluna/linha (lon so depende de x; lat so de z)
	var px_col: PackedFloat32Array = PackedFloat32Array()
	px_col.resize(res)
	var py_row: PackedFloat32Array = PackedFloat32Array()
	py_row.resize(res)
	for i in res:
		var ll: Vector2 = frame.xz_to_latlon(x0 + i * step, z0 + i * step)
		px_col[i] = GeoUtils.lon_to_pixel_x(ll.y, zoom) - 0.5
		py_row[i] = GeoUtils.lat_to_pixel_y(ll.x, zoom) - 0.5

	var max_gx: int = (tx_max + 1) * TILE_PX - 1
	var max_gy: int = (ty_max + 1) * TILE_PX - 1
	var min_gx: int = tx_min * TILE_PX
	var min_gy: int = ty_min * TILE_PX

	var heights: PackedFloat32Array = PackedFloat32Array()
	heights.resize(res * res)

	for iz in res:
		var fy: float = py_row[iz]
		var iy0: int = int(floor(fy))
		var wy: float = fy - float(iy0)
		var iy1: int = iy0 + 1
		iy0 = clampi(iy0, min_gy, max_gy)
		iy1 = clampi(iy1, min_gy, max_gy)
		var ty0: int = ((iy0 >> 8) - ty_min) * ncols
		var ty1: int = ((iy1 >> 8) - ty_min) * ncols
		var ry0: int = (iy0 & 255) * TILE_PX
		var ry1: int = (iy1 & 255) * TILE_PX

		for ix in res:
			var fx: float = px_col[ix]
			var ix0: int = int(floor(fx))
			var wx: float = fx - float(ix0)
			var ix1: int = ix0 + 1
			ix0 = clampi(ix0, min_gx, max_gx)
			ix1 = clampi(ix1, min_gx, max_gx)
			var cx0: int = (ix0 >> 8) - tx_min
			var cx1: int = (ix1 >> 8) - tx_min
			var a: PackedFloat32Array = grid[ty0 + cx0]
			var b: PackedFloat32Array = grid[ty0 + cx1]
			var c: PackedFloat32Array = grid[ty1 + cx0]
			var d: PackedFloat32Array = grid[ty1 + cx1]
			var h00: float = a[ry0 + (ix0 & 255)]
			var h10: float = b[ry0 + (ix1 & 255)]
			var h01: float = c[ry1 + (ix0 & 255)]
			var h11: float = d[ry1 + (ix1 & 255)]
			heights[iz * res + ix] = lerpf(lerpf(h00, h10, wx), lerpf(h01, h11, wx), wy)

		# cede o frame a cada ~32 linhas para a UI nao congelar
		if iz % 32 == 31:
			status.emit("Relevo: amostrando %d%%…" % int(100.0 * float(iz) / float(res)))
			await get_tree().process_frame

	# A primeira regiao define a referencia vertical (y = 0)
	if is_nan(frame.elev0):
		frame.elev0 = heights[(res / 2) * res + (res / 2)]

	var hmin: float = INF
	var hmax: float = -INF
	for i in heights.size():
		var h: float = heights[i] - frame.elev0
		heights[i] = h
		if h < hmin: hmin = h
		if h > hmax: hmax = h

	return {
		"ok": true,
		"heights": heights,
		"res": res,
		"step": step,
		"offset": Vector2(x0, z0),
		"size": Vector2(size_m, size_m),
		"hmin": hmin,
		"hmax": hmax,
		"error": "",
	}


## Terreno plano (fallback offline ou "relevo desligado").
func flat_heightfield(center_xz: Vector2, size_m: float, res: int) -> Dictionary:
	var heights: PackedFloat32Array = PackedFloat32Array()
	heights.resize(res * res)
	var half: float = size_m * 0.5
	return {
		"ok": true, "flat": true,
		"heights": heights, "res": res, "step": size_m / float(res - 1),
		"offset": Vector2(center_xz.x - half, center_xz.y - half),
		"size": Vector2(size_m, size_m), "hmin": 0.0, "hmax": 0.0, "error": "",
	}


## So baixa para o disco (sem decodificar) os tiles que cobrem um quadrado. Usado no pre-carregamento.
## Retorna o no de tiles que falharam.
func prefetch(frame, center_xz: Vector2, size_m: float, cancel: Callable = Callable()) -> int:
	var half: float = size_m * 0.5
	var ll_nw: Vector2 = frame.xz_to_latlon(center_xz.x - half, center_xz.y - half)
	var ll_se: Vector2 = frame.xz_to_latlon(center_xz.x + half, center_xz.y + half)
	var tx_min: int = int(floor((GeoUtils.lon_to_pixel_x(ll_nw.y, zoom) - 2.0) / TILE_PX))
	var tx_max: int = int(floor((GeoUtils.lon_to_pixel_x(ll_se.y, zoom) + 2.0) / TILE_PX))
	var ty_min: int = int(floor((GeoUtils.lat_to_pixel_y(ll_nw.x, zoom) - 2.0) / TILE_PX))
	var ty_max: int = int(floor((GeoUtils.lat_to_pixel_y(ll_se.x, zoom) + 2.0) / TILE_PX))
	var falhas: int = 0
	for ty in range(ty_min, ty_max + 1):
		for tx in range(tx_min, tx_max + 1):
			if cancel.is_valid() and cancel.call():
				return falhas
			var path: String = _tile_path(zoom, tx, ty)
			if FileAccess.file_exists(path):
				continue
			var r: Dictionary = await http.request_bytes(URL_TEMPLATE % [zoom, tx, ty])
			if not r.ok:
				falhas += 1
				continue
			var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
			if f:
				f.store_buffer(r.body)
				f.close()
	return falhas
