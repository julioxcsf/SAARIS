#[compute]
#version 450

// Define o bloco local ideal de 16x16 threads (256 núcleos por grupo)
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// 1. Estrutura bruta dos Prédios (Mapeamento exato de 48 bytes do StreamPeerBuffer)
struct ObstaculoGPU {
	vec3 centro;
	float raio_maximo;
	vec3 bounds_min;
	float perda_difracao; //irrelevante no momento
	vec3 bounds_max;
	float coef_reflexao; //util no futuro
};

// 2. Estrutura das Antenas (Mapeamento exato de 32 bytes do seu Stream de TX)
struct AntenaGPU {
	vec3 global_pos;
	float padding_seguranca; // Captura o padding de alinhamento do vec3
	float freq_mhz;
	float potencia_dbm;
	vec2 padding_final;      // Absorve o restante do bloco de 16 bytes
};

// ==============================================================================
//# BINDINGS DOS BUFFERS CONFIGURADOS NO GDSCRIPT
// ==============================================================================
layout(set = 0, binding = 0, std430) readonly buffer ObstaculosBuffer {
	ObstaculoGPU obstaculos[];
};

layout(set = 0, binding = 1, std430) readonly buffer AntenasBuffer {
	AntenaGPU antenas[];
};

layout(set = 0, binding = 2, std430) writeonly buffer MapaSaidaBuffer {
	float power_map[]; // Matriz plana NxN que receberá os Watts finais
};

// ==============================================================================
// # PUSH CONSTANTS (Dados rápidos de controle global)
// ==============================================================================
layout(push_constant) uniform ParametrosGlobais {
	ivec2 map_resolution; // 8 bytes
	vec2 map_size; // 8 bytes
	vec2 map_offset; // 8 bytes
	int total_obstaculos;
	int total_antenas;
}; // Perfeito! 8 variáveis de 4 bytes = 32 bytes exatos, sem perigo de desalinhamento.

float log10(float x) {
	return log(x) / 2.302585092994046; // Otimizado: divisão direta pela constante log(10)
}

vec3 pixel_to_world_position(ivec2 pixel_coord) {
	// Converte a coordenada do pixel para a posição tridimensional do mundo do Saaris
	// (Assumindo tamanho de célula de 0.5m e altura do receptor a 5cm do chão)
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

float FSPL(float distancia, float freq_mhz) {
	// Calcula a perda em espaço livre (Free Space Path Loss) em dB
	return 20.0 * log10(distancia) + 20.0 * log10(freq_mhz) - 27.55;
}

void main() {
	// Captura as coordenadas X, Y do pixel que esta thread física vai processar
	ivec2 pixel_coord = ivec2(gl_GlobalInvocationID.xy);
	
	// ESCUDO DE PROTEÇÃO: Evita invasão de memória se a resolução não for múltipla de 16
	if (pixel_coord.x >= map_resolution.x || pixel_coord.y >= map_resolution.y) {
		return;
	}
	
	// Calcula o índice unidimensional para escrita linear no buffer de saída
	int index_plano = pixel_coord.y * map_resolution.x + pixel_coord.x;
	
	vec3 rx_pos = pixel_to_world_position(pixel_coord);
	
	// Inicializador de potência acumulada em Watts (Todas as contribuições das antenas)
	float watts_totais = 0.0;
	
	// ==========================================================================
	// # LAÇO PRINCIPAL: Processa todas as antenas ativas enviadas pelo TX_Handler
	// ==========================================================================
	for (int t = 0; t < total_antenas; t++) {
		AntenaGPU antena = antenas[t];
		vec3 tx_pos = antena.global_pos;
		
		// Geometria básica do raio TX -> RX
		vec3 raio_vetor = rx_pos - tx_pos;
		float distancia = length(raio_vetor);
		vec3 raio_dir_norm = normalize(raio_vetor);
		
		// Calcula a perda em espaço livre teórica antes de testar colisões caras
		float fspl_db = FSPL(distancia, antena.freq_mhz);
		float pot_estimada_dbm = antena.potencia_dbm - fspl_db;
		
		// --- CORTE RÁPIDO DO SEU ARTIGO: Sensibilidade limite a -120 dBm ---
		// Se o sinal já morre por distância pura, nem gasta tempo testando os prédios!
		if (pot_estimada_dbm < -120.0) {
			continue; 
		}
		
		bool tem_los = true;
		float perda_acumulada_db = 0.0;
		
		// ======================================================================
		// # LAÇO INTERNO: Varre os K prédios brutas ordenados em X
		// ======================================================================
		for (int i = 0; i < total_obstaculos; i++) {
			ObstaculoGPU obs = obstaculos[i];
			
			// Heurística de descarte rápido baseada na sua ordenação em X
			// Se o prédio atual passou muito do limite máximo do raio, quebra o laço!
			if (obs.centro.x > max(tx_pos.x, rx_pos.x) + obs.raio_maximo) {
				break;
			}
			
			// Se o prédio está muito atrás da origem do raio, ignora
			if (obs.centro.x < min(tx_pos.x, rx_pos.x) - obs.raio_maximo) {
				continue;
			}
			
			// --- FILTRO DO EPSILON / MARGEM DE SEGURANÇA ---
			// Ignora o teste se o prédio for a própria carcaça onde a antena está instalada
			if (length(obs.centro - tx_pos) < (obs.raio_maximo + 0.1)) {
				continue;
			}
			
			// --- FILTRO PERPENDICULAR (Se o raio passa perto da caixa do prédio) ---
			vec3 vetor_tx_predio = obs.centro - tx_pos;
			float projecao = dot(vetor_tx_predio, raio_dir_norm);
			float dist_perp_sq = dot(vetor_tx_predio, vetor_tx_predio) - (projecao * projecao);
			
			if (dist_perp_sq > (obs.raio_maximo * obs.raio_maximo)) {
				continue; 
			}
			
			// --- TESTE FINO: Intersecção Raio-AABB (Slab Test de Kay-Kajiya) ---
			vec3 inv_dir = 1.0 / (raio_dir_norm + vec3(1e-6)); // Proteção contra divisão por zero
			vec3 t0 = (obs.bounds_min - tx_pos) * inv_dir;
			vec3 t1 = (obs.bounds_max - tx_pos) * inv_dir;
			
			vec3 tmin = min(t0, t1);
			vec3 tmax = max(t0, t1);
			
			float t_entrada = max(max(tmin.x, tmin.y), tmin.z);
			float t_saida = min(min(tmax.x, tmax.y), tmax.z);

			// Confirmação de colisão física dentro do intervalo do pixel
			if (t_saida >= t_entrada && t_entrada > 0.0 && t_entrada < distancia) {
				tem_los = false;
				perda_acumulada_db += obs.perda_difracao; 
				// Se o seu modelo considerar bloqueio total de primeira, pode colocar um 'break;' aqui
			}
		}
		
		// --- CÁLCULO FÍSICO FINAL DA ANTENA E ACUMULAÇÃO ---
		float pot_final_dbm = antena.potencia_dbm - fspl_db - perda_acumulada_db;
		
		// Garante o piso de sensibilidade do receptor
		if (pot_final_dbm < -120.0) pot_final_dbm = -120.0;
		
		// Converte o resultado de dBm de volta para Watts puros para somar linearmente as energias
		float watts_antena = pow(10.0, (pot_final_dbm - 30.0) / 10.0);
		watts_totais += watts_antena;
	}
	
	// Escreve a energia total recebida de todas as fontes na VRAM de saída
	power_map[index_plano] = watts_totais;
}
