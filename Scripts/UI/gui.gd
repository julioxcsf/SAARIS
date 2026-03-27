extends Control

func _ready():
	_desabilitar_navegacao_por_teclado(self)

func _desabilitar_navegacao_por_teclado(node: Node):
	# BaseButton engloba Button, CheckBox, OptionButton, etc.
	if node is BaseButton:
		node.focus_mode = Control.FOCUS_NONE
	
	for child in node.get_children():
		_desabilitar_navegacao_por_teclado(child)
