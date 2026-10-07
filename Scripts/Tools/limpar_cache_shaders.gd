@tool
extends EditorScript

func _run():
	var dir = DirAccess.open("res://.godot/shader_cache/")
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		var cont = 0
		while file_name != "":
			if not dir.current_is_dir():
				dir.remove(file_name)
				cont += 1
			file_name = dir.get_next()
		print("=== [SAARIS] " + str(cont) + " arquivos de cache de shader limpos com sucesso! ===")
	else:
		print("=== [SAARIS] Pasta de cache de shaders não encontrada ou já limpa. ===")
