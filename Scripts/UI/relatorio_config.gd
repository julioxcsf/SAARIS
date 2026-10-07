extends Node
## Configurador + visualizador do relatorio (criado por codigo pelo control.gd, sem mexer no gui.tscn).
## Botao "Relatorio" -> Manager.ui_relatorio.abrir() -> janela de configuracao -> gera, salva e mostra.

const Gerador = preload("res://Scripts/Report/relatorio_gerador.gd")

var _cfg: Dictionary = Gerador.CONFIG_PADRAO.duplicate()

var _dlg_cfg: AcceptDialog
var _ed_titulo: LineEdit
var _sp_limiar: SpinBox
var _sp_banda: SpinBox
var _sp_nf: SpinBox
var _opt_escala: OptionButton
var _ck_predios: CheckBox
var _ck_marcadores: CheckBox
var _ck_ris_desl: CheckBox
var _lbl_info: Label
var _cores: Dictionary = {}          # chave da config -> ColorPickerButton
var _ultima_res: Vector2i = Vector2i.ZERO
const _ROTULOS_CORES := [
	["cor_tx", "Antena (TX) ligada"], ["cor_tx_off", "Antena (TX) desligada"], ["cor_rx", "Caixa do RX"],
	["cor_ris", "RIS ligado"], ["cor_ris_off", "RIS desligado"],
	["cor_predio", "Prédios (preenchimento)"], ["cor_predio_borda", "Prédios (contorno)"],
]

var _janela: Window
var _conteudo: VBoxContainer     # recebe texto e imagens do relatorio
var _lbl_pasta: Label
var _ultimo: Dictionary = {}
var _pasta_ultima: String = ""


func _ready() -> void:
	Manager.ui_relatorio = self
	_montar_configurador()
	_montar_visualizador()


# --- configuracao (tambem vai no save) ---

func get_config() -> Dictionary:
	_ler_campos()
	return _cfg.duplicate()

func set_config(c: Dictionary) -> void:
	_cfg.merge(c, true)
	_escrever_campos()


# --- UI ---

func _linha(rotulo: String, controle: Control, pai: Control) -> void:
	var h := HBoxContainer.new()
	var l := Label.new()
	l.text = rotulo
	l.custom_minimum_size = Vector2(230, 0)
	controle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	h.add_child(controle)
	pai.add_child(h)

func _spin(minv: float, maxv: float, passo: float, v: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = minv
	s.max_value = maxv
	s.step = passo
	s.value = v
	return s

func _montar_configurador() -> void:
	_dlg_cfg = AcceptDialog.new()
	_dlg_cfg.title = "Configurar relatório"
	_dlg_cfg.ok_button_text = "Gerar relatório"
	_dlg_cfg.min_size = Vector2i(560, 0)
	_dlg_cfg.confirmed.connect(_on_gerar)
	add_child(_dlg_cfg)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_dlg_cfg.add_child(v)

	_ed_titulo = LineEdit.new()
	_linha("Título", _ed_titulo, v)

	_sp_limiar = _spin(-200.0, 50.0, 1.0, -95.0)
	_sp_limiar.suffix = "dBm"
	_linha("Limiar de cobertura (potência mínima)", _sp_limiar, v)

	_sp_banda = _spin(0.001, 10000.0, 0.5, 20.0)
	_sp_banda.suffix = "MHz"
	_linha("Largura de banda do receptor", _sp_banda, v)

	_sp_nf = _spin(0.0, 40.0, 0.5, 7.0)
	_sp_nf.suffix = "dB"
	_linha("Figura de ruído do receptor", _sp_nf, v)

	_opt_escala = OptionButton.new()
	_linha("Resolução da imagem", _opt_escala, v)

	_ck_predios = CheckBox.new()
	_ck_predios.text = "Desenhar contorno das construções"
	v.add_child(_ck_predios)
	_ck_marcadores = CheckBox.new()
	_ck_marcadores.text = "Desenhar TX, RX e RIS (numerados) na imagem"
	v.add_child(_ck_marcadores)
	_ck_ris_desl = CheckBox.new()
	_ck_ris_desl.text = "Contar também os RIS desligados na interface (desmarcado = estado atual: só os ligados)"
	v.add_child(_ck_ris_desl)

	var tit_cores := Label.new()
	tit_cores.text = "Cores do desenho e da legenda"
	v.add_child(tit_cores)
	var grade := GridContainer.new()
	grade.columns = 4
	v.add_child(grade)
	for par in _ROTULOS_CORES:
		var l := Label.new()
		l.text = par[1]
		var b := ColorPickerButton.new()
		b.custom_minimum_size = Vector2(60, 0)
		b.edit_alpha = false
		grade.add_child(l)
		grade.add_child(b)
		_cores[par[0]] = b

	_lbl_info = Label.new()
	_lbl_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_info.custom_minimum_size = Vector2(520, 0)
	_lbl_info.modulate = Color(0.8, 0.8, 0.8)
	v.add_child(_lbl_info)

	_escrever_campos()

## So oferece ampliacoes cujo resultado fica <= 4096 px por lado (limite fixo do relatorio).
func _atualizar_opcoes_escala() -> void:
	_opt_escala.clear()
	var res: Vector2i = Manager.engine.mapa_calor.resolution if Manager.engine else Vector2i(256, 256)
	var maxe: int = Gerador.escala_maxima(res)
	var esc: int = 1
	while esc <= maxe:
		_opt_escala.add_item("%d × %d px  (%d×%s)" % [res.x * esc, res.y * esc, esc, "  — tamanho da simulação" if esc == 1 else ""])
		_opt_escala.set_item_metadata(_opt_escala.item_count - 1, esc)
		esc *= 2
	var alvo: int = 0
	for i in _opt_escala.item_count:
		if int(_opt_escala.get_item_metadata(i)) == int(_cfg.escala_imagem):
			alvo = i
	_opt_escala.select(alvo)

func _escrever_campos() -> void:
	if _ed_titulo == null: return
	_ed_titulo.text = _cfg.titulo
	_sp_limiar.value = _cfg.limiar_dbm
	_sp_banda.value = _cfg.banda_mhz
	_sp_nf.value = _cfg.figura_ruido_db
	_ck_predios.button_pressed = _cfg.desenhar_predios
	_ck_marcadores.button_pressed = _cfg.desenhar_marcadores
	_ck_ris_desl.button_pressed = _cfg.ris_desligados_contam
	for k in _cores:
		(_cores[k] as ColorPickerButton).color = _cfg[k]
	_atualizar_opcoes_escala()

func _ler_campos() -> void:
	if _ed_titulo == null: return
	_cfg.titulo = _ed_titulo.text if _ed_titulo.text.strip_edges() != "" else Gerador.CONFIG_PADRAO.titulo
	_cfg.limiar_dbm = _sp_limiar.value
	_cfg.banda_mhz = _sp_banda.value
	_cfg.figura_ruido_db = _sp_nf.value
	_cfg.desenhar_predios = _ck_predios.button_pressed
	_cfg.desenhar_marcadores = _ck_marcadores.button_pressed
	_cfg.ris_desligados_contam = _ck_ris_desl.button_pressed
	for k in _cores:
		_cfg[k] = (_cores[k] as ColorPickerButton).color
	if _opt_escala.item_count > 0 and _opt_escala.selected >= 0:
		_cfg.escala_imagem = int(_opt_escala.get_item_metadata(_opt_escala.selected))

func _montar_visualizador() -> void:
	_janela = Window.new()
	_janela.title = "Relatório de cobertura"
	_janela.size = Vector2i(1100, 820)
	_janela.visible = false
	_janela.wrap_controls = false
	_janela.close_requested.connect(func(): _janela.hide())
	add_child(_janela)

	var fundo := PanelContainer.new()
	fundo.set_anchors_preset(Control.PRESET_FULL_RECT)
	_janela.add_child(fundo)
	var v := VBoxContainer.new()
	fundo.add_child(v)

	var barra := HBoxContainer.new()
	v.add_child(barra)
	var b_pasta := Button.new()
	b_pasta.text = "Abrir pasta do relatório"
	b_pasta.pressed.connect(func(): if _pasta_ultima != "": OS.shell_show_in_file_manager(_pasta_ultima))
	barra.add_child(b_pasta)
	var b_html := Button.new()
	b_html.text = "Abrir HTML"
	b_html.pressed.connect(func(): if _pasta_ultima != "": OS.shell_open(_pasta_ultima.path_join("relatorio.html")))
	barra.add_child(b_html)
	var b_md := Button.new()
	b_md.text = "Copiar Markdown"
	b_md.pressed.connect(func(): if not _ultimo.is_empty(): DisplayServer.clipboard_set(_ultimo.markdown))
	barra.add_child(b_md)
	var b_cfg := Button.new()
	b_cfg.text = "Reconfigurar…"
	b_cfg.pressed.connect(func(): abrir())
	barra.add_child(b_cfg)
	_lbl_pasta = Label.new()
	_lbl_pasta.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lbl_pasta.clip_text = true
	barra.add_child(_lbl_pasta)

	var rolagem := ScrollContainer.new()
	rolagem.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(rolagem)
	var conteudo := VBoxContainer.new()
	conteudo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rolagem.add_child(conteudo)

	_conteudo = conteudo

func _novo_texto(pai: Control) -> RichTextLabel:
	var t := RichTextLabel.new()
	t.bbcode_enabled = true
	t.fit_content = true
	t.selection_enabled = true
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pai.add_child(t)
	return t


## Monta o visualizador: texto | imagem 1 | texto | imagem 2 | texto (marcadores {{IMAGEM1}} e {{IMAGEM2}} no BBCode).
func _mostrar(res: Dictionary) -> void:
	for c in _conteudo.get_children():
		c.queue_free()
	var texto: String = res.bbcode
	var imgs := {"{{IMAGEM1}}": res.imagem, "{{IMAGEM2}}": res.imagem2}
	var restante: String = texto
	while true:
		var prox: String = ""
		var pos: int = -1
		for marca in imgs.keys():
			var p: int = restante.find("[center]" + marca + "[/center]")
			if p != -1 and (pos == -1 or p < pos):
				pos = p
				prox = marca
		if pos == -1:
			break
		_novo_texto(_conteudo).parse_bbcode(restante.substr(0, pos))
		var tr := TextureRect.new()
		tr.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
		tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		tr.custom_minimum_size = Vector2(900, 0)
		tr.texture = ImageTexture.create_from_image(imgs[prox])
		_conteudo.add_child(tr)
		restante = restante.substr(pos + ("[center]" + prox + "[/center]").length())
	_novo_texto(_conteudo).parse_bbcode(restante)


# --- acoes ---

## Botao "Relatorio": abre o configurador.
func abrir() -> void:
	if Manager.engine == null or not Manager.engine.tem_resultado():
		Manager.aviso("Ainda não há resultado de simulação.\nClique em Start e, quando terminar, gere o relatório.")
		return
	var res: Vector2i = Manager.engine.mapa_calor.resolution
	if res != _ultima_res:                 # outra resolucao: volta para o tamanho da simulacao (sem ampliar)
		_cfg.escala_imagem = 1
		_ultima_res = res
	_cfg.escala_imagem = clampi(int(_cfg.escala_imagem), 1, Gerador.escala_maxima(res))
	_escrever_campos()
	_lbl_info.text = "Mapa simulado: %d × %d pixels. A imagem do relatório nunca passa de %d × %d px; só são oferecidas ampliações que cabem nesse limite (por padrão, sem ampliar)." % [res.x, res.y, Gerador.LIMITE_IMAGEM_PX, Gerador.LIMITE_IMAGEM_PX]
	_dlg_cfg.popup_centered()


func _on_gerar() -> void:
	_ler_campos()
	var gerador = Gerador.new()
	var res: Dictionary = gerador.gerar(_cfg)
	if not res.ok:
		Manager.aviso(res.erro)
		return
	_ultimo = res
	_pasta_ultima = gerador.salvar(res)

	_mostrar(res)
	_lbl_pasta.text = "Salvo em: " + _pasta_ultima
	_janela.popup_centered()
