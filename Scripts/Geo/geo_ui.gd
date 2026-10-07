extends PanelContainer
## Painel "Mapa real": origem lat/lon, tamanho da regiao, camadas (relevo, OSM,
## antenas), parametros das antenas e importacao/baixa da base da Anatel.
## Montado por codigo (nao altera o gui.tscn). Fica no canto superior direito.

const AntennaTable = preload("res://Scripts/Geo/antenna_table.gd")

var geo: Node = null

var _body: VBoxContainer
var _lbl_status: Label
var _lbl_anatel: Label
var _spin_lat: SpinBox
var _spin_lon: SpinBox
var _chk_follow: CheckButton
var _tabela: Window = null
var _file_dialog: FileDialog
var _dl: HTTPRequest = null
var _dl_path: String = ""
var _le_url: LineEdit
var _lbl_pacote: Label
var _fd_pacote: FileDialog


func _ready() -> void:
	# Ancora: canto superior direito, abaixo da barra de topo
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 0.0
	offset_left = -352.0
	offset_right = -10.0
	offset_top = 74.0
	offset_bottom = 74.0
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grow_vertical = Control.GROW_DIRECTION_END

	var margem: MarginContainer = MarginContainer.new()
	for lado in ["left", "right", "top", "bottom"]:
		margem.add_theme_constant_override("margin_" + lado, 8)
	add_child(margem)

	var raiz: VBoxContainer = VBoxContainer.new()
	raiz.add_theme_constant_override("separation", 5)
	margem.add_child(raiz)

	# --- cabecalho recolhivel ---
	var cab: HBoxContainer = HBoxContainer.new()
	raiz.add_child(cab)
	var t: Label = Label.new()
	t.text = "🌍 Mapa real"
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cab.add_child(t)
	var b_col: Button = Button.new()
	b_col.text = "▾"
	b_col.focus_mode = Control.FOCUS_NONE
	b_col.pressed.connect(func():
		_body.visible = not _body.visible
		b_col.text = "▾" if _body.visible else "▸")
	cab.add_child(b_col)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 5)
	raiz.add_child(_body)

	# --- pacote SAARIS Data Source ---
	_body.add_child(_rotulo("Pacote SAARIS (relevo + prédios casados)"))
	_lbl_pacote = Label.new()
	_lbl_pacote.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_pacote.custom_minimum_size = Vector2(320, 0)
	_body.add_child(_lbl_pacote)
	var hp: HBoxContainer = HBoxContainer.new()
	_body.add_child(hp)
	var b_pk: Button = Button.new()
	b_pk.text = "Importar pacote…"
	b_pk.tooltip_text = "Escolha o manifesto.json (ou o .zip) gerado pela página SAARIS_DataSource/index.html"
	b_pk.pressed.connect(func(): _fd_pacote.popup_centered(Vector2i(900, 560)))
	hp.add_child(b_pk)
	var b_on: Button = Button.new()
	b_on.text = "Voltar ao online"
	b_on.tooltip_text = "Deixa de usar o pacote: relevo e prédios voltam a ser baixados (cache em GeoCache/)"
	b_on.pressed.connect(func(): geo.sair_do_pacote())
	hp.add_child(b_on)
	b_pk.focus_mode = Control.FOCUS_NONE
	b_on.focus_mode = Control.FOCUS_NONE
	_fd_pacote = FileDialog.new()
	_fd_pacote.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_fd_pacote.access = FileDialog.ACCESS_FILESYSTEM
	_fd_pacote.use_native_dialog = true
	_fd_pacote.title = "Pacote SAARIS Data Source (manifesto.json ou .zip)"
	_fd_pacote.filters = PackedStringArray(["*.json, *.zip ; Pacote SAARIS"])
	_fd_pacote.file_selected.connect(func(pth: String): geo.importar_pacote(pth))
	add_child(_fd_pacote)
	_body.add_child(HSeparator.new())

	# --- origem ---
	_body.add_child(_rotulo("Origem (lat, lon) — padrão: Ilha do Fundão"))
	var h1: HBoxContainer = HBoxContainer.new()
	_body.add_child(h1)
	_spin_lat = _spin(-90.0, 90.0, 0.0001, geo.frame.lat0)
	_spin_lon = _spin(-180.0, 180.0, 0.0001, geo.frame.lon0)
	h1.add_child(_spin_lat)
	h1.add_child(_spin_lon)
	var b_ir: Button = Button.new()
	b_ir.text = "Ir"
	b_ir.tooltip_text = "Move a origem para estas coordenadas e carrega a região (relevo + OSM + antenas)"
	b_ir.pressed.connect(func(): geo.ir_para(_spin_lat.value, _spin_lon.value))
	h1.add_child(b_ir)

	# --- regiao ---
	var h2: HBoxContainer = HBoxContainer.new()
	_body.add_child(h2)
	h2.add_child(_rotulo("Região (km):"))
	var s_reg: SpinBox = _spin(0.5, 6.0, 0.5, geo.tamanho_regiao_m / 1000.0)
	s_reg.tooltip_text = "Lado do quadrado carregado/simulado. 2 km = 2x2 km²."
	s_reg.value_changed.connect(func(v: float): geo.aplicar_tamanho_regiao(v * 1000.0))
	h2.add_child(s_reg)
	h2.add_child(_rotulo("  Alt. RX (m):"))
	var s_rx: SpinBox = _spin(0.05, 30.0, 0.05, Manager.engine.sim_config.altura_rx_relevo_m if Manager.engine else 1.5)
	s_rx.tooltip_text = "Altura do receptor sobre o terreno (usada com relevo). Sem relevo, o receptor fica a 5 cm."
	s_rx.value_changed.connect(func(v: float): if Manager.engine: Manager.engine.sim_config.altura_rx_relevo_m = v)
	h2.add_child(s_rx)

	# --- streaming: chunks ---
	var h2b: HBoxContainer = HBoxContainer.new()
	_body.add_child(h2b)
	h2b.add_child(_rotulo("Chunk (m):"))
	var s_chunk: SpinBox = _spin(100.0, 2000.0, 100.0, geo.tamanho_chunk_m)
	s_chunk.tooltip_text = "A região recarrega saltando de chunk em chunk quando a câmera anda."
	s_chunk.value_changed.connect(func(v: float): geo.tamanho_chunk_m = v; geo.salvar_config())
	h2b.add_child(s_chunk)
	h2b.add_child(_rotulo("  Pré-carga:"))
	var s_pre: SpinBox = _spin(0, 6, 1, geo.chunks_pre_carregados)
	s_pre.tooltip_text = "Chunks baixados em segundo plano ao redor da região, em cada direção (0 = desliga)."
	s_pre.value_changed.connect(func(v: float): geo.chunks_pre_carregados = int(v); geo.salvar_config())
	h2b.add_child(s_pre)

	# --- camadas ---
	_body.add_child(_chk("Relevo (elevação)", geo.usar_relevo, func(p: bool): geo.usar_relevo = p; _aplicar_camadas()))
	_body.add_child(_chk("Prédios e ruas (OSM)", geo.usar_osm, func(p: bool): geo.usar_osm = p; _aplicar_camadas()))
	_body.add_child(_chk("Antenas (Anatel + torres OSM)", geo.usar_antenas, func(p: bool): geo.usar_antenas = p; _aplicar_camadas()))
	_chk_follow = _chk("Seguir câmera (região acompanha o que você vê)", geo.seguir_camera, func(p: bool): geo.seguir_camera = p)
	_body.add_child(_chk_follow)

	# --- acoes ---
	var h3: HBoxContainer = HBoxContainer.new()
	_body.add_child(h3)
	var b_aqui: Button = Button.new()
	b_aqui.text = "Carregar aqui"
	b_aqui.tooltip_text = "Carrega a região que está no centro da tela"
	b_aqui.pressed.connect(func(): geo.recarregar_aqui())
	h3.add_child(b_aqui)
	var b_tab: Button = Button.new()
	b_tab.text = "Tabela de antenas…"
	b_tab.pressed.connect(_abrir_tabela)
	h3.add_child(b_tab)

	_lbl_status = Label.new()
	_lbl_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_status.custom_minimum_size = Vector2(320, 0)
	_lbl_status.text = geo.status()
	_body.add_child(_lbl_status)

	_body.add_child(HSeparator.new())

	# --- parametros das antenas reais ---
	_body.add_child(_rotulo("Antenas reais na simulação"))
	var h4: HBoxContainer = HBoxContainer.new()
	_body.add_child(h4)
	h4.add_child(_rotulo("Pot. (dBm):"))
	var s_pot: SpinBox = _spin(1.0, 100.0, 1.0, geo.potencia_padrao_dbm)
	s_pot.tooltip_text = "EIRP omni usada para cada antena marcada (a base da Anatel não traz EIRP confiável)."
	s_pot.value_changed.connect(func(v: float): geo.potencia_padrao_dbm = v; geo.salvar_config())
	h4.add_child(s_pot)
	h4.add_child(_rotulo(" Alt. (m):"))
	var s_alt: SpinBox = _spin(3.0, 150.0, 1.0, geo.altura_padrao_antena_m)
	s_alt.tooltip_text = "Altura padrão da antena sobre o terreno quando o registro não informa."
	s_alt.value_changed.connect(func(v: float): geo.altura_padrao_antena_m = v; geo.salvar_config())
	h4.add_child(s_alt)
	var h5: HBoxContainer = HBoxContainer.new()
	_body.add_child(h5)
	h5.add_child(_rotulo("Freq. padrão (MHz):"))
	var s_f: SpinBox = _spin(100.0, 6000.0, 50.0, geo.freq_padrao_mhz)
	s_f.tooltip_text = "Usada em registros sem frequência (ex.: torres do OSM)."
	s_f.value_changed.connect(func(v: float): geo.freq_padrao_mhz = v; geo.salvar_config())
	h5.add_child(s_f)

	_body.add_child(HSeparator.new())

	# --- fonte das antenas + token RMF ---
	_body.add_child(_rotulo("Fonte das antenas"))
	var ob: OptionButton = OptionButton.new()
	ob.add_item("API RMF (Anatel/Mosaico, online)", 0)
	ob.add_item("Base Anatel (CSV importado)", 1)
	ob.add_item("RMF + Anatel", 2)
	ob.add_item("Só torres do OSM", 3)
	ob.select(int(geo.fonte_antenas))
	ob.item_selected.connect(func(i: int): geo.fonte_antenas = i; geo.salvar_config(); geo.recarregar_antenas())
	_body.add_child(ob)
	var h7: HBoxContainer = HBoxContainer.new()
	_body.add_child(h7)
	var le_tok: LineEdit = LineEdit.new()
	le_tok.placeholder_text = "Token da API RMF (redesmoveisfixas.com/createapi)"
	le_tok.secret = true
	le_tok.text = geo.rmf.token
	le_tok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h7.add_child(le_tok)
	var b_tok: Button = Button.new()
	b_tok.text = "Salvar + testar"
	b_tok.tooltip_text = "Guarda o token em GeoCache/geo_settings.cfg, testa as conexões e recarrega as antenas"
	b_tok.pressed.connect(func():
		geo.rmf.token = le_tok.text.strip_edges()
		geo.rmf_token = geo.rmf.token
		geo.salvar_config()
		await geo.testar_conexao()
		geo.recarregar_antenas())
	h7.add_child(b_tok)
	b_tok.focus_mode = Control.FOCUS_NONE
	var b_net: Button = Button.new()
	b_net.text = "Testar conexão"
	b_net.pressed.connect(func(): geo.testar_conexao())
	b_net.focus_mode = Control.FOCUS_NONE
	_body.add_child(b_net)

	_body.add_child(HSeparator.new())

	# --- base Anatel ---
	_body.add_child(_rotulo("Base de antenas (Anatel)"))
	_lbl_anatel = Label.new()
	_lbl_anatel.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(_lbl_anatel)
	var chk_smp: CheckBox = CheckBox.new()
	chk_smp.text = "Somente telefonia móvel (SMP)"
	chk_smp.button_pressed = geo.anatel.somente_telefonia_movel
	chk_smp.toggled.connect(func(p: bool): geo.anatel.somente_telefonia_movel = p)
	chk_smp.focus_mode = Control.FOCUS_NONE
	_body.add_child(chk_smp)
	var h6: HBoxContainer = HBoxContainer.new()
	_body.add_child(h6)
	var b_imp: Button = Button.new()
	b_imp.text = "Importar CSV/ZIP…"
	b_imp.tooltip_text = "Escolha o estacoes_licenciadas.zip (ou um CSV com latitude/longitude) já baixado"
	b_imp.pressed.connect(func(): _file_dialog.popup_centered(Vector2i(900, 560)))
	h6.add_child(b_imp)
	var b_dl: Button = Button.new()
	b_dl.text = "Baixar da Anatel"
	b_dl.tooltip_text = "Baixa o arquivo público (centenas de MB) e importa. Se o servidor recusar, baixe pelo navegador e use \"Importar\"."
	b_dl.pressed.connect(_baixar_anatel)
	h6.add_child(b_dl)
	_le_url = LineEdit.new()
	_le_url.text = geo.anatel.DEFAULT_URL
	_le_url.tooltip_text = "URL do arquivo de estações da Anatel (dados abertos)"
	_body.add_child(_le_url)

	for b in [b_ir, b_aqui, b_tab, b_imp, b_dl]:
		b.focus_mode = Control.FOCUS_NONE

	# FileDialog (nativo do SO)
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = true
	_file_dialog.title = "Base de estações (Anatel ou qualquer CSV com latitude/longitude)"
	_file_dialog.filters = PackedStringArray(["*.zip, *.csv, *.txt ; Estações (zip/csv)"])
	_file_dialog.file_selected.connect(func(p: String): geo.anatel.import_async(p); _set_status("Importando %s…" % p.get_file()))
	add_child(_file_dialog)

	geo.status_changed.connect(_set_status)
	geo.settings_changed.connect(_sync)
	geo.package_changed.connect(_sync)
	_sync()


func _rotulo(txt: String) -> Label:
	var l: Label = Label.new()
	l.text = txt
	return l


func _spin(minv: float, maxv: float, step: float, val: float) -> SpinBox:
	var s: SpinBox = SpinBox.new()
	s.min_value = minv
	s.max_value = maxv
	s.step = step
	s.value = val
	s.custom_minimum_size = Vector2(100, 0)
	return s


func _chk(txt: String, val: bool, cb: Callable) -> CheckButton:
	var c: CheckButton = CheckButton.new()
	c.text = txt
	c.button_pressed = val
	c.focus_mode = Control.FOCUS_NONE
	c.toggled.connect(cb)
	return c


func _aplicar_camadas() -> void:
	geo.salvar_config()
	if not geo.regiao.is_empty():
		geo.carregar_regiao(geo.regiao.center)


func _set_status(msg: String) -> void:
	if _lbl_status:
		_lbl_status.text = msg


func _sync() -> void:
	if _lbl_pacote:
		_lbl_pacote.text = ("📦 " + geo.pacote.resumo()) if geo.pacote != null else "Nenhum — modo online (relevo/OSM baixados e guardados em cache)."
	if _chk_follow:
		_chk_follow.set_pressed_no_signal(geo.seguir_camera)
	if _lbl_anatel:
		_lbl_anatel.text = geo.anatel.resumo()


func _abrir_tabela() -> void:
	if _tabela == null or not is_instance_valid(_tabela):
		_tabela = AntennaTable.new()
		_tabela.geo = geo
		add_child(_tabela)
	_tabela.popup_centered(Vector2i(1060, 620))


# Download da base Anatel (stream direto para o disco)
func _baixar_anatel() -> void:
	if _dl != null and is_instance_valid(_dl):
		_set_status("Download já em andamento…")
		return
	var url: String = _le_url.text.strip_edges()
	if url == "":
		return
	_dl_path = geo.anatel.raw_dir().path_join("estacoes_licenciadas.zip")
	_dl = HTTPRequest.new()
	_dl.download_file = _dl_path
	_dl.download_chunk_size = 1048576
	_dl.timeout = 0.0
	_dl.use_threads = true
	_dl.request_completed.connect(_on_dl_done)
	add_child(_dl)
	var err: int = _dl.request(url, PackedStringArray(["User-Agent: SAARIS-Simulator/1.0 (pesquisa academica UFRJ/GTA)"]))
	if err != OK:
		_set_status("❌ Não consegui iniciar o download (erro %d)." % err)
		_dl.queue_free()
		_dl = null
		return
	_set_status("Baixando base da Anatel…")


func _process(_delta: float) -> void:
	if _dl != null and is_instance_valid(_dl):
		var feito: float = float(_dl.get_downloaded_bytes()) / 1048576.0
		var total: int = _dl.get_body_size()
		if total > 0:
			_set_status("Baixando base da Anatel… %.1f / %.1f MB" % [feito, float(total) / 1048576.0])
		else:
			_set_status("Baixando base da Anatel… %.1f MB" % feito)


func _on_dl_done(result: int, code: int, _headers: PackedStringArray, _body_bytes: PackedByteArray) -> void:
	if _dl:
		_dl.queue_free()
	_dl = null
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_set_status("❌ Download falhou (resultado %d, HTTP %d). Baixe o arquivo pelo navegador e use \"Importar CSV/ZIP…\"." % [result, code])
		return
	_set_status("Download concluído. Importando (pode levar alguns minutos)…")
	geo.anatel.import_async(_dl_path)
