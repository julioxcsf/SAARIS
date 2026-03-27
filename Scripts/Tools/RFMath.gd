class_name RFMath extends RefCounted
# Funções utilitárias para calculos de perda

static func dbm_to_watts(dbm: float) -> float: 
	return pow(10.0, (dbm - 30.0) / 10.0)

static func watts_to_dbm(watts: float) -> float: 
	return (10.0 * log(watts) / log(10.0) + 30.0) if watts > 0 else -200.0

static func db_to_linear(db: float) -> float: 
	return pow(10.0, db / 10.0)

# Retorna o comprimento de onda em metros
static func get_lambda_m(frequencia_mhz: float) -> float:
	return 300.0 / frequencia_mhz

# Calcula a perda por difração (em dB POSITIVOS) usando a aproximação de Lee
static func calculate_knife_edge_loss_db(v: float) -> float:
	if v < -0.8: # Quase 0 dB de perda (Zona de Fresnel > 60% livre)
		return 0.0
	
	if v < 0:
		return 6.0 + 9.0 * v + 1.6 * v * v
	
	if v < 1.0:
		return 6.0 + 8.0 * v
	
	if v < 2.4:
		return 8.0 + 6.0 * (v - 1.0)
	
	# Aproximação de Lee (para v > 2.4)
	return 16.0 + 20.0 * log(v / 2.4) / log(10.0)

# Calcula o parâmetro 'v' de Fresnel-Kirchhoff
static func calculate_diffraction_parameter_v(h: float, d1: float, d2: float, lambda_m: float) -> float:
	if d1 == 0.0 or d2 == 0.0 or lambda_m == 0.0:
		return 0.0 # Evita divisão por zero
	
	# A fórmula clássica
	var v = h * sqrt( (2.0 * (d1 + d2)) / (lambda_m * d1 * d2) )
	return v

static func gerar_distancia_de_fraunhofer(dimensao_maxima_m: float, lambda_m: float) -> float:
	# df = 2 * D^2 / lambda
	return (2.0 * pow(dimensao_maxima_m, 2)) / lambda_m
