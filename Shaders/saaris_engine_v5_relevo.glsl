#[compute]
#version 450

// SAARIS v5 - v4 (penetracao + difracao + reflexao) + RELEVO (heightfield).
// Com usar_relevo = 0 o comportamento e identico ao da v4 (chao plano em y = 0.05).
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

layout(set = 0, binding = 4, std430) readonly buffer TerrenoBuffer {
	float alturas_terreno[]; // grade terrain_res.x * terrain_res.y, linha a linha (z), em metros
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
	ivec2 terrain_res;    // 8 bytes  - vertices da grade de relevo (cobre exatamente o mapa)
	float altura_rx;      // 4 bytes  - altura do receptor sobre o terreno (m)
	float terreno_h_max;  // 4 bytes
	float terreno_h_min;  // 4 bytes
	int usar_relevo;      // 4 bytes  - 0 = chao plano legado (v4)
	int _pad0;            // 4 bytes
	int _pad1;            // 4 bytes
	ivec2 tile_origem;    // 8 bytes  - 1o pixel (x,y) deste dispatch: o mapa e calculado em faixas curtas (evita timeout/TDR do driver)
	float expoente_perda; // 4 bytes - expoente n da perda de percurso (interface)
	float perda_reflexao_db; // 4 bytes - perda por reflexao (interface)
	int max_reflexoes;    // 4 bytes - limite de reflexoes (0..MAX_REFLECTIONS)
	int _padA;            // 4 bytes
	int _padB;            // 4 bytes
	int _padC;            // 4 bytes
}; // 20 variaveis de 4 bytes = 80 bytes - alinhamento ok.

// Constantes físicas globais
const float VELOCIDADE_LUZ = 299792458.0;
const float PI = 3.141592653589793;

float log10(float x) {
	// nao faz sentido verificar se x <= 0, pois o FSPL já garante que a distância é positiva?

	return log(x) / 2.302585092994046; // Otimizado: divisão direta pela constante log(10)
}

// ==============================================================================
// # RELEVO (HEIGHTFIELD)
// ==============================================================================
const float CHAO_PLANO_LEGADO_M = 0.05;

vec2 terreno_celula() {
	return map_size / vec2(terrain_res - ivec2(1));
}

// Altura bilinear do terreno em (x,z) mundo. Fora da grade, repete a borda.
float altura_terreno(vec2 xz) {
	vec2 g = (xz - map_offset) / terreno_celula();
	g = clamp(g, vec2(0.0), vec2(terrain_res) - vec2(1.0001));
	ivec2 i0 = ivec2(g);
	vec2 f = g - vec2(i0);
	int w = terrain_res.x;
	float h00 = alturas_terreno[i0.y * w + i0.x];
	float h10 = alturas_terreno[i0.y * w + i0.x + 1];
	float h01 = alturas_terreno[(i0.y + 1) * w + i0.x];
	float h11 = alturas_terreno[(i0.y + 1) * w + i0.x + 1];
	return mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
}

float altura_chao(vec2 xz) {
	if (usar_relevo == 0) return CHAO_PLANO_LEGADO_M;
	return altura_terreno(xz);
}

bool dentro_do_mapa(vec2 xz) {
	vec2 r = xz - map_offset;
	return r.x >= 0.0 && r.y >= 0.0 && r.x <= map_size.x && r.y <= map_size.y;
}

vec3 pixel_to_world_position(ivec2 pixel_coord) {
	// Converte a coordenada do pixel para a posicao tridimensional do mundo do Saaris.
	float x_step = map_size.x/float(map_resolution.x);
	float x0 = x_step/2.0;
	float y_step = map_size.y/float(map_resolution.y);
	float y0 = y_step/2.0;

	float wx = map_offset.x + (float(pixel_coord.x) * x_step + x0);
	float wz = map_offset.y + (float(pixel_coord.y) * y_step + y0);

	// Sem relevo: receptor a 5 cm do chao plano (comportamento da v4).
	// Com relevo: receptor a altura_rx acima do terreno local.
	float wy = (usar_relevo == 0) ? CHAO_PLANO_LEGADO_M : altura_terreno(vec2(wx, wz)) + altura_rx;
	return vec3(wx, wy, wz);
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
	return l0 + (10.0 * expoente_perda * log10(distancia_m));
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
// # DIFRACAO HIBRIDA MULTI-PREDIO: TOPO + BORDAS
// ==============================================================================
// Modelo deliberadamente limitado e estavel:
// - o primeiro predio bloqueador gera 3 caminhos: lateral A, lateral B e topo;
// - cada caminho segue ate o RX;
// - se outro predio bloquear a rota, ele pode gerar nova difracao;
// - entre eventos de difracao, predios atravessados acumulam a mesma perda de
//   penetracao usada no caminho direto;
// - profundidade maxima pequena evita explosao combinatoria;
// - mantemos apenas o ramo dominante depois da primeira abertura em 3 caminhos.
//
// Isso nao e UTD completa, mas trata de forma coerente sequencias de edificios
// sem voltar para a DFS gigante das versoes antigas.

const int ITERACOES_PONTO_DIFRACAO = 12;
const int MAX_EVENTOS_DIFRACAO = 3;

vec3 ponto_otimo_aresta(vec3 origem, vec3 destino, vec3 a, vec3 b) {
    float lo = 0.0, hi = 1.0;
    for (int i = 0; i < ITERACOES_PONTO_DIFRACAO; i++) {
        float t1 = lo + (hi - lo) / 3.0;
        float t2 = hi - (hi - lo) / 3.0;
        vec3 p1 = mix(a, b, t1);
        vec3 p2 = mix(a, b, t2);
        float l1 = length(p1 - origem) + length(destino - p1);
        float l2 = length(p2 - origem) + length(destino - p2);
        if (l1 < l2) hi = t2; else lo = t1;
    }
    return mix(a, b, 0.5 * (lo + hi));
}

float perda_knife_edge_db(float v) {
    if (v <= -0.78) return 0.0;
    float x = v - 0.1;
    return 6.9 + 20.0 * log10(sqrt(x * x + 1.0) + x);
}

float knife_aresta_db(vec3 origem, vec3 destino, vec3 q, float freq_mhz) {
    if (freq_mhz <= 0.0) return 0.0;
    float d1 = length(q - origem);
    float d2 = length(destino - q);
    float d0 = length(destino - origem);
    if (d1 <= 0.001 || d2 <= 0.001) return 0.0;
    float lambda = VELOCIDADE_LUZ / (freq_mhz * 1e6);
    float delta = max(d1 + d2 - d0, 0.0);
    float v = sqrt(max(2.0 * delta / max(lambda, 1e-9), 0.0));
    return perda_knife_edge_db(v);
}

float distancia_ponto_segmento_2d(vec2 p, vec2 a, vec2 b) {
    vec2 ab = b - a;
    float d2 = dot(ab, ab);
    if (d2 <= 1e-12) return length(p - a);
    float t = clamp(dot(p - a, ab) / d2, 0.0, 1.0);
    return length(p - (a + ab * t));
}

int aresta_relevante_predio(ObstaculoGPU obs, int aresta_impacto, int tipo_impacto, vec3 ponto_impacto) {
    int n = obs.vertex_count - 1;
    if (n < 2) return -1;
    if (tipo_impacto == SUPERFICIE_PAREDE && aresta_impacto >= 0 && aresta_impacto < n) return aresta_impacto;

    int base = obs.vertex_offset;
    float melhor = 1e30;
    int melhor_i = 0;
    for (int i = 0; i < n; i++) {
        int j = (i + 1) % n;
        float d = distancia_ponto_segmento_2d(ponto_impacto.xz, vertices_totais[base + i].xz, vertices_totais[base + j].xz);
        if (d < melhor) { melhor = d; melhor_i = i; }
    }
    return melhor_i;
}

// Encontra o primeiro volume realmente atingido por um segmento.
bool primeiro_bloqueio_segmento(vec3 origem, vec3 destino, int ignorar_a, int ignorar_b, out int obs_index, out float t_hit, out vec3 normal_hit, out int aresta_hit, out int tipo_hit) {
    vec3 delta = destino - origem;
    float max_dist = length(delta);
    if (max_dist <= EPSILON_SUPERFICIE_M) return false;
    vec3 dir = delta / max_dist;

    bool achou = false;
    float melhor_t = max_dist;
    int melhor_obs = -1, melhor_aresta = -1, melhor_tipo = SUPERFICIE_NENHUMA;
    vec3 melhor_normal = vec3(0.0);

    for (int i = 0; i < total_obstaculos; i++) {
        if (i == ignorar_a || i == ignorar_b) continue;
        ObstaculoGPU obs = obstaculos[i];
        if (obs.centro.x > max(origem.x, destino.x) + obs.raio_maximo) break;
        if (obs.centro.x < min(origem.x, destino.x) - obs.raio_maximo) continue;

        float t_aabb;
        if (!verifica_interceptacao_aabb(obs, origem, dir, melhor_t, t_aabb)) continue;

        float t_real;
        vec3 normal_real;
        int aresta_real, tipo_real;
        if (!calcular_impacto_real(obs, origem, dir, melhor_t, t_real, normal_real, aresta_real, tipo_real)) continue;
        if (t_real < melhor_t) {
            melhor_t = t_real;
            melhor_obs = i;
            melhor_normal = normal_real;
            melhor_aresta = aresta_real;
            melhor_tipo = tipo_real;
            achou = true;
        }
    }

    if (!achou) return false;
    obs_index = melhor_obs;
    t_hit = melhor_t;
    normal_hit = melhor_normal;
    aresta_hit = melhor_aresta;
    tipo_hit = melhor_tipo;
    return true;
}

// Perda por penetracao de todos os edificios cruzados por um segmento.
float perda_penetracao_segmento_db(vec3 origem, vec3 destino, int ignorar_a, int ignorar_b) {
    vec3 delta = destino - origem;
    float distancia = length(delta);
    if (distancia <= EPSILON_SUPERFICIE_M) return 0.0;
    vec3 dir = delta / distancia;
    float perda = 0.0;

    for (int i = 0; i < total_obstaculos; i++) {
        if (i == ignorar_a || i == ignorar_b) continue;
        ObstaculoGPU obs = obstaculos[i];
        if (obs.centro.x > max(origem.x, destino.x) + obs.raio_maximo) break;
        if (obs.centro.x < min(origem.x, destino.x) - obs.raio_maximo) continue;

        float t_aabb;
        if (!verifica_interceptacao_aabb(obs, origem, dir, distancia, t_aabb)) continue;

        float t_entrada;
        vec3 normal_entrada;
        int aresta_entrada, tipo_entrada;
        if (!calcular_impacto_real(obs, origem, dir, distancia, t_entrada, normal_entrada, aresta_entrada, tipo_entrada)) continue;

        float distancia_dentro;
        int tipo_saida;
        perda += perda_atravessamento_predio_db(obs, origem, dir, distancia, t_entrada, normal_entrada, tipo_entrada, distancia_dentro, tipo_saida);
    }
    return perda;
}

// Constroi as 3 arestas candidatas da face relevante: duas verticais + topo.
void arestas_candidatas_predio(ObstaculoGPU obs, int aresta_impacto, int tipo_impacto, vec3 ponto_impacto, out vec3 a0, out vec3 b0, out vec3 a1, out vec3 b1, out vec3 a2, out vec3 b2) {
    int n = obs.vertex_count - 1;
    int base = obs.vertex_offset;
    int i = aresta_relevante_predio(obs, aresta_impacto, tipo_impacto, ponto_impacto);
    int j = (i + 1) % n;

    vec3 pi = vertices_totais[base + i].xyz;
    vec3 pj = vertices_totais[base + j].xyz;
    float y0 = obs.bounds_min.y;
    float y1 = obs.bounds_max.y;

    vec3 li0 = vec3(pi.x, y0, pi.z);
    vec3 li1 = vec3(pi.x, y1, pi.z);
    vec3 lj0 = vec3(pj.x, y0, pj.z);
    vec3 lj1 = vec3(pj.x, y1, pj.z);

    a0 = li0; b0 = li1;
    a1 = lj0; b1 = lj1;
    a2 = li1; b2 = lj1;
}

// Escolhe uma unica aresta dominante para continuar o caminho em eventos
// posteriores. A primeira interacao ainda abre os 3 caminhos separadamente.
bool escolher_aresta_dominante(ObstaculoGPU obs, vec3 origem, vec3 rx, int aresta_impacto, int tipo_impacto, vec3 ponto_impacto, float freq_mhz, float pot_tx_dbm, float distancia_acumulada, float perda_acumulada, out vec3 q_out, out float knife_out) {
    vec3 ea0, eb0, ea1, eb1, ea2, eb2;
    arestas_candidatas_predio(obs, aresta_impacto, tipo_impacto, ponto_impacto, ea0, eb0, ea1, eb1, ea2, eb2);

    vec3 qa[3];
    qa[0] = ponto_otimo_aresta(origem, rx, ea0, eb0);
    qa[1] = ponto_otimo_aresta(origem, rx, ea1, eb1);
    qa[2] = ponto_otimo_aresta(origem, rx, ea2, eb2);

    float melhor_dbm = -1e30;
    int melhor = -1;
    float melhor_knife = 0.0;

    for (int c = 0; c < 3; c++) {
        float d = length(qa[c] - origem);
        if (d <= EPSILON_SUPERFICIE_M) continue;
        float knife = knife_aresta_db(origem, rx, qa[c], freq_mhz);
        float dist_total = distancia_acumulada + d + length(rx - qa[c]);
        float estimativa = pot_tx_dbm - FSPL(dist_total, freq_mhz) - perda_acumulada - knife;
        if (estimativa > melhor_dbm) { melhor_dbm = estimativa; melhor = c; melhor_knife = knife; }
    }

    if (melhor < 0) return false;
    q_out = qa[melhor];
    knife_out = melhor_knife;
    return true;
}

// Avalia um dos 3 caminhos produzidos pela primeira borda e permite ate
// MAX_EVENTOS_DIFRACAO eventos no total. Em cada novo predio segue pela borda
// dominante e compara continuamente com a opcao de simplesmente penetrar o
// restante do caminho.
float avaliar_caminho_difracao(vec3 tx, vec3 rx, vec3 q_inicial, int obs_inicial, float knife_inicial, float freq_mhz, float pot_tx_dbm) {
    vec3 dir_primeiro = normalize(q_inicial - tx);
    vec3 fim_antes_q = q_inicial - dir_primeiro * EPSILON_SUPERFICIE_M;
    float perda_acumulada = knife_inicial + perda_penetracao_segmento_db(tx, fim_antes_q, obs_inicial, -1);
    float distancia_acumulada = length(q_inicial - tx);

    vec3 current = q_inicial + normalize(rx - q_inicial) * EPSILON_SUPERFICIE_M;
    int obs_anterior = obs_inicial;
    float melhor_dbm = PotMin_dBm;

    for (int evento = 1; evento < MAX_EVENTOS_DIFRACAO; evento++) {
        // Alternativa 1: daqui em diante apenas penetracao ate o RX.
        float perda_restante = perda_penetracao_segmento_db(current, rx, obs_anterior, -1);
        float dist_terminal = distancia_acumulada + length(rx - current);
        float p_terminal = pot_tx_dbm - FSPL(dist_terminal, freq_mhz) - perda_acumulada - perda_restante;
        melhor_dbm = max(melhor_dbm, p_terminal);

        // Alternativa 2: se houver outro predio, contorna sua borda dominante.
        int obs2, aresta2, tipo2;
        float t2;
        vec3 normal2;
        if (!primeiro_bloqueio_segmento(current, rx, obs_anterior, -1, obs2, t2, normal2, aresta2, tipo2)) break;

        ObstaculoGPU o2 = obstaculos[obs2];
        vec3 ponto_hit2 = current + normalize(rx - current) * t2;
        vec3 q2;
        float knife2;
        if (!escolher_aresta_dominante(o2, current, rx, aresta2, tipo2, ponto_hit2, freq_mhz, pot_tx_dbm, distancia_acumulada, perda_acumulada, q2, knife2)) break;

        vec3 dir_q2 = normalize(q2 - current);
        vec3 fim_q2 = q2 - dir_q2 * EPSILON_SUPERFICIE_M;
        float perda_entre = perda_penetracao_segmento_db(current, fim_q2, obs_anterior, obs2);

        distancia_acumulada += length(q2 - current);
        perda_acumulada += perda_entre + knife2;
        current = q2 + normalize(rx - q2) * EPSILON_SUPERFICIE_M;
        obs_anterior = obs2;
    }

    float perda_final = perda_penetracao_segmento_db(current, rx, obs_anterior, -1);
    float dist_final = distancia_acumulada + length(rx - current);
    melhor_dbm = max(melhor_dbm, pot_tx_dbm - FSPL(dist_final, freq_mhz) - perda_acumulada - perda_final);
    return melhor_dbm;
}

float potencia_difracao_multiplos_predios_dbm(int obs_index, vec3 tx, vec3 rx, int aresta_impacto, int tipo_impacto, vec3 ponto_impacto, float freq_mhz, float pot_tx_dbm) {
    if (obs_index < 0 || freq_mhz <= 0.0) return PotMin_dBm;
    ObstaculoGPU obs = obstaculos[obs_index];

    vec3 ea0, eb0, ea1, eb1, ea2, eb2;
    arestas_candidatas_predio(obs, aresta_impacto, tipo_impacto, ponto_impacto, ea0, eb0, ea1, eb1, ea2, eb2);

    vec3 q0 = ponto_otimo_aresta(tx, rx, ea0, eb0);
    vec3 q1 = ponto_otimo_aresta(tx, rx, ea1, eb1);
    vec3 q2 = ponto_otimo_aresta(tx, rx, ea2, eb2);

    float p0 = avaliar_caminho_difracao(tx, rx, q0, obs_index, knife_aresta_db(tx, rx, q0, freq_mhz), freq_mhz, pot_tx_dbm);
    float p1 = avaliar_caminho_difracao(tx, rx, q1, obs_index, knife_aresta_db(tx, rx, q1, freq_mhz), freq_mhz, pot_tx_dbm);
    float p2 = avaliar_caminho_difracao(tx, rx, q2, obs_index, knife_aresta_db(tx, rx, q2, freq_mhz), freq_mhz, pot_tx_dbm);

    // Soma todos os caminhos que estejam ate 10 dB abaixo do melhor.
    // 10 dB = fator 10 em potencia. Caminhos muito mais fracos sao ignorados.
    const float LIMIAR_CAMINHO_DB = 10.0;
    float melhor = max(p0, max(p1, p2));
    float watts = 0.0;

    if (p0 >= melhor - LIMIAR_CAMINHO_DB) watts += pow(10.0, (p0 - 30.0) / 10.0);
    if (p1 >= melhor - LIMIAR_CAMINHO_DB) watts += pow(10.0, (p1 - 30.0) / 10.0);
    if (p2 >= melhor - LIMIAR_CAMINHO_DB) watts += pow(10.0, (p2 - 30.0) / 10.0);

    if (watts <= 0.0) return PotMin_dBm;
    return 10.0 * log10(watts) + 30.0;
}

// ==============================================================================
// # DIFRACAO POR RELEVO (Deygout, ITU-R P.526) + INTERSECAO RAIO x RELEVO
// ==============================================================================

// Maior parametro de Fresnel-Kirchhoff v do relevo entre a e b.
// v > 0: o terreno fura a linha de visada; v < -0.78: desobstruido (perda ~ 0).
float v_max_relevo(vec3 a, vec3 b, float lambda, int n_amostras, out vec3 ponto_topo) {
	ponto_topo = a;
	float D = length(b - a);
	if (D < 1.0) return -100.0;

	float v_max = -100.0;
	for (int i = 1; i < n_amostras; i++) {
		float s = float(i) / float(n_amostras);
		vec3 p = mix(a, b, s);
		float h = altura_terreno(p.xz);
		float d1 = s * D;
		float d2 = D - d1;
		float v = (h - p.y) * sqrt(2.0 * D / (lambda * d1 * d2));
		if (v > v_max) {
			v_max = v;
			ponto_topo = vec3(p.x, h, p.z);
		}
	}
	return v_max;
}

// Perda de difracao do relevo no caminho direto a->b: aresta principal + 2 sub-arestas (Deygout).
float perda_relevo_db(vec3 a, vec3 b, float freq_mhz) {
	if (usar_relevo == 0 || freq_mhz <= 0.0) return 0.0;

	float lambda = VELOCIDADE_LUZ / (freq_mhz * 1e6);
	vec2 cel = terreno_celula();
	float dist_h = length(b.xz - a.xz);
	int n = clamp(int(dist_h / max(min(cel.x, cel.y), 1.0)), 8, 128);

	vec3 topo;
	float v1 = v_max_relevo(a, b, lambda, n, topo);
	if (v1 <= -0.78) return 0.0;

	float perda = perda_knife_edge_db(v1);

	vec3 ignorado;
	int n2 = max(n / 2, 6);
	float v2 = v_max_relevo(a, topo, lambda, n2, ignorado);
	if (v2 > -0.78) perda += perda_knife_edge_db(v2);
	float v3 = v_max_relevo(topo, b, lambda, n2, ignorado);
	if (v3 > -0.78) perda += perda_knife_edge_db(v3);

	return min(perda, 80.0);
}

// Interseccao raio x relevo por marcha + bisseccao. Retorna t>0 ou -1 (nao toca / saiu do mapa).
float tracar_terreno(vec3 origem, vec3 dir, float t_max) {
	vec2 cel = terreno_celula();
	float passo = max(min(cel.x, cel.y), 1.0);
	float dt = max(passo, t_max / 192.0);

	if (origem.y - altura_terreno(origem.xz) <= 0.0) {
		return EPSILON_SUPERFICIE_M;
	}

	float t_prev = 0.0;
	for (int i = 1; i <= 256; i++) {
		float tt = min(float(i) * dt, t_max);
		vec3 p = origem + dir * tt;
		if (!dentro_do_mapa(p.xz)) {
			return -1.0;
		}
		if (p.y - altura_terreno(p.xz) <= 0.0) {
			float lo = t_prev;
			float hi = tt;
			for (int k = 0; k < 8; k++) {
				float mid = 0.5 * (lo + hi);
				vec3 pm = origem + dir * mid;
				if (pm.y - altura_terreno(pm.xz) <= 0.0) { hi = mid; } else { lo = mid; }
			}
			return hi;
		}
		t_prev = tt;
		if (tt >= t_max) {
			break;
		}
	}
	return -1.0;
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
	float reflection_loss_db = perda_reflexao_db;

	vec3 current_origin = origin;
	vec3 current_dir = normalize(dir);

	float distance_traveled = distancia_inicial;

	// Limite espacial para raios que estao subindo ou quase horizontais.
	float scene_ray_limit =
		max(length(map_size) * 1.5, 1000.0);

	// A chamada acontece DEPOIS da primeira reflexao. Logo bounce=0 ja
	// representa um caminho que sofreu 1 reflexao.
	for (int bounce = 0; bounce < MAX_REFLECTIONS && bounce < max_reflexoes; bounce++) {
		bool pode_tocar_chao = false;
		float t_ground = scene_ray_limit;

		if (usar_relevo == 0) {
			// Chao plano legado (v4)
			pode_tocar_chao = current_dir.y < -1e-6;

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
		}
		else {
			// Chao = relevo (heightfield)
			float tg = tracar_terreno(current_origin, current_dir, scene_ray_limit);
			if (tg > 0.0) {
				pode_tocar_chao = true;
				t_ground = tg;
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
		ivec2(gl_GlobalInvocationID.xy) + tile_origem;

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
		float perda_relevo = perda_relevo_db(tx_pos, rx_pos, antena.freq_mhz);
		float pot_transmitida_dbm = pot_sem_predios_dbm - perda_construcoes_db - perda_relevo;

		float pot_clamp_dbm = max(pot_transmitida_dbm, PotMin_dBm);
		float watts_antena = pow(10.0, (pot_clamp_dbm - 30.0) / 10.0);
		watts_totais += watts_antena;

		// Difracao hibrida: topo/laterais no primeiro bloqueio e ate mais 2
		// eventos em predios posteriores; os demais volumes entram como penetracao.
		if (primeiro_obs_index >= 0) {
			vec3 ponto_primeiro_impacto = tx_pos + raio_dir_norm * menor_t_reflexao;
			float pot_diff_dbm = potencia_difracao_multiplos_predios_dbm(primeiro_obs_index, tx_pos, rx_pos, primeira_aresta, tipo_primeira_superficie, ponto_primeiro_impacto, antena.freq_mhz, antena.potencia_dbm);
			pot_diff_dbm -= perda_relevo;
			if (pot_diff_dbm > PotMin_dBm) watts_totais += pow(10.0, (pot_diff_dbm - 30.0) / 10.0);
		}
	}

	// As reflexoes foram depositadas via atomicAdd na funcao de ray bouncing.
	if (watts_totais > 0.0) atomicAdd(power_map[index_plano], watts_totais);
}
