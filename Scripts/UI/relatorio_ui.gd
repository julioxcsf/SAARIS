# relatorio_ui.gd - label "Relatorio:" da barra lateral (resumo rapido + leitura da ponteira).
# O relatorio completo e o botao "Relatorio" (relatorio_config.gd).
extends Label

@onready var label_potencia = $"../Label_potencia"
@onready var switch_ponteira = $"../LigarPonteira"


func _ready() -> void:
	Manager.ui_dados = self       # camera e simulador chamam atualizar_sonda() / atualizar_estatisticas() / limpar()
	switch_ponteira.toggled.connect(func(p):
		Manager.is_probe_active = p
		if _painel_detalhe != null and not p:
			_painel_detalhe.visible = false)


func atualizar_sonda(dbm: float, pos: Vector3, detalhe: String = "") -> void:
	var pos_str = "(x: %.1f, y: %.1f, z: %.1f)" % [pos.x, pos.y, pos.z]
	if dbm > -200.0:
		label_potencia.text = "Sinal: %.2f dBm\nPos: %s" % [dbm, pos_str]
	else:
		label_potencia.text = "Sinal: abaixo de -200 dBm\nPos: %s" % pos_str
	_mostrar_detalhe(detalhe)
	if detalhe != "":
		print(_sem_bbcode(detalhe))


var _painel_detalhe: PanelContainer
var _texto_detalhe: RichTextLabel
var _arrastando := false
var _desloc := Vector2.ZERO


func _sem_bbcode(t: String) -> String:
	var re := RegEx.new()
	re.compile("\\[/?[a-z_]+[^\\]]*\\]")
	return re.sub(t, "", true)


## Janela flutuante: arraste pela barra de titulo; "x" fecha (reabre na proxima leitura).
func _criar_painel() -> void:
	var cl := CanvasLayer.new()
	cl.layer = 50
	add_child(cl)
	_painel_detalhe = PanelContainer.new()
	_painel_detalhe.position = Vector2(get_viewport().get_visible_rect().size.x - 640, 12)
	_painel_detalhe.custom_minimum_size = Vector2(620, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.09, 0.14, 0.94)
	sb.border_color = Color("#ffb454")
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(0)
	_painel_detalhe.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 0)
	_painel_detalhe.add_child(vb)
	var barra := PanelContainer.new()
	var sbb := StyleBoxFlat.new()
	sbb.bg_color = Color("#1c2a40")
	sbb.set_corner_radius_all(8)
	sbb.set_content_margin_all(6)
	barra.add_theme_stylebox_override("panel", sbb)
	barra.mouse_default_cursor_shape = Control.CURSOR_MOVE
	var hb := HBoxContainer.new()
	var tit := Label.new()
	tit.text = "⠿ Ponteira de potência — por que deu esse valor"
	tit.add_theme_color_override("font_color", Color("#ffb454"))
	tit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var fechar := Button.new()
	fechar.text = "×"
	fechar.flat = true
	fechar.pressed.connect(func(): _painel_detalhe.visible = false)
	hb.add_child(tit)
	hb.add_child(fechar)
	barra.add_child(hb)
	barra.gui_input.connect(_arrastar_painel)
	vb.add_child(barra)
	var margem := MarginContainer.new()
	for lado in ["left", "right", "top", "bottom"]:
		margem.add_theme_constant_override("margin_" + lado, 10)
	_texto_detalhe = RichTextLabel.new()
	_texto_detalhe.bbcode_enabled = true
	_texto_detalhe.fit_content = true
	_texto_detalhe.scroll_active = false
	_texto_detalhe.selection_enabled = true
	_texto_detalhe.custom_minimum_size = Vector2(600, 0)
	_texto_detalhe.add_theme_font_size_override("normal_font_size", 14)
	_texto_detalhe.add_theme_font_size_override("bold_font_size", 14)
	margem.add_child(_texto_detalhe)
	vb.add_child(margem)
	cl.add_child(_painel_detalhe)


func _arrastar_painel(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		_arrastando = ev.pressed
		_desloc = _painel_detalhe.position - get_viewport().get_mouse_position()
	elif ev is InputEventMouseMotion and _arrastando:
		var p: Vector2 = get_viewport().get_mouse_position() + _desloc
		var vp: Vector2 = get_viewport().get_visible_rect().size
		_painel_detalhe.position = Vector2(clampf(p.x, -400.0, vp.x - 120.0), clampf(p.y, 0.0, vp.y - 40.0))


func _mostrar_detalhe(detalhe: String) -> void:
	if _painel_detalhe == null:
		_criar_painel()
	_texto_detalhe.text = detalhe
	_painel_detalhe.reset_size()
	_painel_detalhe.visible = detalhe != "" and Manager.is_probe_active


## Resumo do ultimo mapa simulado (vem de engine.estatisticas_mapa()).
func atualizar_estatisticas(d: Dictionary) -> void:
	if not d.get("valido", false):
		limpar()
		return
	var texto = "[ RESUMO DA SIMULAÇÃO ]\n"
	texto += "Cobertura: %.1f%% (>= %.0f dBm)\n" % [d.cobertura_pct, d.limiar_dbm]
	texto += "Área: %.1f x %.1f m\n" % [d.terrain_size.x, d.terrain_size.y]
	texto += "Resolução: 1px = %.2fm x %.2fm\n" % [d.res_m_px.x, d.res_m_px.y]
	texto += "Pot.: mín %.0f | méd %.0f | máx %.0f dBm\n" % [d.min_dbm, d.media_dbm, d.max_dbm]
	texto += "(detalhes: botão Relatório)"
	self.text = texto


func limpar() -> void:
	self.text = "Relatório:"
	label_potencia.text = "Sinal: ---"
