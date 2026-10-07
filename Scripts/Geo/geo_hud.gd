extends Control
## HUD do mundo real, sempre visivel na cena principal:
##  - canto superior esquerdo: lat/lon da camera (ponto do chao no centro da tela),
##    centro da regiao carregada, estado da conexao e andamento do carregamento;
##  - canto inferior esquerdo: log de tudo que o GeoManager faz (F3 mostra/esconde).
## Nao intercepta cliques (mouse_filter = ignore), para nao atrapalhar a camera.

var geo: Node = null

var _lbl_cam: Label
var _lbl_regiao: Label
var _lbl_status: Label
var _lbl_conn: Label
var _log_panel: PanelContainer
var _log: RichTextLabel
var _linhas: int = 0
const MAX_LINHAS := 400


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# --- barra de status (topo esquerdo) ---
	var barra: PanelContainer = PanelContainer.new()
	barra.mouse_filter = Control.MOUSE_FILTER_IGNORE
	barra.position = Vector2(10, 74)
	add_child(barra)
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.10, 0.82)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	barra.add_theme_stylebox_override("panel", sb)
	var v: VBoxContainer = VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	barra.add_child(v)

	_lbl_cam = _novo_label(v, 15)
	_lbl_regiao = _novo_label(v, 13)
	_lbl_conn = _novo_label(v, 13)
	_lbl_status = _novo_label(v, 13)
	_lbl_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_status.custom_minimum_size = Vector2(430, 0)

	# --- log (inferior esquerdo) ---
	_log_panel = PanelContainer.new()
	_log_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_log_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_log_panel.anchor_top = 1.0
	_log_panel.anchor_bottom = 1.0
	_log_panel.offset_left = 10
	_log_panel.offset_right = 560
	_log_panel.offset_top = -210
	_log_panel.offset_bottom = -10
	_log_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_log_panel.add_theme_stylebox_override("panel", sb)
	add_child(_log_panel)
	_log = RichTextLabel.new()
	_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_log.scroll_following = true
	_log.bbcode_enabled = false
	_log.add_theme_font_size_override("normal_font_size", 12)
	_log_panel.add_child(_log)

	geo.log_line.connect(_on_log)
	geo.status_changed.connect(func(m: String): _lbl_status.text = m)
	geo.region_loaded.connect(func(_i): _atualizar())
	geo.camera_latlon_changed.connect(func(_a, _b): _atualizar_cam())
	_lbl_status.text = geo.status()
	_atualizar()


func _input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_F3:
		_log_panel.visible = not _log_panel.visible


func _novo_label(pai: Node, tam: int) -> Label:
	var l: Label = Label.new()
	l.add_theme_font_size_override("font_size", tam)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pai.add_child(l)
	return l


func _on_log(msg: String) -> void:
	_log.append_text("%s  %s\n" % [Time.get_time_string_from_system(), msg])
	_linhas += 1
	if _linhas > MAX_LINHAS:
		_log.remove_paragraph(0)
		_linhas -= 1


func _atualizar_cam() -> void:
	_lbl_cam.text = "📍 Câmera: %.5f, %.5f" % [geo.lat_camera, geo.lon_camera]


func _atualizar() -> void:
	_atualizar_cam()
	if geo.regiao.is_empty():
		_lbl_regiao.text = "Região: (carregando…)"
	else:
		var ll: Vector2 = geo.frame.xz_to_latlon(geo.regiao.center.x, geo.regiao.center.y)
		_lbl_regiao.text = "🗺 Região %.1f km em %.5f, %.5f %s" % [float(geo.regiao.get("lado", geo.tamanho_regiao_m)) / 1000.0, ll.x, ll.y, "🔒 fixada" if geo.regiao_fixada else ("(segue câmera)" if geo.seguir_camera else "")]


func _process(_d: float) -> void:
	var c: Dictionary = geo.conexao
	var partes: PackedStringArray = PackedStringArray()
	if geo.pacote != null:
		pass   # modo pacote: sem rede
	elif c.is_empty():
		partes.append("🌐 testando conexão…")
	if geo.pacote == null and not c.is_empty():
		partes.append("%s relevo" % ("✅" if c.get("relevo", false) else "❌"))
		partes.append("%s OSM" % ("✅" if c.get("osm", false) else "❌"))
		partes.append("%s RMF" % ("✅" if c.get("rmf", false) else "⚠"))
	if geo.pacote != null:
		partes.append("📦 " + geo.pacote.nome)
	elif geo.prefetch_estado != "":
		partes.append(geo.prefetch_estado)
	_lbl_conn.text = "  ".join(partes)
	if geo.carregando:
		_lbl_regiao.modulate = Color(1, 0.85, 0.4)
	else:
		_lbl_regiao.modulate = Color(1, 1, 1)
