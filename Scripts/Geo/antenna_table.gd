extends Window
## Tabela de antenas da regiao: ordenavel (clique no titulo da coluna),
## agrupavel por Empresa / Faixa de frequencia / Tecnologia, filtravel por texto
## e com caixas de selecao (por antena ou por grupo inteiro) que definem QUAIS
## antenas entram na proxima simulacao.
## Duplo clique em uma linha leva a camera ate a antena.

var geo: Node = null

var tree: Tree
var opt_group: OptionButton
var le_filter: LineEdit
var lbl_resumo: Label

var group_mode: int = 0          # 0 Empresa | 1 Faixa | 2 Tecnologia | 3 Nenhum
var sort_col: int = 1
var sort_asc: bool = true
var _rebuilding: bool = false
var _rebuild_pendente: bool = false

const COLS: Array[String] = ["Usar", "Empresa", "Estação", "Freq (MHz)", "Faixa", "Tecnologia", "Altura (m)", "Dist. (m)", "Fonte"]
const COL_W: Array[int] = [90, 250, 120, 90, 100, 100, 80, 80, 70]


func _ready() -> void:
	title = "Antenas na região"
	size = Vector2i(1060, 620)
	min_size = Vector2i(760, 360)
	exclusive = false
	close_requested.connect(hide)

	var margem: MarginContainer = MarginContainer.new()
	margem.set_anchors_preset(Control.PRESET_FULL_RECT)
	for lado in ["left", "right", "top", "bottom"]:
		margem.add_theme_constant_override("margin_" + lado, 8)
	add_child(margem)

	var vb: VBoxContainer = VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	margem.add_child(vb)

	# --- barra de ferramentas ---
	var bar: HBoxContainer = HBoxContainer.new()
	vb.add_child(bar)
	var l1: Label = Label.new()
	l1.text = "Agrupar por:"
	bar.add_child(l1)
	opt_group = OptionButton.new()
	for t in ["Empresa", "Faixa de frequência", "Tecnologia", "Nenhum (lista)"]:
		opt_group.add_item(t)
	opt_group.item_selected.connect(func(i: int): group_mode = i; _rebuild())
	bar.add_child(opt_group)

	le_filter = LineEdit.new()
	le_filter.placeholder_text = "Filtrar: empresa, faixa, estação, tecnologia…"
	le_filter.clear_button_enabled = true
	le_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le_filter.text_changed.connect(func(_t: String): _rebuild())
	bar.add_child(le_filter)

	var b_vis: Button = Button.new()
	b_vis.text = "Marcar visíveis"
	b_vis.tooltip_text = "Marca todas as antenas que passam no filtro atual"
	b_vis.pressed.connect(_marcar_visiveis)
	bar.add_child(b_vis)

	var b_clr: Button = Button.new()
	b_clr.text = "Limpar seleção"
	b_clr.pressed.connect(func(): geo.limpar_selecao())
	bar.add_child(b_clr)

	# --- tabela ---
	tree = Tree.new()
	tree.columns = COLS.size()
	tree.column_titles_visible = true
	tree.hide_root = true
	tree.select_mode = Tree.SELECT_ROW
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for i in COLS.size():
		tree.set_column_custom_minimum_width(i, COL_W[i])
		tree.set_column_expand(i, i == 1)
	_atualizar_titulos()
	tree.column_title_clicked.connect(_on_title_clicked)
	tree.item_edited.connect(_on_item_edited)
	tree.item_activated.connect(_on_item_activated)
	vb.add_child(tree)

	# --- rodape ---
	lbl_resumo = Label.new()
	lbl_resumo.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(lbl_resumo)
	var dica: Label = Label.new()
	dica.text = "Marque as antenas (ou um grupo inteiro: empresa/faixa) e clique em Simular: o mapa de calor usa só as marcadas + seus TX manuais. Clique no título para ordenar; duplo clique para focar a câmera."
	dica.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dica.modulate = Color(1, 1, 1, 0.65)
	vb.add_child(dica)

	geo.antennas_changed.connect(_rebuild)
	_rebuild()


func _atualizar_titulos() -> void:
	for i in COLS.size():
		var t: String = COLS[i]
		if i == sort_col:
			t += " ▲" if sort_asc else " ▼"
		tree.set_column_title(i, t)


func _on_title_clicked(col: int, button: int) -> void:
	if button != MOUSE_BUTTON_LEFT:
		return
	if col == sort_col:
		sort_asc = not sort_asc
	else:
		sort_col = col
		sort_asc = true
	_atualizar_titulos()
	_rebuild()


# Dados

func _dist(a: Dictionary) -> float:
	if geo.regiao.is_empty():
		return 0.0
	var c: Vector2 = geo.regiao.center
	return Vector2(a.x, a.z).distance_to(c)


func _chave(a: Dictionary, col: int) -> Variant:
	match col:
		0: return 1 if geo.selecionadas.has(a.id) else 0
		1: return String(a.op).to_lower()
		2: return String(a.stid)
		3, 4: return float(a.freq)
		5: return String(a.tech).to_lower()
		6: return float(a.agl)
		7: return _dist(a)
		_: return String(a.src)


func _ordenar(lista: Array) -> void:
	var col: int = sort_col
	var asc: bool = sort_asc
	lista.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		var kx: Variant = _chave(x, col)
		var ky: Variant = _chave(y, col)
		return kx < ky if asc else kx > ky)


func _casa(a: Dictionary, filtro: String) -> bool:
	var alvo: String = ("%s %s %s %s %s %s" % [a.op, a.banda, a.stid, a.tech, a.src, "%.0f" % a.freq]).to_lower()
	return alvo.contains(filtro)


func _nome_grupo(a: Dictionary) -> String:
	match group_mode:
		0: return a.op
		1: return a.banda
		_: return a.tech if a.tech != "" else "(sem tecnologia)"


# Construcao da arvore

func _rebuild() -> void:
	# Coalescer: varias emissoes de antennas_changed no mesmo frame viram uma reconstrucao
	if _rebuild_pendente:
		return
	_rebuild_pendente = true
	_rebuild_agora.call_deferred()


func _rebuild_agora() -> void:
	_rebuild_pendente = false
	if tree == null:
		return
	_rebuilding = true

	# guarda grupos expandidos
	var expandidos: Dictionary = {}
	var r0: TreeItem = tree.get_root()
	if r0 != null:
		for g in r0.get_children():
			if not g.collapsed:
				expandidos[g.get_text(1).get_slice("  (", 0)] = true

	tree.clear()
	var root: TreeItem = tree.create_item()

	var filtro: String = le_filter.text.strip_edges().to_lower()
	var lista: Array = []
	for a in geo.antenas_regiao:
		if filtro == "" or _casa(a, filtro):
			lista.append(a)

	if group_mode == 3:
		_ordenar(lista)
		for a in lista:
			_add_linha(root, a)
	else:
		var grupos: Dictionary = {}
		for a in lista:
			var n: String = _nome_grupo(a)
			if not grupos.has(n):
				grupos[n] = []
			(grupos[n] as Array).append(a)

		var nomes: Array = grupos.keys()
		if group_mode == 1:
			# faixas em ordem crescente de frequencia
			nomes.sort_custom(func(x: String, y: String) -> bool:
				return _freq_min(grupos[x]) < _freq_min(grupos[y]))
		else:
			nomes.sort_custom(func(x: String, y: String) -> bool:
				return x.to_lower() < y.to_lower())

		for n in nomes:
			var itens: Array = grupos[n]
			_ordenar(itens)
			var g: TreeItem = tree.create_item(root)
			var ids: Array = []
			var estacoes: Dictionary = {}
			var marcadas: int = 0
			for a in itens:
				ids.append(a.id)
				estacoes["%s|%.5f|%.5f" % [a.op, a.lat, a.lon]] = true
				if geo.selecionadas.has(a.id):
					marcadas += 1

			g.set_text(1, "%s  (%d estações · %d registros)" % [n, estacoes.size(), itens.size()])
			g.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
			g.set_editable(0, true)
			g.set_checked(0, marcadas == itens.size() and marcadas > 0)
			g.set_indeterminate(0, marcadas > 0 and marcadas < itens.size())
			g.set_metadata(0, {"group": n, "ids": ids})
			g.set_custom_bg_color(1, Color(0.2, 0.25, 0.35, 0.6))
			for c in range(2, COLS.size()):
				g.set_custom_bg_color(c, Color(0.2, 0.25, 0.35, 0.6))
			for a in itens:
				_add_linha(g, a)
			g.collapsed = not expandidos.has(n)

	_rebuilding = false
	_atualizar_resumo(lista.size())


func _freq_min(itens: Array) -> float:
	var m: float = INF
	for a in itens:
		var f: float = a.freq if a.freq > 0.0 else 1.0e9
		m = minf(m, f)
	return m


func _add_linha(parent: TreeItem, a: Dictionary) -> void:
	var it: TreeItem = tree.create_item(parent)
	it.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
	it.set_editable(0, true)
	it.set_checked(0, geo.selecionadas.has(a.id))
	it.set_text(1, a.op)
	it.set_text(2, a.stid)
	it.set_text(3, "%.1f" % a.freq if a.freq > 0.0 else "—")
	it.set_text(4, a.banda)
	it.set_text(5, a.tech)
	it.set_text(6, "%.0f" % a.agl)
	it.set_text(7, "%.0f" % _dist(a))
	it.set_text(8, a.src)
	for c in [3, 6, 7]:
		it.set_text_alignment(c, HORIZONTAL_ALIGNMENT_RIGHT)
	it.set_metadata(0, {"id": a.id})
	if a.has("endereco") and str(a.endereco) != "":
		it.set_tooltip_text(1, "%s — %s" % [str(a.get("infra", "")), str(a.endereco)])
	if a.src == "OSM":
		it.set_tooltip_text(1, "Torre mapeada no OpenStreetMap (sem frequência: usa a frequência padrão do painel)")


func _atualizar_resumo(visiveis: int) -> void:
	var por_op: Dictionary = {}
	var total_sel: int = 0
	for a in geo.antenas_regiao:
		if geo.selecionadas.has(a.id):
			total_sel += 1
			por_op[a.op] = int(por_op.get(a.op, 0)) + 1
	var partes: PackedStringArray = PackedStringArray()
	for k in por_op.keys():
		partes.append("%s %d" % [k, por_op[k]])
	var txt: String = "%d registros na região (%d visíveis com o filtro) · %d marcadas" % [geo.antenas_regiao.size(), visiveis, total_sel]
	if partes.size() > 0:
		txt += "  [" + ", ".join(partes) + "]"
	if total_sel > 24:
		txt += "\n⚠ Muitas antenas: o tempo de simulação cresce ~linearmente com o nº de antenas."
	if not geo.anatel.loaded:
		txt += "\nBase da Anatel não importada: só aparecem torres do OpenStreetMap. Use \"Importar/Baixar base Anatel\" no painel Mapa real."
	lbl_resumo.text = txt


# Interacao

func _on_item_edited() -> void:
	if _rebuilding:
		return
	var it: TreeItem = tree.get_edited()
	if it == null or tree.get_edited_column() != 0:
		return
	var meta: Variant = it.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY:
		return
	var marcado: bool = it.is_checked(0)
	if (meta as Dictionary).has("group"):
		geo.definir_selecao((meta as Dictionary).ids, marcado)
	else:
		geo.definir_selecao([(meta as Dictionary).id], marcado)


func _on_item_activated() -> void:
	var it: TreeItem = tree.get_selected()
	if it == null:
		return
	var meta: Variant = it.get_metadata(0)
	if typeof(meta) == TYPE_DICTIONARY and (meta as Dictionary).has("id"):
		geo.focar_antena((meta as Dictionary).id)


func _marcar_visiveis() -> void:
	var filtro: String = le_filter.text.strip_edges().to_lower()
	var ids: Array = []
	for a in geo.antenas_regiao:
		if filtro == "" or _casa(a, filtro):
			ids.append(a.id)
	geo.definir_selecao(ids, true)
