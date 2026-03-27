# tx.gd 
extends Node3D

var ligado: bool = true
var freq_mhz: float = 2400.0
var potencia_dbm: float = 20.0

# Opcional: Visualizar mudança no editor
func _process(_delta):
	# Se desligado, talvez ocultar ou mudar a cor?
	visible = ligado
