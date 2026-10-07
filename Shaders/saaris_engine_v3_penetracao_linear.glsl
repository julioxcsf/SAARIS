#[compute]
#version 450

// Depende de Vulkan 1.2.148 ou superior
#extension GL_EXT_shader_atomic_float : require                                 // ou : enable

#define MAX_REFLECTIONS 5
#define PotMin_dBm -160.0

// Define o bloco local ideal de 16x16 threads (256 nucleos por grupo)
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// 1. Estrutura bruta dos Predios (Mapeamento de 64 bytes do StreamPeerBuffer)
struct ObstaculoGPU {
	vec3 centro;           // offset  0,  size 12
	float raio_maximo;     // offset 12,  size  4
	vec3 bounds_min;       // offset 16,  size 12
	float perda_difracao;  // offset 28,  size  4
	vec3 bounds_max;       // offset 32,  size 12
	float coef_reflexao;   // offset 44,  size  4
	int vertex_offset;     // offset 48,  size  4
	int vertex_count;      // offset 52,  size  4
	int id;                // offset 56,  size  4
	int _pad;              // offset 60,  size  4
};  // total: 4 x 16 = 64 bytes de alinhamento

// 2. Estrutura das Antenas (Mapeamento exato de 32 bytes do seu Stream de TX)
struct AntenaGPU {
	vec3 global_pos;
	float padding_seguranca; // Captura o padding de alinhamento do vec3
	float freq_mhz;
	float potencia_dbm;
	vec2 padding_final;      // Absorve o restante do bloco de 16 bytes
};

// ==============================================================================
// # BINDINGS DOS BUFFERS CONFIGURADOS NO GDSCRIPT
// ==============================================================================
layout(set = 0, binding = 0, std430) coherent buffer MapaSaidaBuffer {
	float power_map[]; // Matriz plana NxN que receberá os Watts finais
};

layout(set = 0, binding = 1, std430) readonly buffer ObstaculosBuffer {
	ObstaculoGPU obstaculos[];
};

layout(set = 0, binding = 2, std430) readonly buffer AntenasBuffer {
	AntenaGPU antenas[];
};

layout(set = 0, binding = 3, std430) readonly buffer VerticesCompletosBuffer {
	vec4 vertices_totais[]; // Array gigante com todos os pontos do mapa
	// vec4.xyz é a posição do ponto
	// vec4.w é o ID do obstaculo que possui o ponto
};

// ==============================================================================
// # PUSH CONSTANTS (Dados rapidos de controle global)
// ==============================================================================
layout(push_constant) uniform ParametrosGlobais {
	ivec2 map_resolution; // 8 bytes
	vec2 map_size; // 8 bytes
	vec2 map_offset; // 8 bytes
	int total_obstaculos;
	int total_antenas;
}; // 8 variaveis de 4 bytes = 32 bytes - alinhamento ok.

// Constantes físicas globais
const float VELOCIDADE_LUZ = 299792458.0;
const float PI = 3.141592653589793;
const float path_loss_exponent = 2.8;

float log10(float x) {
	// nao faz sentido verificar se x <= 0, pois o FSPL já garante que a distância é positiva?

	return log(x) / 2.302585092994046; // Otimizado: divisão direta pela constante log(10)
}

vec3 pixel_to_world_position(ivec2 pixel_coord) {
	// Converte a coordenada do pixel para a posicao tridimensional do mundo do Saaris
	// (Assumindo tamanho de celula de 0.5m e altura do receptor a 5cm do chão)
	float x_step = map_size.x/float(map_resolution.x);
	float x0 = x_step/2.0;
	float y_step = map_size.y/float(map_resolution.y);
	float y0 = y_step/2.0;

	// oficialmente eu posso trocar esse ofset em z conforme o plano geredo
	return vec3(map_offset.x + (float(pixel_coord.x) * x_step + x0), 0.05, map_offset.y + (float(pixel_coord.y) * y_step + y0));
}

int world_to_pixel_index(vec3 pos) {
	vec2 pos_relativa = pos.xz - map_offset;
	float x_step = map_size.x / float(map_resolution.x);
	float y_step = map_size.y / float(map_resolution.y);

	int px = clamp(int(pos_relativa.x / x_step), 0, map_resolution.x - 1);
	int py = clamp(int(pos_relativa.y / y_step), 0, map_resolution.y - 1);

	return py * map_resolution.x + px;
}

float FSPL(float distancia_m, float freq_mhz) {
	if (distancia_m <= 0.001) return 0.0;

	// Calcula a perda em espaço livre (Free Space Path Loss) em dB
	float l0 = 20.0 * log10(1.0) + 20.0 * log10(freq_mhz) - 27.55;
	return l0 + (10.0 * path_loss_exponent * log10(distancia_m));
}

// --- FUNCAO AUXILIAR: Verifica colisao com os blocos AABB (Slab Test de Kay-Kajiya) ---
bool verifica_interceptacao_aabb(ObstaculoGPU obs, vec3 origin, vec3 dir, float max_dist, out float t_hit) {
	vec3 inv_dir = 1.0 / (dir + vec3(1e-6));
	vec3 t0 = (obs.bounds_min - origin) * inv_dir;
	vec3 t1 = (obs.bounds_max - origin) * inv_dir;

	vec3 tmin = min(t0, t1);
	vec3 tmax = max(t0, t1);

	float t_entrada = max(max(tmin.x, tmin.y), tmin.z);
	float t_saida = min(min(tmax.x, tmax.y), tmax.z);

	if (t_saida >= t_entrada && t_entrada > 0.0 && t_entrada < max_dist) {
		t_hit = t_entrada;
		return true;
	}
	return false;
}

// ==============================================================================
// # GEOMETRIA 3D FECHADA DO PREDIO: PAREDES + TETO
// ==============================================================================

const int SUPERFICIE_NENHUMA = -1;
const int SUPERFICIE_PAREDE  = 0;
const int SUPERFICIE_TETO    = 1;

const float EPSILON_SUPERFICIE_M = 0.03;

// Intersecao raio x parede vertical definida por uma aresta do footprint.
// A parede ocupa [y_min, y_max].
float intersecta_parede_vertical(vec4 vA, vec4 vB, vec3 origem, vec3 dir, float y_min, float y_max) {
	vec2 o = origem.xz;
	vec2 d = dir.xz;
	vec2 a = vA.xz;
	vec2 b = vB.xz;

	vec2 e = b - a;
	float denom = d.x * e.y - d.y * e.x;

	if (abs(denom) < 1e-7) {
		return -1.0;
	}

	float t = ((a.x - o.x) * e.y - (a.y - o.y) * e.x) / denom;
	float s = ((a.x - o.x) * d.y - (a.y - o.y) * d.x) / denom;

	if (t <= EPSILON_SUPERFICIE_M) {
		return -1.0;
	}

	if (s < 0.0 || s > 1.0) {
		return -1.0;
	}

	float y_impacto = origem.y + dir.y * t;

	if (y_impacto < y_min - 1e-4 || y_impacto > y_max + 1e-4) {
		return -1.0;
	}

	return t;
}

// Point-in-polygon 2D no footprint XZ do predio.
// O cache atual possui um vertice final de fechamento; por isso usamos
// vertex_count - 1 vertices unicos e fechamos a ultima aresta manualmente.
bool ponto_dentro_footprint(ObstaculoGPU obs, vec2 p) {
	int n = obs.vertex_count - 1;

	if (n < 3) {
		return false;
	}

	int base = obs.vertex_offset;
	bool dentro = false;

	for (int i = 0, j = n - 1; i < n; j = i++) {
		vec2 vi = vertices_totais[base + i].xz;
		vec2 vj = vertices_totais[base + j].xz;

		bool cruza_vertical = ((vi.y > p.y) != (vj.y > p.y));

		if (!cruza_vertical) {
			continue;
		}

		float denom = vj.y - vi.y;

		if (abs(denom) < 1e-8) {
			continue;
		}

		float x_intersecao =
			vi.x
			+ (p.y - vi.y)
			* (vj.x - vi.x)
			/ denom;

		if (p.x < x_intersecao) {
			dentro = !dentro;
		}
	}

	return dentro;
}

// Intersecao do raio com o plano horizontal do teto e validacao contra
// o footprint real do edificio.
bool intersectar_teto(ObstaculoGPU obs, vec3 origem, vec3 dir, float max_dist, out float t_hit, out vec3 normal_out) {
	if (abs(dir.y) < 1e-8) {
		return false;
	}

	float teto_y = obs.bounds_max.y;
	float t = (teto_y - origem.y) / dir.y;

	if (t <= EPSILON_SUPERFICIE_M || t >= max_dist) {
		return false;
	}

	vec3 ponto = origem + dir * t;

	if (!ponto_dentro_footprint(obs, ponto.xz)) {
		return false;
	}

	t_hit = t;
	normal_out = vec3(0.0, 1.0, 0.0);

	return true;
}

// Narrow-phase 3D: paredes laterais + teto competem pelo menor t.
// Esta e agora a unica fonte de verdade para colisao fisica do predio.
bool calcular_impacto_real(ObstaculoGPU obs, vec3 origem, vec3 dir, float max_dist, out float t_hit, out vec3 normal_out, out int aresta_local_out, out int tipo_superficie_out) {
	int v0 = obs.vertex_offset;
	int vN = obs.vertex_offset + obs.vertex_count;

	float y_min = obs.bounds_min.y;
	float y_max = obs.bounds_max.y;

	float t_menor = max_dist;
	bool achou = false;

	vec3 melhor_normal = vec3(0.0);
	int melhor_aresta = -1;
	int melhor_tipo = SUPERFICIE_NENHUMA;

	// --------------------------------------------------------------------------
	// Paredes laterais
	// --------------------------------------------------------------------------
	for (int v = v0; v < vN - 1; v++) {
		vec4 vA = vertices_totais[v];
		vec4 vB = vertices_totais[v + 1];

		float t = intersecta_parede_vertical(vA, vB, origem, dir, y_min, y_max);

		if (t > EPSILON_SUPERFICIE_M && t < t_menor && t < max_dist) {
			vec3 aresta = vec3(vB.x - vA.x, 0.0, vB.z - vA.z);

			vec3 normal_parede = normalize(vec3(-aresta.z, 0.0, aresta.x));

			// Mantem a convencao historica do cache para orientacao.
			// reflect() funciona com N ou -N; a orientacao e mais importante
			// para diagnostico do que para o rebate em si.
			if (vB.w < 0.0) {
				normal_parede *= -1.0;
			}

			t_menor = t;
			melhor_normal = normal_parede;
			melhor_aresta = v - v0;
			melhor_tipo = SUPERFICIE_PAREDE;
			achou = true;
		}
	}

	// --------------------------------------------------------------------------
	// Teto
	// --------------------------------------------------------------------------
	float t_teto;
	vec3 normal_teto;

	if (intersectar_teto(obs, origem, dir, max_dist, t_teto, normal_teto) && t_teto < t_menor) {
		t_menor = t_teto;
		melhor_normal = normal_teto;
		melhor_aresta = -1;
		melhor_tipo = SUPERFICIE_TETO;
		achou = true;
	}

	if (!achou) {
		return false;
	}

	t_hit = t_menor;
	normal_out = melhor_normal;
	aresta_local_out = melhor_aresta;
	tipo_superficie_out = melhor_tipo;

	return true;
}

// ==============================================================================
// # PENETRACAO / TRANSMISSAO ATRAVES DE CONSTRUCOES
// ==============================================================================
//
// Este modelo nao e knife-edge. Ele e um modelo empirico de transmissao por
// edificios. O caminho direto continua atravessando cada volume e acumula:
//
//   perda_superficie_entrada
// + perda_linear_interior
// + perda_superficie_saida
//
// A distancia interna e SEMPRE 3D: length(saida - entrada). Portanto X/Y/Z
// entram naturalmente sem somar perdas separadas por eixo.
// ==============================================================================

const float PENETRACAO_EPSILON_M = 0.03;

// Fachada externa media.
const float ESPESSURA_PAREDE_EXTERNA_M = 0.12;

// Cobertura/laje media. Mantemos separada porque normalmente e mais espessa.
const float ESPESSURA_TETO_M = 0.20;

// Atenuacao volumetrica equivalente do material atravessado.
const float ATENUACAO_MATERIAL_PAREDE_DB_POR_M = 35.0;
const float ATENUACAO_MATERIAL_TETO_DB_POR_M = 35.0;

// Aproximacao estatistica do interior: uma parede interna equivalente a cada 3 m.
const float ESPACAMENTO_MEDIO_PAREDES_INTERNAS_M = 4.0;
const float PERDA_MEDIA_PAREDE_INTERNA_DB = 2.0;

// Limite angular para evitar singularidade em incidencia quase tangencial.
const float COS_INCIDENCIA_MINIMO = 0.20;

float espessura_superficie_m(int tipo_superficie) {
	if (tipo_superficie == SUPERFICIE_TETO) {
		return ESPESSURA_TETO_M;
	}

	return ESPESSURA_PAREDE_EXTERNA_M;
}

float atenuacao_material_superficie_db_por_m(int tipo_superficie) {
	if (tipo_superficie == SUPERFICIE_TETO) {
		return ATENUACAO_MATERIAL_TETO_DB_POR_M;
	}

	return ATENUACAO_MATERIAL_PAREDE_DB_POR_M;
}

// Perda da interface/placa atravessada considerando incidencia obliqua.
// percurso_material = espessura / |cos(theta)|
float perda_superficie_db(vec3 direcao_raio, vec3 normal_superficie, int tipo_superficie) {
	float cos_theta = abs(dot(normalize(direcao_raio), normalize(normal_superficie)));

	cos_theta = max(cos_theta, COS_INCIDENCIA_MINIMO);

	float espessura = espessura_superficie_m(tipo_superficie);

	float atenuacao_db_por_m =
		atenuacao_material_superficie_db_por_m(tipo_superficie);

	float percurso_material =
		espessura / cos_theta;

	return percurso_material
		* atenuacao_db_por_m;
}

// Converte "uma parede a cada 3 m" em densidade continua (dB/m), evitando
// degraus artificiais em 3, 6, 9... metros.
float perda_interior_db(float distancia_dentro_m) {
	if (distancia_dentro_m <= 0.0) {
		return 0.0;
	}

	float perda_por_metro =
		PERDA_MEDIA_PAREDE_INTERNA_DB
		/ ESPACAMENTO_MEDIO_PAREDES_INTERNAS_M;

	return distancia_dentro_m
		* perda_por_metro;
}

// Perda total causada por UM edificio.
// A entrada pode ser parede ou teto; a saida tambem.
float perda_atravessamento_predio_db(ObstaculoGPU obs, vec3 origem, vec3 dir, float distancia_total, float t_entrada, vec3 normal_entrada, int tipo_entrada, out float distancia_dentro_m, out int tipo_saida_out) {
	vec3 ponto_entrada =
		origem + dir * t_entrada;

	float depois_entrada =
		t_entrada + PENETRACAO_EPSILON_M;

	if (depois_entrada >= distancia_total) {
		distancia_dentro_m = 0.0;
		tipo_saida_out = SUPERFICIE_NENHUMA;

		return perda_superficie_db(dir, normal_entrada, tipo_entrada);
	}

	vec3 origem_interna =
		origem + dir * depois_entrada;

	float distancia_restante =
		distancia_total - depois_entrada;

	float t_saida_local;
	vec3 normal_saida;
	int aresta_saida;
	int tipo_saida;

	bool encontrou_saida =
		calcular_impacto_real(obs, origem_interna, dir, distancia_restante, t_saida_local, normal_saida, aresta_saida, tipo_saida);

	float perda_db =
		perda_superficie_db(dir, normal_entrada, tipo_entrada);

	tipo_saida_out = SUPERFICIE_NENHUMA;

	if (encontrou_saida) {
		vec3 ponto_saida =
			origem_interna
			+ dir * t_saida_local;

		// Distancia 3D real percorrida dentro do volume.
		distancia_dentro_m =
			length(ponto_saida - ponto_entrada);

		perda_db +=
			perda_superficie_db(dir, normal_saida, tipo_saida);

		tipo_saida_out = tipo_saida;
	}
	else {
		// RX terminou dentro do volume: somente entrada + interior ate o RX.
		vec3 ponto_final =
			origem + dir * distancia_total;

		distancia_dentro_m =
			length(ponto_final - ponto_entrada);
	}

	perda_db +=
		perda_interior_db(distancia_dentro_m);

	return perda_db;
}


// ==============================================================================
// # DIFRACAO SIMPLES: PRIMEIRO OBSTACULO, TOPO + BORDAS
// ==============================================================================
// A penetracao continua sendo calculada normalmente. A difracao entra como um
// caminho ADICIONAL e e somada em watts no final.
//
// Para uma parede atingida sao testadas 3 arestas:
//   - vertical esquerda;
//   - vertical direita;
//   - topo da parede.
//
// Se o primeiro impacto for o teto, todas as arestas do perimetro superior e
// todas as verticais sao candidatas. Mantemos apenas o caminho mais forte para
// evitar superestimar a potencia somando varias knife-edges quase equivalentes.

const int ITERACOES_PONTO_DIFRACAO = 14;

vec3 ponto_otimo_aresta(vec3 origem, vec3 destino, vec3 a, vec3 b) {
	float lo = 0.0;
	float hi = 1.0;

	for (int i = 0; i < ITERACOES_PONTO_DIFRACAO; i++) {
		float t1 = lo + (hi - lo) / 3.0;
		float t2 = hi - (hi - lo) / 3.0;
		vec3 p1 = mix(a, b, t1);
		vec3 p2 = mix(a, b, t2);
		float l1 = length(p1 - origem) + length(destino - p1);
		float l2 = length(p2 - origem) + length(destino - p2);

		if (l1 < l2) hi = t2;
		else lo = t1;
	}

	return mix(a, b, 0.5 * (lo + hi));
}

float perda_knife_edge_db(float v) {
	if (v <= -0.78) return 0.0;
	float x = v - 0.1;
	return 6.9 + 20.0 * log10(sqrt(x * x + 1.0) + x);
}

float potencia_difracao_aresta_dbm(vec3 tx, vec3 rx, vec3 edge_a, vec3 edge_b, float freq_mhz, float pot_tx_dbm) {
	if (freq_mhz <= 0.0) return PotMin_dBm;

	vec3 q = ponto_otimo_aresta(tx, rx, edge_a, edge_b);
	float d1 = length(q - tx);
	float d2 = length(rx - q);
	float d0 = length(rx - tx);

	if (d1 <= 0.001 || d2 <= 0.001) return PotMin_dBm;

	float lambda = VELOCIDADE_LUZ / (freq_mhz * 1e6);
	float delta = max(d1 + d2 - d0, 0.0);
	float v = sqrt(max(2.0 * delta / max(lambda, 1e-9), 0.0));
	float loss_diff_db = perda_knife_edge_db(v);
	float path_db = FSPL(d1 + d2, freq_mhz);

	return pot_tx_dbm - path_db - loss_diff_db;
}

float potencia_difracao_predio_dbm(ObstaculoGPU obs, vec3 tx, vec3 rx, int aresta_impacto, int tipo_impacto, float freq_mhz, float pot_tx_dbm) {
	int base = obs.vertex_offset;
	int n = obs.vertex_count - 1;
	if (n < 2) return PotMin_dBm;

	float melhor_dbm = PotMin_dBm;

	if (tipo_impacto == SUPERFICIE_PAREDE && aresta_impacto >= 0 && aresta_impacto < n) {
		int j = (aresta_impacto + 1) % n;
		vec3 a0 = vertices_totais[base + aresta_impacto].xyz;
		vec3 b0 = vertices_totais[base + j].xyz;
		float y_top = obs.bounds_max.y;
		vec3 a_top = vec3(a0.x, y_top, a0.z);
		vec3 b_top = vec3(b0.x, y_top, b0.z);

		melhor_dbm = max(melhor_dbm, potencia_difracao_aresta_dbm(tx, rx, a0, a_top, freq_mhz, pot_tx_dbm));
		melhor_dbm = max(melhor_dbm, potencia_difracao_aresta_dbm(tx, rx, b0, b_top, freq_mhz, pot_tx_dbm));
		melhor_dbm = max(melhor_dbm, potencia_difracao_aresta_dbm(tx, rx, a_top, b_top, freq_mhz, pot_tx_dbm));
		return melhor_dbm;
	}

	// Impacto no teto: procura a melhor aresta do perimetro superior ou vertical.
	float y_top = obs.bounds_max.y;
	float y_bottom = obs.bounds_min.y;

	for (int i = 0; i < n; i++) {
		int j = (i + 1) % n;
		vec3 pi = vertices_totais[base + i].xyz;
		vec3 pj = vertices_totais[base + j].xyz;

		vec3 vi0 = vec3(pi.x, y_bottom, pi.z);
		vec3 vi1 = vec3(pi.x, y_top, pi.z);
		vec3 top_i = vec3(pi.x, y_top, pi.z);
		vec3 top_j = vec3(pj.x, y_top, pj.z);

		melhor_dbm = max(melhor_dbm, potencia_difracao_aresta_dbm(tx, rx, vi0, vi1, freq_mhz, pot_tx_dbm));
		melhor_dbm = max(melhor_dbm, potencia_difracao_aresta_dbm(tx, rx, top_i, top_j, freq_mhz, pot_tx_dbm));
	}

	return melhor_dbm;
}

// ==============================================================================
// # MECANISMO DE RASTREAMENTO MULTI-REFLEXAO 3D (RAY BOUNCING)
// ==============================================================================
//
// Diferenca principal para a versao anterior:
// - teto participa da colisao e da reflexao;
// - raios refletidos para cima NAO sao descartados imediatamente;
// - se o raio estiver descendo, o chao compete com os edificios;
// - se estiver subindo/horizontal, ele continua ate escapar da cena ou bater
//   em outra superficie;
// - offset apos impacto e feito NA DIRECAO REFLETIDA, evitando depender do
//   sentido da normal do footprint.
// ==============================================================================

void processar_trajeto_reflexao(float pot_tx_dbm, float freq_mhz, vec3 origin, vec3 dir, float distancia_inicial) {
	const float reflection_loss_db = 4.0;

	vec3 current_origin = origin;
	vec3 current_dir = normalize(dir);

	float distance_traveled = distancia_inicial;

	// Limite espacial para raios que estao subindo ou quase horizontais.
	float scene_ray_limit =
		max(length(map_size) * 1.5, 1000.0);

	// A chamada acontece DEPOIS da primeira reflexao. Logo bounce=0 ja
	// representa um caminho que sofreu 1 reflexao.
	for (int bounce = 0; bounce < MAX_REFLECTIONS; bounce++) {
		bool pode_tocar_chao =
			current_dir.y < -1e-6;

		float t_ground = scene_ray_limit;

		if (pode_tocar_chao) {
			float tg =
				(0.05 - current_origin.y)
				/ current_dir.y;

			if (tg > EPSILON_SUPERFICIE_M) {
				t_ground = min(tg, scene_ray_limit);
			}
			else {
				pode_tocar_chao = false;
			}
		}

		float t_limite =
			pode_tocar_chao
			? t_ground
			: scene_ray_limit;

		vec3 target_position =
			current_origin
			+ current_dir * t_limite;

		float t_closest = t_limite;
		int id_obs_colidido = -1;

		vec3 normal_colidida =
			vec3(0.0, 1.0, 0.0);

		int tipo_superficie_colidida =
			SUPERFICIE_NENHUMA;

		for (int i = 0; i < total_obstaculos; i++) {
			ObstaculoGPU obs = obstaculos[i];

			if (obs.centro.x > max(current_origin.x, target_position.x) + obs.raio_maximo) {
				break;
			}

			if (obs.centro.x < min(current_origin.x, target_position.x) - obs.raio_maximo) {
				continue;
			}

			float t_aabb;

			if (!verifica_interceptacao_aabb(obs, current_origin, current_dir, t_closest, t_aabb)) {
				continue;
			}

			float t_real;
			vec3 normal_real;
			int aresta_real;
			int tipo_real;

			if (calcular_impacto_real(obs, current_origin, current_dir, t_closest, t_real, normal_real, aresta_real, tipo_real)) {
				if (t_real < t_closest) {
					t_closest = t_real;
					id_obs_colidido = i;
					normal_colidida = normal_real;
					tipo_superficie_colidida = tipo_real;
				}
			}
		}

		// ----------------------------------------------------------------------
		// Nenhum edificio antes do limite.
		// Se o limite era o chao, deposita a potencia; se era o limite da cena,
		// o raio escapou e termina.
		// ----------------------------------------------------------------------
		if (id_obs_colidido == -1) {
			if (!pode_tocar_chao) {
				break;
			}

			distance_traveled += t_closest;

			float fspl_db =
				FSPL(distance_traveled, freq_mhz);

			float pot_final_dbm =
				pot_tx_dbm
				- fspl_db
				- (float(bounce) + 1.0)
				* reflection_loss_db;

			if (pot_final_dbm >= PotMin_dBm) {
				int idx_alvo =
					world_to_pixel_index(target_position);

				float watts_raio =
					pow(10.0, (pot_final_dbm - 30.0) / 10.0);

				atomicAdd(power_map[idx_alvo], watts_raio);
			}

			break;
		}

		// ----------------------------------------------------------------------
		// Colidiu com parede OU teto: reflete com a normal real.
		// ----------------------------------------------------------------------
		vec3 ponto_impacto =
			current_origin
			+ current_dir * t_closest;

		distance_traveled +=
			t_closest;

		vec3 nova_dir =
			normalize(reflect(current_dir, normal_colidida));

		// Avanca para o lado para o qual o raio realmente saiu.
		current_origin =
			ponto_impacto
			+ nova_dir * EPSILON_SUPERFICIE_M;

		current_dir =
			nova_dir;
	}
}

void main() {
	ivec2 pixel_coord =
		ivec2(gl_GlobalInvocationID.xy);

	if (pixel_coord.x >= map_resolution.x || pixel_coord.y >= map_resolution.y) {
		return;
	}

	int index_plano =
		pixel_coord.y
		* map_resolution.x
		+ pixel_coord.x;

	vec3 rx_pos =
		pixel_to_world_position(pixel_coord);

	float watts_totais = 0.0;

	for (int t = 0; t < total_antenas; t++) {
		AntenaGPU antena =
			antenas[t];

		vec3 tx_pos =
			antena.global_pos;

		vec3 raio_vetor =
			rx_pos - tx_pos;

		float distancia = length(raio_vetor);

		if (distancia <= 0.001) {
			continue;
		}

		vec3 raio_dir_norm = raio_vetor / distancia;

		// ----------------------------------------------------------------------
		// Propagacao base
		// ----------------------------------------------------------------------
		float fspl_db =
			FSPL(distancia, antena.freq_mhz);

		float pot_sem_predios_dbm =
			antena.potencia_dbm
			- fspl_db;

		//if (pot_sem_predios_dbm < PotMin_dBm) {
		//	continue;
		//}

		// ----------------------------------------------------------------------
		// Caminho transmitido por edificios.
		// ----------------------------------------------------------------------
		float perda_construcoes_db = 0.0;

		// Guardamos o impacto MAIS PROXIMO do TX para disparar uma unica cadeia
		// de reflexao coerente com o caminho original.
		bool encontrou_primeira_superficie = false;
		float menor_t_reflexao = distancia;
		vec3 normal_primeira_superficie = vec3(0.0);
		int tipo_primeira_superficie = SUPERFICIE_NENHUMA;
		int primeiro_obs_index = -1;
		int primeira_aresta = -1;

		for (int i = 0; i < total_obstaculos; i++) {
			ObstaculoGPU obs =
				obstaculos[i];

			// Broad phase pela ordenacao em X do cache.
			if (obs.centro.x > max(tx_pos.x, rx_pos.x) + obs.raio_maximo) {
				break;
			}

			if (obs.centro.x < min(tx_pos.x, rx_pos.x) - obs.raio_maximo) {
				continue;
			}

			// Mantem a convencao anterior: se a antena nasceu dentro do AABB,
			// nao cobra imediatamente uma parede desse mesmo edificio.
			if (all(greaterThanEqual(tx_pos, obs.bounds_min)) && all(lessThanEqual(tx_pos, obs.bounds_max))) {
				continue;
			}

			// AABB 3D inclui naturalmente o teto e evita falsos candidatos.
			float t_aabb;

			if (!verifica_interceptacao_aabb(obs, tx_pos, raio_dir_norm, distancia, t_aabb)) {
				continue;
			}

			// Narrow phase 3D: parede ou teto, o que vier primeiro.
			float t_entrada;
			vec3 normal_entrada;
			int aresta_entrada;
			int tipo_entrada;

			if (!calcular_impacto_real(obs, tx_pos, raio_dir_norm, distancia, t_entrada, normal_entrada, aresta_entrada, tipo_entrada)) {
				continue;
			}

			// Guarda a primeira superficie fisica real para a reflexao.
			if (t_entrada < menor_t_reflexao) {
				menor_t_reflexao = t_entrada;
				normal_primeira_superficie = normal_entrada;
				tipo_primeira_superficie = tipo_entrada;
				primeiro_obs_index = i;
				primeira_aresta = aresta_entrada;
				encontrou_primeira_superficie = true;
			}

			// ------------------------------------------------------------------
			// Perda continua pelo edificio: entrada + interior 3D + saida.
			// ------------------------------------------------------------------
			float distancia_dentro_m;
			int tipo_saida;

			float perda_predio_db =
				perda_atravessamento_predio_db(obs, tx_pos, raio_dir_norm, distancia, t_entrada, normal_entrada, tipo_entrada, distancia_dentro_m, tipo_saida);

			perda_construcoes_db += perda_predio_db;

			//if (pot_sem_predios_dbm - perda_construcoes_db < PotMin_dBm ) {
			//	break;
			//}
		}

		// ----------------------------------------------------------------------
		// Reflexao a partir da PRIMEIRA superficie realmente encontrada.
		// Funciona da mesma forma para parede e teto.
		// ----------------------------------------------------------------------
		if (encontrou_primeira_superficie) {
			vec3 ponto_impacto =
				tx_pos
				+ raio_dir_norm
				* menor_t_reflexao;

			vec3 direcao_refletida =
				normalize(reflect(raio_dir_norm, normal_primeira_superficie));

			processar_trajeto_reflexao(antena.potencia_dbm, antena.freq_mhz, ponto_impacto + direcao_refletida * EPSILON_SUPERFICIE_M, direcao_refletida, menor_t_reflexao);
		}

		// ----------------------------------------------------------------------
		// Potencia do caminho direto/transmitido.
		// ----------------------------------------------------------------------
		float pot_transmitida_dbm = pot_sem_predios_dbm - perda_construcoes_db;

		float pot_clamp_dbm = max(pot_transmitida_dbm, PotMin_dBm);
		float watts_antena = pow(10.0, (pot_clamp_dbm - 30.0) / 10.0);
		watts_totais += watts_antena;

		// Difracao e um caminho adicional. Consideramos apenas o primeiro predio
		// bloqueador e escolhemos a melhor rota entre topo e bordas.
		if (primeiro_obs_index >= 0) {
			ObstaculoGPU obs_diff = obstaculos[primeiro_obs_index];
			float pot_diff_dbm = potencia_difracao_predio_dbm(obs_diff, tx_pos, rx_pos, primeira_aresta, tipo_primeira_superficie, antena.freq_mhz, antena.potencia_dbm);
			if (pot_diff_dbm > PotMin_dBm) watts_totais += pow(10.0, (pot_diff_dbm - 30.0) / 10.0);
		}
	}

	// As reflexoes foram depositadas via atomicAdd na funcao de ray bouncing.
	if (watts_totais > 0.0) atomicAdd(power_map[index_plano], watts_totais);
}
