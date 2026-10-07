extends RefCounted
## Modelo analitico de um RIS (funcoes puras, sem dependencia de cena).
## Base: Ozdogan, Bjornson, Larsson, "Intelligent Reflecting Surfaces: Physics, Propagation, and Pathloss Modeling"
## (IEEE WCL 2020, arXiv 1911.03359).
##
## Reflexao ideal, eq. 19:   Pr = Pt * Gt * Gr * eta * (A / (4*pi*d1*d2))^2 * cos^2(theta_i)
##   A = area do painel, d1 = TX->RIS, d2 = RIS->ponto, eta = eficiencia (acrescimo pratico; o artigo assume 1).
## Fora da direcao ideal entra o fator de feixe sinc^2 da eq. 15 (so no modo "feixe fixo").
## Vale em campo distante (r >= 2*max(a,b)^2/lambda); abaixo disso e so estimativa ("campo proximo").
## A soma com o mapa direto e incoerente (potencias somadas); o motor GPU nao modela RIS.

const LIMITE_FREQ_REL := 0.02    # RIS e banda estreita: so reflete TX a +/-2 % da sua frequencia

static func dbm_para_w(dbm: float) -> float:
	return pow(10.0, (dbm - 30.0) / 10.0)

static func w_para_dbm(w: float) -> float:
	if w <= 0.0:
		return -200.0
	return 10.0 * log(w) / log(10.0) + 30.0

## sinc^2(x) = (sin x / x)^2
static func sinc2(x: float) -> float:
	if absf(x) < 1.0e-4:
		return 1.0
	var v: float = sin(x) / x
	return v * v

## Fator de feixe (eq. 15 do artigo): 1 na direcao alvo e decai fora dela.
## dx, dy = diferenca dos cossenos diretores (direcao avaliada - direcao alvo) ao longo da largura e da altura.
static func fator_feixe(largura_m: float, altura_m: float, lambda_m: float, dx: float, dy: float) -> float:
	return sinc2(PI * largura_m * dx / lambda_m) * sinc2(PI * altura_m * dy / lambda_m)

## Potencia (W) no ponto `rx_pos` vinda de UM TX refletida por UM RIS, na direcao do feixe (F = 1).
## Retorna {w, d1, d2, cos_i, cos_r, campo_proximo}.
static func potencia_via_ris(pt_dbm: float, tx_pos: Vector3, ris_pos: Vector3, ris_normal: Vector3,
		rx_pos: Vector3, area_m2: float, eficiencia: float, freq_mhz: float,
		gt: float = 1.0, gr: float = 1.0) -> Dictionary:
	var v1: Vector3 = tx_pos - ris_pos
	var v2: Vector3 = rx_pos - ris_pos
	var d1: float = maxf(v1.length(), 0.01)
	var d2: float = maxf(v2.length(), 0.01)
	var n: Vector3 = ris_normal.normalized()
	var cos_i: float = n.dot(v1 / d1)
	var cos_r: float = n.dot(v2 / d2)
	var out := {"w": 0.0, "d1": d1, "d2": d2, "cos_i": cos_i, "cos_r": cos_r, "campo_proximo": false}
	if cos_i <= 0.0 or cos_r <= 0.0 or area_m2 <= 0.0:
		return out            # TX ou RX atras do painel

	var pt: float = dbm_para_w(pt_dbm)
	var raz: float = area_m2 / (4.0 * PI * d1 * d2)
	var pr: float = pt * gt * gr * eficiencia * raz * raz * cos_i * cos_i            # eq. (19)
	var interceptada: float = pt * gt * area_m2 * cos_i / (4.0 * PI * d1 * d1)
	pr = minf(minf(pr, interceptada * eficiencia), pt)      # nunca mais que o interceptado nem que o transmitido

	var lambda_m: float = 300.0 / maxf(freq_mhz, 1.0)
	var fraunhofer: float = 2.0 * area_m2 / lambda_m          # 2*D^2/lambda, painel ~ quadrado (D^2 = area)
	out.w = pr
	out.campo_proximo = (d2 < fraunhofer)                     # o artigo exige r >= 2*D^2/lambda no lado do RX
	return out

static func freq_compativel(freq_tx_mhz: float, freq_ris_mhz: float) -> bool:
	return absf(freq_tx_mhz - freq_ris_mhz) <= LIMITE_FREQ_REL * freq_ris_mhz
