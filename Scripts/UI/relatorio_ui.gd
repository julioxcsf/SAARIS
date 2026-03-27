# relatorio_ui.gd
extends Label

@onready var label_potencia = $"../Label_potencia"
@onready var switch_ponteira = $"../LigarPonteira"


func _ready() -> void:
	Manager.simulation_stats_received.connect(_on_simulation_stats_received)
	Manager.power_probe_updated.connect(_on_power_probe_updated)
	
	switch_ponteira.toggled.connect(func(p): Manager.is_probe_active = p)

func _on_power_probe_updated(dbm: float, _pos: Vector3):
	var pos_str = "(x: %.1f, y: %.1f, z: %.1f)" % [_pos.x, _pos.y, _pos.z]
	
	if dbm > -200.0:
		label_potencia.text = "Sinal: %.2f dBm\nPos: %s" % [dbm, pos_str]
	else:
		label_potencia.text = "Sinal: abaixo de -200 dBm\nPos: %s" % pos_str

func _on_simulation_stats_received(data: Dictionary):
	var total_seconds = int(data["elapsed_time"] / 1000.0)
	var time_str = "%02d:%02d" % [total_seconds / 60, total_seconds % 60]
	
	var texto = "[ RELATÓRIO DE COBERTURA ]\n"
	texto += "Status: %s\n" % ("FINALIZADO" if data["is_final"] else "SIMULANDO...")
	texto += "Tempo: %s\n" % time_str
	texto += "Cobertura: %.1f%% (>= %.0f dBm)\n" % [data["coverage_percent"], data["threshold"]]
	texto += "Área: %.1f x %.1f m\n" % [data["terrain_size"].x, data["terrain_size"].y]
	texto += "Resolução: 1px = %.2fm x %.2fm\n" % [data["res_m_px"].x, data["res_m_px"].y]
	texto += "Freq: %.1f MHz | TXs: %d\n" % [data["frequency"], data["antenna_count"]]
	
	self.text = texto
