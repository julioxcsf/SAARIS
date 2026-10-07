extends RefCounted
## Utilidades estaticas do modulo geografico: cache em disco, tiles XYZ,
## classificacao de faixas de frequencia e leitura tolerante de numeros.

# CACHE EM DISCO

## Pasta raiz do cache geografico. Fica AO LADO de "Saves" (e nao dentro) para
## nao aparecer na lista de cenas salvas.
static func cache_root() -> String:
	var base: String = ""
	if Manager and Manager.save_base_dir != "":
		base = Manager.save_base_dir.get_base_dir()
	else:
		base = ProjectSettings.globalize_path("res://")
	return base.path_join("GeoCache")


static func cache_dir(sub: String) -> String:
	var p: String = cache_root().path_join(sub)
	if not DirAccess.dir_exists_absolute(p):
		DirAccess.make_dir_recursive_absolute(p)
	return p


# TILES XYZ (Web Mercator)

## Coordenada X continua em PIXELS globais (tiles de 256 px) para um dado zoom.
static func lon_to_pixel_x(lon: float, zoom: int) -> float:
	return (lon + 180.0) / 360.0 * float(1 << zoom) * 256.0


## Coordenada Y continua em PIXELS globais (tiles de 256 px) para um dado zoom.
static func lat_to_pixel_y(lat: float, zoom: int) -> float:
	var lat_c: float = clampf(lat, -85.05112878, 85.05112878)
	var s: float = sin(deg_to_rad(lat_c))
	return (0.5 - log((1.0 + s) / (1.0 - s)) / (4.0 * PI)) * float(1 << zoom) * 256.0


# FAIXAS DE FREQUENCIA (telefonia movel no Brasil)

## Nome da faixa a partir da frequencia em MHz. Ordem importa (ver sort_key).
static func faixa_de_freq(freq_mhz: float) -> String:
	if freq_mhz <= 0.0:
		return "Sem frequência"
	if freq_mhz >= 698.0 and freq_mhz <= 806.0:
		return "700 MHz"
	if freq_mhz >= 824.0 and freq_mhz <= 894.0:
		return "850 MHz"
	if freq_mhz >= 895.0 and freq_mhz <= 960.0:
		return "900 MHz"
	if freq_mhz >= 1710.0 and freq_mhz <= 1880.0:
		return "1800 MHz"
	if freq_mhz >= 1881.0 and freq_mhz <= 2170.0:
		return "2100 MHz"
	if freq_mhz >= 2300.0 and freq_mhz <= 2400.0:
		return "2300 MHz"
	if freq_mhz >= 2500.0 and freq_mhz <= 2690.0:
		return "2600 MHz"
	if freq_mhz >= 3300.0 and freq_mhz <= 3800.0:
		return "3500 MHz"
	return "Outras (%d MHz)" % int(round(freq_mhz))


## Normaliza o nome da prestadora para a marca comercial quando reconhecivel.
static func marca_operadora(raw: String) -> String:
	var n: String = raw.to_upper()
	if n.contains("TELEF") or n.contains("VIVO") or n.contains("TELESP") or n.contains("GVT"):
		return "Vivo"
	if n.contains("CLARO") or n.contains("EMBRATEL") or n.contains("NET SERV") or n.contains("AMERICA MOVIL"):
		return "Claro"
	if n.begins_with("TIM") or n.contains(" TIM ") or n.contains("TIM S.A") or n.contains("TIM CELULAR"):
		return "TIM"
	if n.begins_with("OI ") or n == "OI" or n.contains("OI MOVEL") or n.contains("TELEMAR") or n.contains("BRASIL TELECOM"):
		return "Oi"
	if n.contains("ALGAR") or n.contains("CTBC"):
		return "Algar"
	if n.contains("NEXTEL") or n.contains("NII HOLDINGS"):
		return "Nextel"
	if n.contains("SERCOMTEL"):
		return "Sercomtel"
	return raw.strip_edges()


# PARSING TOLERANTE

## Remove acentos/pontuacao e poe em minusculas: "Frequencia Tx (MHz)" -> "frequenciatxmhz"
static func norm_header(s: String) -> String:
	var t: String = s.strip_edges().to_lower()
	var map: Dictionary = {
		"á": "a", "à": "a", "â": "a", "ã": "a", "ä": "a",
		"é": "e", "è": "e", "ê": "e", "ë": "e",
		"í": "i", "ì": "i", "î": "i", "ï": "i",
		"ó": "o", "ò": "o", "ô": "o", "õ": "o", "ö": "o",
		"ú": "u", "ù": "u", "û": "u", "ü": "u", "ç": "c",
	}
	var out: String = ""
	for i in t.length():
		var ch: String = t[i]
		if map.has(ch):
			out += map[ch]
		elif (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out


## Le graus decimais ("-22,8587", "-22.8587") ou DMS ("22 graus51'31,2\"S").
## Retorna NAN se nao conseguir.
static func parse_coord(raw: String) -> float:
	var s: String = raw.strip_edges()
	if s == "":
		return NAN
	var t: String = s.replace(",", ".")
	if t.is_valid_float():
		return t.to_float()
	# DMS: extrai os numeros e o hemisferio
	var nums: PackedFloat64Array = PackedFloat64Array()
	var cur: String = ""
	for i in t.length():
		var ch: String = t[i]
		if (ch >= "0" and ch <= "9") or ch == ".":
			cur += ch
		else:
			if cur != "":
				nums.append(cur.to_float())
				cur = ""
	if cur != "":
		nums.append(cur.to_float())
	if nums.size() == 0:
		return NAN
	var val: float = nums[0]
	if nums.size() > 1:
		val += nums[1] / 60.0
	if nums.size() > 2:
		val += nums[2] / 3600.0
	var up: String = t.to_upper()
	if up.contains("S") or up.contains("W") or up.contains("O") or t.begins_with("-"):
		val = -absf(val)
	return val


## Numero generico com virgula ou ponto decimal; NAN se invalido.
static func parse_num(raw: String) -> float:
	var t: String = raw.strip_edges().replace(",", ".")
	if t.is_valid_float():
		return t.to_float()
	return NAN
