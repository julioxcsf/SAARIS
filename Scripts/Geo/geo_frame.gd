extends RefCounted
## Quadro de referencia local do SAARIS (ENU simplificado).
##
## Convencao (identica a do importador OSM original):
##   x = leste (m)     z = SUL (m)     y = altura (m) relativa a elev0
## A origem (0,0) e o ponto lat0/lon0. Todas as regioes carregadas usam a MESMA
## origem, entao regioes vizinhas encaixam sem emendas no mundo 3D.

var lat0: float = -22.8587
var lon0: float = -43.2306
var elev0: float = NAN            # elevacao (m, nivel do mar) que vira y = 0. NAN = ainda nao definida
var m_per_deg_lat: float = 111000.0
var m_per_deg_lon: float = 102000.0


func _init(p_lat0: float = -22.8587, p_lon0: float = -43.2306) -> void:
	set_origin(p_lat0, p_lon0)


func set_origin(p_lat0: float, p_lon0: float) -> void:
	lat0 = p_lat0
	lon0 = p_lon0
	var phi: float = deg_to_rad(lat0)
	# Comprimento de 1 grau (formulas WGS84 padrao)
	m_per_deg_lat = 111132.92 - 559.82 * cos(2.0 * phi) + 1.175 * cos(4.0 * phi) - 0.0023 * cos(6.0 * phi)
	m_per_deg_lon = 111412.84 * cos(phi) - 93.5 * cos(3.0 * phi) + 0.118 * cos(5.0 * phi)


## lat/lon -> (x, z) locais em metros
func latlon_to_xz(lat: float, lon: float) -> Vector2:
	return Vector2((lon - lon0) * m_per_deg_lon, (lat0 - lat) * m_per_deg_lat)


## (x, z) locais -> Vector2(lat, lon)
func xz_to_latlon(x: float, z: float) -> Vector2:
	return Vector2(lat0 - z / m_per_deg_lat, lon0 + x / m_per_deg_lon)


## Caixa lat/lon que cobre um quadrado local (centro em metros, meia-aresta em metros)
func bbox_latlon(center_xz: Vector2, half_m: float, margin_m: float = 0.0) -> Dictionary:
	var h: float = half_m + margin_m
	var nw: Vector2 = xz_to_latlon(center_xz.x - h, center_xz.y - h)
	var se: Vector2 = xz_to_latlon(center_xz.x + h, center_xz.y + h)
	return {
		"north": nw.x, "south": se.x,
		"west": nw.y, "east": se.y,
	}
