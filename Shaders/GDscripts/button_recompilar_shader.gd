extends Button

func _ready() -> void:
	pressed.connect(recompilar_shaders)
	
func recompilar_shaders():
	Manager.engine.compilar_shader_glsl2()
	Manager.network_node.iniciar_teste()
