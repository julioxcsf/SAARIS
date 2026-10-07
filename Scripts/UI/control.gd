extends HBoxContainer
## Barra de controle: Start | Limpar | Relatorio. Sem sinais de simulacao: chamadas diretas ao motor.

const RelatorioConfig = preload("res://Scripts/UI/relatorio_config.gd")

@onready var start_button = $start_button
@onready var cancel_button = $cancel_button       # no antigo "Cancel": agora e o botao "Limpar"
@onready var progress_bar: ProgressBar = $ProgressBar

var report_button: Button

func _ready() -> void:
	start_button.pressed.connect(_on_start_button_pressed)

	cancel_button.text = "Limpar"
	cancel_button.tooltip_text = "Apaga o mapa de potência calculado e devolve o chão ao normal."
	cancel_button.pressed.connect(_on_limpar_pressed)

	# Botao "Relatorio" e o configurador sao criados aqui (nada novo no gui.tscn)
	report_button = Button.new()
	report_button.text = "Relatório"
	report_button.tooltip_text = "Gera o relatório de cobertura (imagem do mapa, antenas, RX com RIS off/on…)."
	add_child(report_button)
	report_button.pressed.connect(_on_report_pressed)
	add_child(RelatorioConfig.new())      # registra-se em Manager.ui_relatorio

	progress_bar.visible = false


func _on_start_button_pressed():
	# Com o modulo geo ativo: se a camera aponta para outra regiao, carrega-a; depois FIXA a regiao
	# (manifesto em GeoCache/regions/) e so entao dispara o simulador.
	if Manager.geo != null:
		var pronto: bool = await Manager.geo.preparar_para_simular()
		if not pronto:
			return
	progress_bar.visible = true
	progress_bar.modulate = Color.WHITE
	progress_bar.value = 0.0
	Manager.engine.start_simulation()          # sincrono: ao voltar, o mapa ja esta pronto
	if Manager.engine.tem_resultado():
		progress_bar.value = 100.0
		progress_bar.modulate = Color.GREEN
	else:
		progress_bar.visible = false


func _on_limpar_pressed():
	progress_bar.value = 0.0
	progress_bar.modulate = Color.WHITE
	progress_bar.visible = false
	Manager.engine.limpar_resultados()         # chamada direta


func _on_report_pressed():
	if Manager.ui_relatorio != null:
		Manager.ui_relatorio.abrir()
