extends Node3D

const MapaRIS = preload("res://Scripts/Simulator/mapa_ris.gd")

## Estado do efeito dos RIS no mapa (power_map_watts = so o resultado da GPU, SEM RIS).
var ris_delta_watts: PackedFloat32Array = PackedFloat32Array()
var ris_por_ris: Array = []
var _mascara_predios: PackedByteArray = PackedByteArray()
var _mascara_chave: String = ""
var _ris_versao: int = 0

# simulador mais rapido com nova engine C++

@onready var node_tx_container = $"../Node_TX"
@onready var node_rx_container = get_node_or_null("../Node_RX")
@onready var node_ris_container = get_node_or_null("../Node_RIS")
@onready var scene_3d_mapa = $"../Scene3D"

@export_group("Cores do Mapa de Calor")
@export var min_sinal_color: Color = Color.BLUE
@export var critical_sinal_color: Color = Color.GREEN
@export var max_sinal_color: Color = Color.RED

@export_group("Shader Compute Selection")
# 2. Exporta a variavel tipada com o Enum. O Godot cria o menu de escolha automaticamente!
@export var shader_selecionado: ShaderCompute = ShaderCompute.REFLEXAO_V2:
	set(valor):
		shader_selecionado = valor
		# Se o jogo ja estiver rodando, recompila automaticamente ao mudar no editor
		if is_inside_tree() and rd:
			compilar_shader_glsl()

enum ShaderCompute {
	FSPL_V1,
	REFLEXAO_V2,
	PERMEABILIDADE_V3,
	DIFRACAO_V4,
	RELEVO_V5
}

# Definicao da struct de configuracao exportavel
class SimulationConfig extends RefCounted:
	@export_group("Simulação - Performance & Qualidade")
	@export var los_ativado: bool = true
	@export var reflection_ativado: bool = true
	@export var diffraction_ativado: bool = true
	@export var pixels_per_frame: int = 1024
	@export var max_reflections: int = 5
	@export var reflection_loss_db: float = 5.0
	@export var offset_collider: float = 0.01
	@export var orcamento_dispatch_ms: float = 250.0   # alvo de duracao de cada despacho da GPU (bem abaixo do timeout/TDR de ~2 s do driver)

	@export_group("Física de Rádio")
	@export var path_loss_exponent: float = 2.8
	@export var potencia_tx_dbm: float = 20.0
	@export var frequencia_mhz: float = 2400.0
	@export var min_sinal_dbm: float = -120.0
	@export var max_sinal_dbm: float = -30.0
	@export var critical_sinal_dbm: float = -85.0
	@export var altura_rx_relevo_m: float = 1.5   # altura do receptor sobre o terreno (v5 com relevo)

class HeatMap:
	var size: Vector2 = Vector2.ZERO      # Tamanho X, Y do plano em metros
	var resolution: Vector2i = Vector2i(256, 256) # Resolucao X, Y em pixels
	var map_offset: Vector2 = Vector2.ZERO        # Posicao global de origem do mapa (AABB.position)
	var map_offset_y_adjusted: float = 0.05       # Deslocamento vertical do chao para o calculo

	# Nos e referencias fisicas da Godot relacionados ao chao/cenario
	var chao_node: MeshInstance3D
	var chao_static_body: StaticBody3D
	var space_state: PhysicsDirectSpaceState3D

	# Buffers de imagem e texturas de renderizacao
	var result_image: Image
	var result_texture: ImageTexture

	# Matrizes lineares de dados brutos trazidos do C++
	var power_map_watts: PackedFloat32Array = []
	var baseline_power_map_watts: PackedFloat32Array = []
	var debug_los_only_watts: PackedFloat32Array = []
	var debug_diff_only_watts: PackedFloat32Array = []


var mapa_calor := HeatMap.new()
var sim_config: SimulationConfig = SimulationConfig.new()

# Infraestrutura nativa de baixo nivel para conversar com o Vulkan
var rd: RenderingDevice
var shader_rid: RID
var _shader_ativo: ShaderCompute = ShaderCompute.REFLEXAO_V2   # shader REALMENTE compilado (v5 pode cair para v4)


func _ready():
	Manager.engine = self

		# 1. Pega o driver central do servidor da Godot 4
	var dispositivo_principal = RenderingServer.get_rendering_device()

	if dispositivo_principal:
		# 2. MAGICA VULKAN: Cria um dispositivo local isolado para computacao pura!
		rd = dispositivo_principal.create_local_device()

		var nome_gpu = rd.get_device_name()
		print("[SAARIS] GPU ativa: ", nome_gpu)
	else:
		push_error("Falha ao inicializar o RenderingDevice Vulkan.")

	compilar_shader_glsl()


func _caminho_shader(qual: ShaderCompute) -> String:
	match qual:
		ShaderCompute.PERMEABILIDADE_V3: return "res://Shaders/saaris_engine_v3_penetracao_linear.glsl"
		ShaderCompute.DIFRACAO_V4: return "res://Shaders/saaris_engine_v4.glsl"
		ShaderCompute.RELEVO_V5: return "res://Shaders/saaris_engine_v5_relevo.glsl"
		ShaderCompute.FSPL_V1: return "res://Shaders/saaris_engine.glsl"
		_: return "res://Shaders/saaris_engine_v2.glsl"


## Compila um shader; retorna RID invalido se falhar (e imprime o log do compilador).
func _compilar_arquivo(caminho: String) -> RID:
	# CACHE_MODE_IGNORE forca a engine a ler o arquivo fisico atualizado no disco
	var shader_file: RDShaderFile = ResourceLoader.load(caminho, "", ResourceLoader.CACHE_MODE_IGNORE)
	if not shader_file:
		push_error("Arquivo de shader não encontrado/importado: " + caminho + " (abra o projeto no editor Godot uma vez para importar)")
		return RID()

	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	var erro_compilacao: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not erro_compilacao.is_empty():
		print("[SAARIS] Erro de compilacao no compute shader: %s" % caminho)
		print(erro_compilacao)
		return RID()

	return rd.shader_create_from_spirv(spirv)


func compilar_shader_glsl() -> void:
	var rid: RID = _compilar_arquivo(_caminho_shader(shader_selecionado))
	_shader_ativo = shader_selecionado

	# A v5 (relevo) cai automaticamente para a v4 se nao compilar, para o simulador continuar utilizavel.
	if not rid.is_valid() and shader_selecionado == ShaderCompute.RELEVO_V5:
		push_warning("[SAARIS] Shader v5 (relevo) falhou; usando v4 SEM relevo. Veja o erro acima.")
		rid = _compilar_arquivo(_caminho_shader(ShaderCompute.DIFRACAO_V4))
		_shader_ativo = ShaderCompute.DIFRACAO_V4

	if not rid.is_valid():
		return

	shader_rid = rid
	print_rich("[color=green]Compute Shader compilado com sucesso (%s). RID: %s[/color]" % [_caminho_shader(_shader_ativo).get_file(), str(shader_rid)])


func atualiza_chao():
	var chao = scene_3d_mapa.find_child("ChaoMapaDeCalor", true, false)
	mapa_calor.chao_node = chao

## Junta TODAS as fontes de transmissores: TX manuais (ligados) + antenas reais
## selecionadas na tabela do GeoManager (Anatel/OSM).
## Cada item: {pos: Vector3, freq: float (MHz), pot: float (dBm)}
## Hardware e tempos da ultima simulacao (usado pelo relatorio).
var info_execucao: Dictionary = {}
var _expoente_usado: float = 2.8     # n efetivo da ultima simulacao (v1-v3 usam 2,8 fixo)
var _altura_rx_usada: float = 0.05   # altura do RX sobre o chao na ultima simulacao


func exponente_efetivo() -> float:
	return _expoente_usado


## Texto (BBCode) com a decomposicao analitica do ponto clicado (ver analise_ponto.gd). "" se fora do mapa.
func texto_analise_ponto(world_pos: Vector3) -> String:
	if mapa_calor.power_map_watts.is_empty() or mapa_calor.size.x <= 0.0 or mapa_calor.size.y <= 0.0:
		return ""
	var u: float = (world_pos.x - mapa_calor.map_offset.x) / mapa_calor.size.x
	var v: float = (world_pos.z - mapa_calor.map_offset.y) / mapa_calor.size.y
	if u < 0.0 or u >= 1.0 or v < 0.0 or v >= 1.0:
		return ""
	var px: int = clampi(int(u * mapa_calor.resolution.x), 0, mapa_calor.resolution.x - 1)
	var py: int = clampi(int(v * mapa_calor.resolution.y), 0, mapa_calor.resolution.y - 1)
	var cx: float = mapa_calor.map_offset.x + (px + 0.5) / mapa_calor.resolution.x * mapa_calor.size.x
	var cz: float = mapa_calor.map_offset.y + (py + 0.5) / mapa_calor.resolution.y * mapa_calor.size.y
	var rx := Vector3(cx, _altura_rx_usada, cz)
	return preload("res://Scripts/Simulator/analise_ponto.gd").texto(self, rx, 0.0, Vector2i(px, py))


func _coletar_antenas() -> Array:
	var lista: Array = []
	if Manager.tx_handler:
		for tx in Manager.tx_handler.tx_cache:
			if not tx.get("ligado"):
				continue
			lista.append({"pos": tx.global_position, "freq": tx.freq_mhz, "pot": tx.potencia_dbm})
	if Manager.geo != null and Manager.geo.has_method("antenas_para_simulacao"):
		for a in Manager.geo.antenas_para_simulacao():
			lista.append(a)
	return lista


## Descarta o resultado anterior (botao "Limpar", troca de regiao/cenario):
## apaga o mapa de potencia e devolve ao chao o material original (sem mapa de calor).
func limpar_resultados() -> void:
	mapa_calor.power_map_watts = PackedFloat32Array()
	ris_delta_watts = PackedFloat32Array()
	ris_por_ris = []
	_mascara_chave = ""
	mapa_calor.result_image = null
	mapa_calor.result_texture = null
	atualiza_chao()
	if is_instance_valid(mapa_calor.chao_node):
		mapa_calor.chao_node.material_override = null
	if Manager.ui_dados != null:
		Manager.ui_dados.limpar()


## Impede que uma simulacao em andamento atravesse uma troca de cenario (o motor e sincrono: so limpa).
func halt_simulator_for_scene_change() -> void:
	limpar_resultados()


## True se ja existe um mapa de potencia calculado.
func tem_resultado() -> bool:
	return not mapa_calor.power_map_watts.is_empty()


## Aplica o dicionario de configuracao do dialogo "Simulador" (e do settings.cfg).
func aplicar_config_simulador(c: Dictionary) -> void:
	sim_config.los_ativado = c.get("los_ativado", sim_config.los_ativado)
	sim_config.reflection_ativado = c.get("reflection_ativado", sim_config.reflection_ativado)
	sim_config.diffraction_ativado = c.get("diffraction_ativado", sim_config.diffraction_ativado)
	sim_config.pixels_per_frame = int(c.get("pixels_per_frame", sim_config.pixels_per_frame))
	sim_config.max_reflections = int(c.get("max_reflections", sim_config.max_reflections))
	sim_config.reflection_loss_db = float(c.get("reflection_loss_db", sim_config.reflection_loss_db))
	sim_config.path_loss_exponent = float(c.get("path_loss_exponent", sim_config.path_loss_exponent))
	sim_config.orcamento_dispatch_ms = clampf(float(c.get("orcamento_dispatch_ms", sim_config.orcamento_dispatch_ms)), 20.0, 1000.0)
	min_sinal_color = c.get("min_sinal_color", min_sinal_color)
	critical_sinal_color = c.get("critical_sinal_color", critical_sinal_color)
	max_sinal_color = c.get("max_sinal_color", max_sinal_color)
	_update_shader_visualization_parameters()


func start_simulation() -> void:
	var t_inicio_total := Time.get_ticks_usec()
	atualiza_chao()

	var usar_v5: bool = (_shader_ativo == ShaderCompute.RELEVO_V5)
	_expoente_usado = sim_config.path_loss_exponent if (_shader_ativo == ShaderCompute.DIFRACAO_V4 or usar_v5) else 2.8
	_altura_rx_usada = sim_config.altura_rx_relevo_m if usar_v5 else 0.05

	# 1. Le os obstaculos da cena e monta o pacote binario da GPU
	var lista_obstaculos = Manager.importer.obstaculos_brutos_cache

	# Ordena os predios espacialmente em X direto pelo GDScript
	lista_obstaculos.sort_custom(func(a, b): return a.centro.x < b.centro.x)

	# 2. gera o buffer no modelo std430 usando como fonte Manager.importer.obstaculos_brutos_cache
	var stream_obstaculos = gerar_buffer_std430_obstaculos()
	if stream_obstaculos.size() == 0:
		stream_obstaculos.resize(64)   # buffer nao pode ter tamanho 0 (regiao sem predios)
	var buffer_obs_rid = rd.storage_buffer_create(stream_obstaculos.size(), stream_obstaculos)

	# 2.1 buffer de tx (manuais + antenas reais selecionadas)
	var antenas: Array = _coletar_antenas()
	if antenas.is_empty():
		Manager.aviso("Nenhuma antena ligada/selecionada: adicione um TX ou marque antenas na tabela.")
		rd.free_rid(buffer_obs_rid)
		return
	var stream_tx = gerar_buffer_std430_tx(antenas)
	print("[SAARIS] %d obstaculos, %d antenas" % [Manager.importer.obstaculos_brutos_cache.size(), antenas.size()])
	var buffer_txs_rid = rd.storage_buffer_create(stream_tx.size(), stream_tx)

	# 2.2 buffer de vertices de obstaculos
	var stream_vertices = gerar_buffer_std430_vertices_obstaculos()
	if stream_vertices.size() == 0:
		stream_vertices.resize(16)
	var buffer_vertices_rid = rd.storage_buffer_create(stream_vertices.size(), stream_vertices)

	# 3. Cria o buffer de saida onde a GPU vai descarregar os Watts
	var total_pixels = mapa_calor.resolution.x * mapa_calor.resolution.y
	var bytes_limpos = PackedByteArray()
	bytes_limpos.resize(total_pixels * 4) # 4 bytes por int32
	bytes_limpos.fill(0) # Forca todos os bits a zero
	var buffer_saida_rid = rd.storage_buffer_create(total_pixels * 4, bytes_limpos) # 4 bytes por float ou int

	# 4. Amarra os buffers nos pinos de conexao (Bindings 0 e 1... etc)

	# buffer binding 0 - saida do compute_shafer
	var uniform_saida := RDUniform.new()
	uniform_saida.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform_saida.binding = 0
	uniform_saida.add_id(buffer_saida_rid)

	#buffer binding 1 - obstaculos
	var uniform_obs := RDUniform.new()
	uniform_obs.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform_obs.binding = 1
	uniform_obs.add_id(buffer_obs_rid)

	# buffer binding 2 - antenas
	var uniform_txs := RDUniform.new()
	uniform_txs.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform_txs.binding = 2
	uniform_txs.add_id(buffer_txs_rid)

	var uniform_obs_vertex := RDUniform.new()
	uniform_obs_vertex.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform_obs_vertex.binding = 3
	uniform_obs_vertex.add_id(buffer_vertices_rid)

	var uniforms: Array[RDUniform] = [uniform_saida, uniform_obs, uniform_txs, uniform_obs_vertex]

	# buffer binding 4 - relevo (somente shader v5)
	var buffer_terreno_rid := RID()
	var terreno_res := Vector2i(2, 2)
	var terreno_hmax := 0.0
	var terreno_hmin := 0.0
	var usar_relevo := 0
	if usar_v5:
		var dados_terreno: Dictionary = _gerar_dados_terreno()
		var bytes_terreno: PackedByteArray = dados_terreno.bytes
		terreno_res = dados_terreno.res
		terreno_hmax = dados_terreno.hmax
		terreno_hmin = dados_terreno.hmin
		usar_relevo = 1 if dados_terreno.usar else 0
		buffer_terreno_rid = rd.storage_buffer_create(bytes_terreno.size(), bytes_terreno)
		var uniform_terreno := RDUniform.new()
		uniform_terreno.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform_terreno.binding = 4
		uniform_terreno.add_id(buffer_terreno_rid)
		uniforms.append(uniform_terreno)
		print("[SAARIS] Relevo: ", "ATIVO" if usar_relevo == 1 else "desligado (cena sem terreno)", " | grade ", terreno_res, " | h ∈ [%.1f, %.1f] m" % [terreno_hmin, terreno_hmax])

	var uniform_set = rd.uniform_set_create(uniforms, shader_rid, 0)


	## 5. Parametros globais (Push Constants). O mapa e calculado em FAIXAS de linhas de blocos 16x16, cada uma num
	## despacho proprio (submit + sync). Assim nenhum despacho passa do timeout do driver (Windows TDR ~ 2 s), que
	## derrubava a simulacao em alta resolucao. So os shaders v4/v5 tem `tile_origem`; os antigos usam um despacho so.
	var em_faixas: bool = (_shader_ativo == ShaderCompute.DIFRACAO_V4 or usar_v5)
	var montar_push := func(origem_y_px: int) -> PackedByteArray:
		var sp := StreamPeerBuffer.new()
		sp.put_32(mapa_calor.resolution.x) # 4 bytes
		sp.put_32(mapa_calor.resolution.y) # 4 bytes
		sp.put_float(mapa_calor.size.x) # 4 bytes
		sp.put_float(mapa_calor.size.y) # 4 bytes
		sp.put_float(mapa_calor.map_offset.x) # 4 bytes
		sp.put_float(mapa_calor.map_offset.y) # 4 bytes
		sp.put_32(lista_obstaculos.size())  # 4 bytes (Total de predios)
		sp.put_32(antenas.size()) # 4 bytes (Total de antenas REALMENTE enviadas ao buffer)
		if usar_v5:
			sp.put_32(terreno_res.x)
			sp.put_32(terreno_res.y)
			sp.put_float(sim_config.altura_rx_relevo_m)
			sp.put_float(terreno_hmax)
			sp.put_float(terreno_hmin)
			sp.put_32(usar_relevo)
			sp.put_32(0) # pad
			sp.put_32(0) # pad
		if em_faixas:
			sp.put_32(0)             # tile_origem.x
			sp.put_32(origem_y_px)   # tile_origem.y
			sp.put_float(sim_config.path_loss_exponent)                          # expoente_perda
			sp.put_float(sim_config.reflection_loss_db)                          # perda_reflexao_db
			sp.put_32(clampi(sim_config.max_reflections, 0, 5))                  # max_reflexoes
			sp.put_32(0)             # pad
			sp.put_32(0)             # pad
			sp.put_32(0)             # pad
		return sp.data_array

	# 6. DISPARA A PLATAFORMA DE COMPUTACAO VULKAN
	var pipeline = rd.compute_pipeline_create(shader_rid)

	# Grade paralela baseada em blocos de 16x16
	var x_groups = ceili(mapa_calor.resolution.x / 16.0)
	var y_groups = ceili(mapa_calor.resolution.y / 16.0)

	var tempo_inicial := Time.get_ticks_usec() # Marca o tempo inicial em microssegundos

	var faixa: int = mini(4, y_groups) if em_faixas else y_groups   # linhas de blocos do 1o despacho (adapta-se depois)
	var y_g: int = 0
	var n_despachos: int = 0
	var maior_despacho_ms: float = 0.0
	var orcamento_us: float = sim_config.orcamento_dispatch_ms * 1000.0
	while y_g < y_groups:
		var n: int = mini(faixa, y_groups - y_g)
		var push: PackedByteArray = montar_push.call(y_g * 16)
		var list = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, pipeline)
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		rd.compute_list_set_push_constant(list, push, push.size())
		rd.compute_list_dispatch(list, x_groups, n, 1)
		rd.compute_list_end()  # fecha a lista de gravacao primeiro
		var t0 := Time.get_ticks_usec()
		rd.submit()            # despacha o pacote fechado
		rd.sync()              # aguarda o silicio terminar ESTA faixa
		var dt_us: float = maxf(float(Time.get_ticks_usec() - t0), 1.0)
		maior_despacho_ms = maxf(maior_despacho_ms, dt_us / 1000.0)
		y_g += n
		n_despachos += 1
		if em_faixas:
			# ajusta o tamanho da proxima faixa para durar ~orcamento (no maximo dobra/metade a cada passo)
			faixa = clampi(int(round(float(n) * clampf(orcamento_us / dt_us, 0.5, 2.0))), 1, y_groups)
			if dt_us / 1000.0 > 1500.0:
				push_warning("[SAARIS] Um despacho da GPU levou %.0f ms (perto do timeout do driver). Reduza a resolução ou aumente o TdrDelay do Windows." % (dt_us / 1000.0))

	var tempo_final := Time.get_ticks_usec()
	var tempo_gpu_milissegundos : float = (tempo_final - tempo_inicial) / 1000.0

	info_execucao = {
		"gpu": rd.get_device_name(), "gpu_fabricante": rd.get_device_vendor_name(),
		"cpu": OS.get_processor_name(), "cpu_threads": OS.get_processor_count(),
		"so": OS.get_name(), "tempo_gpu_ms": tempo_gpu_milissegundos,
		"despachos": n_despachos, "maior_despacho_ms": maior_despacho_ms,
	}

	# 7. Resgata os watts da placa e atualiza a textura visual do chao
	var bytes_resultado = rd.buffer_get_data(buffer_saida_rid)
	var power_map = bytes_resultado.to_float32_array() # Decodifica os bytes para Floats nativos!

	# Guarda uma copia na RAM para consultas posteriores.
	mapa_calor.power_map_watts = power_map.duplicate()

	print("[SAARIS] GPU: %.0f ms em %d despachos (maior %.0f ms, orcamento %.0f ms)" % [tempo_gpu_milissegundos, n_despachos, maior_despacho_ms, sim_config.orcamento_dispatch_ms])

	ris_delta_watts = PackedFloat32Array()
	_renderizar_imagem_final_float(power_map)
	atualizar_mapa_ris()
	if Manager.ui_dados != null:
		Manager.ui_dados.atualizar_estatisticas(estatisticas_mapa(sim_config.critical_sinal_dbm))
	info_execucao["tempo_total_ms"] = (Time.get_ticks_usec() - t_inicio_total) / 1000.0

	# 8. Limpa a VRAM para a proxima execucao
	rd.free_rid(buffer_saida_rid)
	rd.free_rid(buffer_obs_rid)
	rd.free_rid(buffer_txs_rid)
	rd.free_rid(buffer_vertices_rid)
	if buffer_terreno_rid.is_valid():
		rd.free_rid(buffer_terreno_rid)
	rd.free_rid(pipeline)


## Heightfield em bytes para a GPU. Se a cena nao for geo (ex.: Candelaria), manda uma grade 2x2 zerada
## e usar=false (a v5 se comporta exatamente como a v4).
func _gerar_dados_terreno() -> Dictionary:
	var t: Dictionary = {}
	if Manager.importer and "geo_ativo" in Manager.importer and Manager.importer.geo_ativo:
		t = Manager.importer.geo_terrain
	if t.is_empty():
		var vazio := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
		return {"bytes": vazio.to_byte_array(), "res": Vector2i(2, 2), "hmin": 0.0, "hmax": 0.0, "usar": false}
	var hs: PackedFloat32Array = t.heights
	return {"bytes": hs.to_byte_array(), "res": Vector2i(t.res, t.res), "hmin": t.hmin, "hmax": t.hmax, "usar": true}


## Gera o buffer no formato std430 (formato binario rigido de 16 bytes) que sao usados na GPU
func gerar_buffer_std430_obstaculos() -> PackedByteArray:
	var stream := StreamPeerBuffer.new()

	for obs in Manager.importer.obstaculos_brutos_cache:
		# Bloco 1: centro + raio
		stream.put_float(obs.centro.x)
		stream.put_float(obs.centro.y)
		stream.put_float(obs.centro.z)
		stream.put_float(obs.raio_maximo)

		# Bloco 2: bounds_min + perda
		stream.put_float(obs.bounds_min.x)
		stream.put_float(obs.bounds_min.y)
		stream.put_float(obs.bounds_min.z)
		stream.put_float(obs.perda_difracao)

		# Bloco 3: bounds_max + reflexao
		stream.put_float(obs.bounds_max.x)
		stream.put_float(obs.bounds_max.y)
		stream.put_float(obs.bounds_max.z)
		stream.put_float(obs.coef_reflexao)

		# Bloco 4 (16 bytes): metadados de indexacao
		stream.put_32(obs.vertex_offset)
		stream.put_32(obs.vertex_count)
		stream.put_32(obs.id)
		stream.put_32(0)  # padding

	return stream.data_array

func gerar_buffer_std430_tx(antenas: Array) -> PackedByteArray:
	var stream := StreamPeerBuffer.new()

	for a in antenas:
		var pos: Vector3 = a.pos
		# Bloco 1 (16 bytes): position
		stream.put_float(pos.x)
		stream.put_float(pos.y)
		stream.put_float(pos.z)
		stream.put_float(0.0)                  # 4 bytes -> PADDING OBRIGATORIO VULKAN!

		# Bloco 2 (16 bytes):
		stream.put_float(a.freq)
		stream.put_float(a.pot)
		stream.put_float(0.0)
		stream.put_float(0.0)

	return stream.data_array

func gerar_buffer_std430_vertices_obstaculos() -> PackedByteArray:
	var stream := StreamPeerBuffer.new()

	for vector in Manager.importer.obstaculos_completos_cache:
		stream.put_float(vector.x) # x do vertice de um ponto do obstaculo
		stream.put_float(vector.y) # y do vertice ...
		stream.put_float(vector.z) # z do vertice ...
		stream.put_float(vector.w) # e o Id do objeto

	return stream.data_array


func _renderizar_imagem_final_float(power_map_floats: PackedFloat32Array) -> void:
	# 1. Imagem de alta precisao (FORMAT_RF: um float de 32 bits por pixel = dBm, lido pelo .gdshader)
	var n: int = mapa_calor.resolution.x * mapa_calor.resolution.y
	var dbm_arr := PackedFloat32Array()
	dbm_arr.resize(n)
	var inv_ln10: float = 1.0 / log(10.0)
	for i in mini(n, power_map_floats.size()):
		var watts: float = power_map_floats[i]
		# dBm SEM clamp de escala: o shader do chao satura sozinho, e assim da para recolorir ao vivo.
		dbm_arr[i] = -120.0 if watts <= 0.0 else clampf(10.0 * log(watts) * inv_ln10 + 30.0, -200.0, 200.0)
	var img: Image = Image.create_from_data(mapa_calor.resolution.x, mapa_calor.resolution.y, false, Image.FORMAT_RF, dbm_arr.to_byte_array())
	if mapa_calor.result_texture == null or mapa_calor.result_image == null or mapa_calor.result_image.get_size() != mapa_calor.resolution:
		mapa_calor.result_image = img
		mapa_calor.result_texture = ImageTexture.create_from_image(img)
	else:
		mapa_calor.result_image = img

	# 3. Atualiza a textura na memoria de renderizacao da Godot
	mapa_calor.result_texture.update(mapa_calor.result_image)

	# 4. Injeta a textura gerada diretamente no material do chao
	if mapa_calor.chao_node:
		# Se o override estiver vazio ou nao for um ShaderMaterial, nos criamos um do zero!
		var material = mapa_calor.chao_node.material_override as ShaderMaterial

		if not material:
			material = ShaderMaterial.new()
			# Carrega o seu arquivo .gdshader que criamos
			material.shader = load("res://Shaders/mapa_calor_shader_material.gdshader")
			# Aplica no override (ele passa por cima do material verde do importador)
			mapa_calor.chao_node.material_override = material

		material.set_shader_parameter("signal_map", mapa_calor.result_texture)
		_update_shader_visualization_parameters()

	else:
		push_error("[SAARIS ERRO] mapa_calor.chao_node está NULO! O simulador não sabe onde injetar o mapa visual.")

# EFEITO DOS RIS NO MAPA

## Mascara (1 = predio) na resolucao da simulacao, com a pegada REAL dos predios.
func mascara_predios() -> PackedByteArray:
	var res: Vector2i = mapa_calor.resolution
	var chave: String = "%s|%s|%s|%d" % [res, mapa_calor.size, mapa_calor.map_offset,
		Manager.importer.obstaculos_brutos_cache.size() if Manager.importer != null else 0]
	if chave != _mascara_chave or _mascara_predios.size() != res.x * res.y:
		_mascara_predios = MapaRIS.rasterizar_predios(res.x, res.y, mapa_calor.size, mapa_calor.map_offset)
		_mascara_chave = chave
	return _mascara_predios

## Mapa (W) com os RIS: base da GPU + contribuicao dos RIS. `incluir_desligados` conta tambem os desligados.
func mapa_com_ris(incluir_desligados: bool = false) -> Dictionary:
	var base: PackedFloat32Array = mapa_calor.power_map_watts
	if base.is_empty():
		return {"mapa": base, "por_ris": []}
	var d: Dictionary = MapaRIS.delta_ris(self, base, mascara_predios(), incluir_desligados)
	var soma: PackedFloat32Array = base.duplicate()
	var delta: PackedFloat32Array = d.total
	for i in soma.size():
		soma[i] += delta[i]
	return {"mapa": soma, "delta": delta, "por_ris": d.por_ris}

## Recalcula o efeito dos RIS LIGADOS e atualiza a textura do chao (a regiao iluminada muda de cor).
func atualizar_mapa_ris() -> void:
	if not tem_resultado():
		return
	var r: Dictionary = mapa_com_ris(false)
	ris_delta_watts = r.delta
	ris_por_ris = r.por_ris
	_renderizar_imagem_final_float(r.mapa)
	if Manager.ui_dados != null:
		Manager.ui_dados.atualizar_estatisticas(estatisticas_mapa(sim_config.critical_sinal_dbm, r.mapa))

## Pede a atualizacao com um pequeno atraso (junta varias mudancas seguidas, ex.: arrastar um spinbox).
func agendar_mapa_ris() -> void:
	if not tem_resultado() or not is_inside_tree():
		return
	_ris_versao += 1
	var v: int = _ris_versao
	await get_tree().create_timer(0.25).timeout
	if v == _ris_versao and tem_resultado():
		atualizar_mapa_ris()


# Coleta a potencia no pixel correspondente a posicao de mundo solicitada.
func get_power_at_pixel(pixel: Vector2i) -> float:
	if mapa_calor.power_map_watts.is_empty():
		return -200.0

	if pixel.x < 0 or pixel.x >= mapa_calor.resolution.x:
		return -200.0

	if pixel.y < 0 or pixel.y >= mapa_calor.resolution.y:
		return -200.0

	var index := pixel.y * mapa_calor.resolution.x + pixel.x
	var watts := mapa_calor.power_map_watts[index]
	if ris_delta_watts.size() == mapa_calor.power_map_watts.size():
		watts += ris_delta_watts[index]            # a ponteira le o mapa COM o efeito dos RIS ligados

	if watts <= 0.0:
		return -200.0

	return 10.0 * log(watts) / log(10.0) + 30.0

func get_power_at_world_pos(world_pos: Vector3) -> float:
	if mapa_calor.power_map_watts.is_empty():
		return -200.0

	if mapa_calor.size.x <= 0.0 or mapa_calor.size.y <= 0.0:
		push_error("[SAARIS] Tamanho do mapa de calor inválido.")
		return -200.0

	# Posicao relativa a origem fisica do mapa.
	var local_x := world_pos.x - mapa_calor.map_offset.x
	var local_z := world_pos.z - mapa_calor.map_offset.y

	# Normaliza para 0..1.
	var u := local_x / mapa_calor.size.x
	var v := local_z / mapa_calor.size.y

	# Fora do mapa.
	if u < 0.0 or u >= 1.0 or v < 0.0 or v >= 1.0:
		return -200.0

	var px := int(u * mapa_calor.resolution.x)
	var py := int(v * mapa_calor.resolution.y)

	px = clamp(px, 0, mapa_calor.resolution.x - 1)
	py = clamp(py, 0, mapa_calor.resolution.y - 1)

	return get_power_at_pixel(Vector2i(px, py))


func update_power_limits(min_val : float, crit_val : float , max_val : float ):
	sim_config.max_sinal_dbm = max_val
	sim_config.critical_sinal_dbm = crit_val
	sim_config.min_sinal_dbm = min_val
	_update_shader_visualization_parameters()      # recolore o mapa ja calculado, na hora

# CONSULTAS AO MAPA DE POTENCIA (usadas pelo painel de dados e pelo relatorio)

static func _w_para_dbm(w: float) -> float:
	return 10.0 * log(w) / log(10.0) + 30.0 if w > 0.0 else -200.0

## Estatisticas do mapa: cobertura (% de pixels com potencia >= limiar), min/media/max, tamanho, resolucao.
func estatisticas_mapa(limiar_dbm: float, mapa: PackedFloat32Array = PackedFloat32Array(), so_chao: bool = false) -> Dictionary:
	var w: PackedFloat32Array = mapa if not mapa.is_empty() else mapa_calor.power_map_watts
	if so_chao and not w.is_empty():
		var m: PackedByteArray = mascara_predios()
		var f := PackedFloat32Array()
		for i in w.size():
			if m[i] == 0:
				f.append(w[i])
		w = f
	var res: Vector2i = mapa_calor.resolution
	var out := {
		"valido": not w.is_empty(),
		"limiar_dbm": limiar_dbm,
		"terrain_size": mapa_calor.size,
		"resolution": res,
		"res_m_px": Vector2(mapa_calor.size.x / maxf(1.0, res.x), mapa_calor.size.y / maxf(1.0, res.y)),
		"cobertura_pct": 0.0, "pixels": w.size(), "acima": 0,
		"min_dbm": -200.0, "max_dbm": -200.0, "media_dbm": -200.0,
	}
	if w.is_empty():
		return out
	var lim_w: float = pow(10.0, (limiar_dbm - 30.0) / 10.0)
	var acima: int = 0
	var soma: float = 0.0
	var mx: float = 0.0
	var mn: float = INF
	for v in w:
		if v >= lim_w:
			acima += 1
		soma += v
		if v > mx: mx = v
		if v < mn: mn = v
	out.acima = acima
	out.cobertura_pct = 100.0 * float(acima) / float(w.size())
	out.min_dbm = _w_para_dbm(mn)
	out.max_dbm = _w_para_dbm(mx)
	out.media_dbm = _w_para_dbm(soma / float(w.size()))      # media linear (W) convertida
	return out


## Potencia media (dBm, media em Watts) dentro de uma regiao retangular (centro XZ, largura, comprimento, giro em Y).
## Se nenhum pixel cai dentro, usa o pixel do centro. {dbm, pixels, fora_do_mapa}
func potencia_na_regiao(centro: Vector3, largura: float, comprimento: float, rot_graus: float, mapa: PackedFloat32Array = PackedFloat32Array()) -> Dictionary:
	var res: Vector2i = mapa_calor.resolution
	var w: PackedFloat32Array = mapa if not mapa.is_empty() else mapa_calor.power_map_watts
	if w.is_empty() or mapa_calor.size.x <= 0.0 or mapa_calor.size.y <= 0.0:
		return {"dbm": -200.0, "pixels": 0, "fora_do_mapa": true}

	var px_m := Vector2(mapa_calor.size.x / res.x, mapa_calor.size.y / res.y)
	var meio := Vector2(largura, comprimento) * 0.5
	var ang: float = deg_to_rad(rot_graus)
	var raio: float = meio.length()
	var u0: int = floori((centro.x - raio - mapa_calor.map_offset.x) / px_m.x)
	var u1: int = floori((centro.x + raio - mapa_calor.map_offset.x) / px_m.x)
	var v0: int = floori((centro.z - raio - mapa_calor.map_offset.y) / px_m.y)
	var v1: int = floori((centro.z + raio - mapa_calor.map_offset.y) / px_m.y)

	var soma: float = 0.0
	var n: int = 0
	var c: float = cos(ang)
	var sn: float = sin(ang)
	for v in range(maxi(v0, 0), mini(v1, res.y - 1) + 1):
		for u in range(maxi(u0, 0), mini(u1, res.x - 1) + 1):
			var dx: float = (u + 0.5) * px_m.x + mapa_calor.map_offset.x - centro.x
			var dz: float = (v + 0.5) * px_m.y + mapa_calor.map_offset.y - centro.z
			# gira o ponto para o referencial do RX (rotation_degrees.y do Godot)
			var lx: float = dx * c - dz * sn
			var lz: float = dx * sn + dz * c
			if absf(lx) <= meio.x and absf(lz) <= meio.y:
				soma += w[v * res.x + u]
				n += 1
	if n > 0:
		return {"dbm": _w_para_dbm(soma / float(n)), "pixels": n, "fora_do_mapa": false}

	var dbm: float = get_power_at_world_pos(centro)
	return {"dbm": dbm, "pixels": 1 if dbm > -200.0 else 0, "fora_do_mapa": dbm <= -200.0}


# SNAPSHOT (Save / Load) - sem sinais: o Manager chama estas duas funcoes direto

func get_simulation_snapshot() -> Dictionary:
	var antenas: Array = []
	if Manager.tx_handler:
		for tx in Manager.tx_handler.tx_cache:
			antenas.append({"posicao": tx.position, "potencia": tx.potencia_dbm,
				"freq": tx.freq_mhz, "ligado": tx.ligado})
	var receptores: Array = []
	if Manager.rx_handler:
		for i in Manager.rx_handler.rx_cache.size():
			receptores.append(Manager.rx_handler.get_rx_info(i))
	var ris_lista: Array = []
	if Manager.ris_handler:
		for i in Manager.ris_handler.ris_cache.size():
			var d: Dictionary = Manager.ris_handler.get_ris_info(i)
			ris_lista.append({"posicao": d.posicao, "ligado": d.ligado, "freq_mhz": d.freq_mhz,
				"eficiencia": d.eficiencia, "cell_n": d.cell_n, "cell_m": d.cell_m,
				"ganho_fixo": d.ganho_fixo, "alvo_index": d.alvo_index, "modo_feixe": d.get("modo_feixe", "regiao")})
	var snap := {
		"versao": 2,
		"resolution": mapa_calor.resolution,
		"heatmap": {"min": sim_config.min_sinal_dbm, "crit": sim_config.critical_sinal_dbm, "max": sim_config.max_sinal_dbm},
		"antenas": antenas,
		"receptores": receptores,
		"refletores_ris": ris_lista,
	}
	if Manager.ui_relatorio != null:
		snap["relatorio"] = Manager.ui_relatorio.get_config()
	# mapa de potencia (Watts), igual ao save antigo: permite gerar relatorio logo apos carregar.
	# Acima de 2048x2048 pixels (16 MB) nao e gravado para nao inflar o arquivo.
	if tem_resultado() and mapa_calor.power_map_watts.size() <= 2048 * 2048:
		snap["power_array"] = mapa_calor.power_map_watts
		snap["plane_size"] = mapa_calor.size
		snap["osm_offset"] = mapa_calor.map_offset
	return snap


## Recria TX/RX/RIS (e o mapa de potencia, se estiver no save) a partir de um snapshot.
## Aceita o formato novo (antenas / receptores / refletores_ris) e o antigo (tx_list / rx_list / ris_list).
func apply_simulation_snapshot(snap: Dictionary) -> void:
	Manager.limpar_cena_dinamica()
	limpar_resultados()

	if snap.has("resolution"):
		var r = snap["resolution"]
		var res: Vector2i = mapa_calor.resolution
		if r is Vector2i: res = r
		elif r is Vector2: res = Vector2i(r)
		elif r is Array and r.size() >= 2: res = Vector2i(int(r[0]), int(r[1]))
		mapa_calor.resolution = res
		if Manager.ui_resolucao != null:
			Manager.ui_resolucao.refletir_resolucao(res)

	# limites de cor: formato novo (heatmap{}) ou antigo (min_dbm/crit_dbm/max_dbm no topo)
	var h: Dictionary = snap.get("heatmap", {})
	var lim_min: float = h.get("min", snap.get("min_dbm", sim_config.min_sinal_dbm))
	var lim_crit: float = h.get("crit", snap.get("crit_dbm", sim_config.critical_sinal_dbm))
	var lim_max: float = h.get("max", snap.get("max_dbm", sim_config.max_sinal_dbm))
	update_power_limits(lim_min, lim_crit, lim_max)

	for a in snap.get("antenas", snap.get("tx_list", snap.get("tx", []))):
		if Manager.tx_handler == null: break
		var r1: Dictionary = Manager.tx_handler.add_tx()
		Manager.tx_handler.update_tx(r1.index, {
			"posicao": a.get("posicao", a.get("pos", Vector3(0, 30, 0))),
			"potencia": a.get("potencia", a.get("power", a.get("potencia_dbm", 40.0))),
			"freq": a.get("freq", a.get("freq_mhz", 2400.0)),
			"ligado": a.get("ligado", a.get("active", true))})

	for r in snap.get("receptores", snap.get("rx_list", snap.get("rx", []))):
		if Manager.rx_handler == null: break
		Manager.rx_handler.add_rx(r)             # update_rx entende posicao/pos, width, length, rotation

	for q in snap.get("refletores_ris", snap.get("ris_list", snap.get("ris", []))):
		if Manager.ris_handler == null: break
		var p: Dictionary = {}
		for k in ["ligado", "freq_mhz", "eficiencia", "ganho_fixo", "alvo_index", "modo_feixe"]:
			if q.has(k): p[k] = q[k]
		p["posicao"] = q.get("posicao", q.get("pos", Vector3(0, 5, 0)))
		if q.has("cell_n"): p["cell_n"] = int(q["cell_n"])
		if q.has("cell_m"): p["cell_m"] = int(q["cell_m"])
		Manager.ris_handler.add_ris(p)           # sem alvo_index (save antigo): alvo = primeiro RX

	if snap.has("relatorio") and Manager.ui_relatorio != null:
		Manager.ui_relatorio.set_config(snap["relatorio"])

	# mapa de potencia salvo (Watts): so vale se o tamanho do mapa carregado bate com o do save
	if snap.has("power_array"):
		var arr: PackedFloat32Array = snap["power_array"]
		var res2: Vector2i = mapa_calor.resolution
		var confere: bool = arr.size() == res2.x * res2.y
		if confere and snap.has("plane_size") and mapa_calor.size.x > 0.0:
			confere = (snap["plane_size"] as Vector2).distance_to(mapa_calor.size) < 2.0
		if confere:
			mapa_calor.power_map_watts = arr.duplicate()
			atualiza_chao()
			if is_instance_valid(mapa_calor.chao_node):
				_renderizar_imagem_final_float(arr)
				atualizar_mapa_ris()
			if Manager.ui_dados != null:
				Manager.ui_dados.atualizar_estatisticas(estatisticas_mapa(sim_config.critical_sinal_dbm))
		else:
			push_warning("[SAARIS] O mapa de potência do save não confere com o cenário carregado; rode Start novamente.")

	for painel in [Manager.ui_tx, Manager.ui_rx, Manager.ui_ris]:
		if painel != null:
			painel.recarregar()


## Busca binaria pela extremidade de uma malha para calcular a difracao.


## Converte a posicao 3D para o pixel da textura e pinta o valor bruto.


#
#
## Atualiza as cores do mapa termico direto no hardware grafico.
func _update_shader_visualization_parameters() -> void:
	if not is_instance_valid(mapa_calor.chao_node):
		return

	var material := mapa_calor.chao_node.material_override as ShaderMaterial
	if not material:
		return

	material.set_shader_parameter("min_color", min_sinal_color)
	material.set_shader_parameter("critical_color", critical_sinal_color)
	material.set_shader_parameter("max_color", max_sinal_color)

	material.set_shader_parameter("min_sinal_dbm", sim_config.min_sinal_dbm)
	material.set_shader_parameter("critical_sinal_dbm", sim_config.critical_sinal_dbm)
	material.set_shader_parameter("max_sinal_dbm", sim_config.max_sinal_dbm)
