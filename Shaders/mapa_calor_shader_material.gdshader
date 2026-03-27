// mapa_calor_shader_material.gdshader
shader_type spatial;

// A textura com os resultados pré-calculados pelo nosso motor
uniform sampler2D signal_map;

uniform vec4 min_color : source_color;
uniform vec4 critical_color : source_color;
uniform vec4 max_color : source_color;

uniform float min_sinal_dbm;
uniform float critical_sinal_dbm; // NOVO VALOR
uniform float max_sinal_dbm;

varying vec2 uv_coords; // Passaremos a coordenada UV do vertex para o fragment

void vertex() {
	// Passa a coordenada de textura (UV) do vértice para o fragment shader
	uv_coords = UV;
}

void fragment() {
	// 1. Lê a potência do sinal em dBm (o valor bruto)
	float sinal_dbm = texture(signal_map, uv_coords).r;

	// 2. Calcula os dois gradientes usando smoothstep (seguro contra divisão por zero)
	// Gradiente inferior (Azul -> Verde): Mapeia o intervalo [min, critico] para [0, 1]
	float lower_strength = smoothstep(min_sinal_dbm, critical_sinal_dbm, sinal_dbm);
	vec3 lower_color = mix(min_color.rgb, critical_color.rgb, lower_strength);

	// Gradiente superior (Verde -> Vermelho): Mapeia o intervalo [critico, max] para [0, 1]
	float upper_strength = smoothstep(critical_sinal_dbm, max_sinal_dbm, sinal_dbm);
	vec3 upper_color = mix(critical_color.rgb, max_color.rgb, upper_strength);

	// 3. Escolhe qual gradiente usar.
	// Se sinal_dbm > critical_sinal_dbm, então upper_strength > 0.
	float selector = step(critical_sinal_dbm, sinal_dbm);
	vec3 final_color = mix(lower_color, upper_color, selector);

	ALBEDO = final_color;
}