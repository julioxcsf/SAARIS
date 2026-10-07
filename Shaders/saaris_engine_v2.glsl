#[compute]
#version 450

// Depende de Vulkan 1.2.148 ou superior
#extension GL_EXT_shader_atomic_float : require                                 // ou : enable

#define MAX_REFLECTIONS 5


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
	return vec3(
		map_offset.x + (float(pixel_coord.x) * x_step + x0), 				
		0.05, 				
		map_offset.y + (float(pixel_coord.y) * y_step + y0)
	); 
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

// Interseção raio × aresta vertical. Retorna o `t` ou -1.0 se não bate.
// A aresta vai de vA.xz até vB.xz, com altura `altura_max`.
float intersecta_aresta_vertical(vec4 vA, vec4 vB, vec3 origem, vec3 dir, float altura_max) {
	vec2 o = origem.xz;
	vec2 d = dir.xz;
	vec2 a = vA.xz;
	vec2 b = vB.xz;
	
	vec2 e = b - a;
	float denom = d.x * e.y - d.y * e.x;
	if (abs(denom) < 1e-6) return -1.0;   // raio paralelo à aresta
	
	float t = ((a.x - o.x) * e.y - (a.y - o.y) * e.x) / denom;
	float s = ((a.x - o.x) * d.y - (a.y - o.y) * d.x) / denom;
	
	if (t < 0.01) return -1.0;             // atrás da origem
	if (s < 0.0 || s > 1.0) return -1.0;   // fora do segmento
	
	float y_impacto = origem.y + dir.y * t;
	if (y_impacto < 0.0 || y_impacto > altura_max) return -1.0;   // acima ou abaixo da parede
	
	return t;
}

// Narrow-phase: confirma se o raio bate em alguma aresta real do prédio.
// Só deve ser chamada depois do AABB validar que há interseção.
bool calcular_impacto_real(ObstaculoGPU obs, vec3 origem, vec3 dir, float max_dist,
						   out float t_hit, out vec3 normal_out) {
	int v0 = obs.vertex_offset;
	int vN = obs.vertex_offset + obs.vertex_count;
	float altura = obs.bounds_max.y;
	
	float t_menor = max_dist;
	bool achou = false;
	
	for (int v = v0; v < vN - 1; v++) {
		vec4 vA = vertices_totais[v];
		vec4 vB = vertices_totais[v + 1];
		
		float t = intersecta_aresta_vertical(vA, vB, origem, dir, altura);
		
		if (t > 0.0 && t < t_menor) {
			t_menor = t;
			
			vec3 aresta = vec3(vB.x - vA.x, 0.0, vB.z - vA.z);
			normal_out = normalize(vec3(-aresta.z, 0.0, aresta.x));
			if (vB.w < 0.0) normal_out *= -1.0;   // vértice de fechamento inverte orientação
			
			achou = true;
		}
	}
	
	if (achou) {
		t_hit = t_menor;
		return true;
	}
	return false;
}


// --- MECANISMO DE RASTREAMENTO MULTI-REFLEXAO (RAY BOUNCING) ---
void processar_trajeto_reflexao(float pot_tx_dbm, float freq_mhz, vec3 origin, vec3 dir, float distancia_inicial) {
	float reflection_loss_db = 4.0;
	vec3 current_origin = origin;
	vec3 current_dir = dir;
	float distance_traveled = distancia_inicial;
	
	for (int bounce = 0; bounce <= MAX_REFLECTIONS; bounce++) {
		if (current_dir.y >= 0.0) {
			break;
		}
		
		float t_ground = (0.05 - current_origin.y) / current_dir.y;
		vec3 target_position = current_origin + current_dir * t_ground;
		
		float t_closest = t_ground;
		int id_obs_colidido = -1;
		vec3 normal_colidida = vec3(0.0, 1.0, 0.0);
		
		for (int i = 0; i < total_obstaculos; i++) {
			ObstaculoGPU obs = obstaculos[i];
			if (obs.centro.x > max(current_origin.x, target_position.x) + obs.raio_maximo) break;
			if (obs.centro.x < min(current_origin.x, target_position.x) - obs.raio_maximo) continue;
			
			float t_aabb;
			if (verifica_interceptacao_aabb(obs, current_origin, current_dir, t_closest, t_aabb)) {
				float t_real;
				vec3 normal_real;
				if (calcular_impacto_real(obs, current_origin, current_dir, t_closest, t_real, normal_real)) {
					t_closest = t_real;
					id_obs_colidido = i;
					normal_colidida = normal_real;
				}
			}
		}
		
		// CASO A: Tocou o chao sem novas barreiras
		if (id_obs_colidido == -1) {
			distance_traveled += t_closest;
			float fspl_db = FSPL(distance_traveled, freq_mhz);
			float pot_final_dbm = pot_tx_dbm - fspl_db - (float(bounce) * reflection_loss_db);
			
			if (pot_final_dbm >= -120.0) {
				int idx_alvo = world_to_pixel_index(target_position);
				float watts_raio = pow(10.0, (pot_final_dbm - 30.0) / 10.0);
				atomicAdd(power_map[idx_alvo], watts_raio);
			}
			break;
		}
		
		// ====================================================================
		// CASO B: O raio colidiu com uma parede antes do solo. Prepara o proximo rebate.
		// ====================================================================
		vec3 ponto_impacto = current_origin + current_dir * t_closest;
		distance_traveled += t_closest;
		
		// Usa a normal que o narrow-phase guardou — sem recalcular, sem ID.
		current_origin = ponto_impacto + normal_colidida * 0.01;
		current_dir = reflect(current_dir, normal_colidida);
	}
}

void main() {
	//atomicAdd(power_map[0], 1); // Funciona quando o buffer é definido com o tipo coherent buffer
	
	ivec2 pixel_coord = ivec2(gl_GlobalInvocationID.xy);
	if (pixel_coord.x >= map_resolution.x || pixel_coord.y >= map_resolution.y) {
		return;
	}
	
	int index_plano = pixel_coord.y * map_resolution.x + pixel_coord.x;
	vec3 rx_pos = pixel_to_world_position(pixel_coord);
	float watts_totais = 0.0;
	
	for (int t = 0; t < total_antenas; t++) {
		AntenaGPU antena = antenas[t];
		vec3 tx_pos = antena.global_pos;
		
		vec3 raio_vetor = rx_pos - tx_pos;
		float distancia = length(raio_vetor);
		vec3 raio_dir_norm = normalize(raio_vetor);
		
		float fspl_db = FSPL(distancia, antena.freq_mhz);
		float pot_estimada_dbm = antena.potencia_dbm - fspl_db;
		
		if (pot_estimada_dbm < -120.0) {
			continue; 
		}
		
		bool tem_los = true;

		for (int i = 0; i < total_obstaculos; i++) {
			ObstaculoGPU obs = obstaculos[i];
			if (obs.centro.x > max(tx_pos.x, rx_pos.x) + obs.raio_maximo) break;
			if (obs.centro.x < min(tx_pos.x, rx_pos.x) - obs.raio_maximo) continue;
			if (all(greaterThanEqual(tx_pos, obs.bounds_min)) &&
				all(lessThanEqual(tx_pos, obs.bounds_max))) continue;
			
			vec3 vetor_tx_predio = obs.centro - tx_pos;
			float projecao = dot(vetor_tx_predio, raio_dir_norm);
			float dist_perp_sq = dot(vetor_tx_predio, vetor_tx_predio) - (projecao * projecao);
			if (dist_perp_sq > (obs.raio_maximo * obs.raio_maximo)) continue; 
			
			// Teste AABB Fino
			vec3 inv_dir = 1.0 / (raio_dir_norm + vec3(1e-6)); 
			vec3 t0 = (obs.bounds_min - tx_pos) * inv_dir;
			vec3 t1 = (obs.bounds_max - tx_pos) * inv_dir;
			vec3 tmin = min(t0, t1);
			vec3 tmax = max(t0, t1);
			float t_entrada = max(max(tmin.x, tmin.y), tmin.z);
			float t_saida = min(min(tmax.x, tmax.y), tmax.z);

			if (t_saida >= t_entrada && t_entrada > 0.0 && t_entrada < distancia) {
				// AABB bateu. Confirma se bate em parede real.
				float t_real;
				vec3 normal_parede;
				
				if (calcular_impacto_real(obs, tx_pos, raio_dir_norm, distancia, t_real, normal_parede)) {
					tem_los = false;

					vec3 ponto_impacto = tx_pos + raio_dir_norm * t_real;
					vec3 direcao_raio_refletido = normalize(reflect(raio_dir_norm, normal_parede));

					processar_trajeto_reflexao(antena.potencia_dbm, antena.freq_mhz,
												ponto_impacto + normal_parede * 0.01,
												direcao_raio_refletido, t_real);
					break;
				}
				// Se calcular_impacto_real devolveu false, o AABB foi cruzado mas nenhuma
				// aresta real foi atingida (raio passou acima/abaixo do prédio). LOS continua.
			}

		}
		
		// Se a linha de visada direta (LOS) estava limpa, computa o sinal direto neste pixel
		if (tem_los) {
			float watts_antena = pow(10.0, (pot_estimada_dbm - 30.0) / 10.0);
			watts_totais += watts_antena;
		}
	}
	
	// Grava o sinal direto limpo que chegou a este pixel receptor
	if (watts_totais > 0.0) {
		atomicAdd(power_map[index_plano], watts_totais);
	}
}
