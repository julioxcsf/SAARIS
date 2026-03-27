extends Camera3D

@export var speed: float = 200.0
@export var sensitivity: float = 0.2
@export var ler_potencia: bool = false

var is_camera_fixed: bool = true
var helper_plane_mesh: MeshInstance3D = null

# Variável interna para acumular a visão vertical e evitar o Gimbal Lock.
var _pitch: float = 0.0 


# Inicializa a câmera e conecta os sinais de configuração.
func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_setup_helper_plane()
	Manager.request_camera_config.connect(_on_camera_config_updated)

# Processa eventos de entrada para alternar modos e capturar cliques.
func _input(event):
	if Input.is_action_just_pressed("ui_cancel"):
		is_camera_fixed = not is_camera_fixed
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if is_camera_fixed else Input.MOUSE_MODE_CAPTURED)

	if not is_camera_fixed:
		if event is InputEventMouseMotion:
			rotate_y(-event.relative.x * sensitivity/100)
			_pitch -= event.relative.y * sensitivity/100
			_pitch = clamp(_pitch, deg_to_rad(-89.0), deg_to_rad(89.0))
			rotation.x = _pitch
			rotation.z = 0.0
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if Manager.current_placement_mode != Manager.PlacementMode.NONE:
			_calculate_plane_intersection(event.position)

# Atualiza a posição do plano visual auxiliar e realiza a leitura da sonda.
func _process(_delta):
	if Manager.current_placement_mode != Manager.PlacementMode.NONE:
		helper_plane_mesh.show()
		helper_plane_mesh.global_position = Vector3.ZERO
		helper_plane_mesh.rotation = Vector3.ZERO
		
		var val = Manager.current_placement_fixed_value
		if Manager.current_placement_axis == "X":
			helper_plane_mesh.global_position.x = val
			helper_plane_mesh.rotation_degrees.z = 90
		elif Manager.current_placement_axis == "Y":
			helper_plane_mesh.global_position.y = val
		elif Manager.current_placement_axis == "Z":
			helper_plane_mesh.global_position.z = val
			helper_plane_mesh.rotation_degrees.x = 90
	else:
		helper_plane_mesh.hide()
	
	if Manager.is_probe_active and is_camera_fixed:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			_execute_probe_reading(get_viewport().get_mouse_position())

# Controla a movimentação física da câmera pelo cenário.
func _physics_process(delta):
	if is_camera_fixed:
		return

	var direction = Vector3.ZERO
	if Input.is_action_pressed("ui_up"):
		direction -= transform.basis.z
	if Input.is_action_pressed("ui_down"):
		direction += transform.basis.z
	if Input.is_action_pressed("ui_left"):
		direction -= transform.basis.x
	if Input.is_action_pressed("ui_right"):
		direction += transform.basis.x
		
	if Input.is_action_pressed("ui_page_up"):
		direction += Vector3.UP
	if Input.is_action_pressed("ui_page_down"):
		direction -= Vector3.UP

	if direction != Vector3.ZERO:
		direction = direction.normalized()
		global_translate(direction * speed * delta)


# Cria a malha do plano auxiliar utilizado para posicionamento.
func _setup_helper_plane():
	helper_plane_mesh = MeshInstance3D.new()
	var mesh = PlaneMesh.new()
	mesh.size = Vector2(5000, 5000)
	helper_plane_mesh.mesh = mesh
	
	var mat = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.2, 0.8, 1.0, 0.2)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	helper_plane_mesh.material_override = mat
	
	add_child(helper_plane_mesh)
	helper_plane_mesh.top_level = true
	helper_plane_mesh.hide()

# Calcula a interseção do clique do mouse com o plano matemático.
func _calculate_plane_intersection(mouse_pos: Vector2):
	var ray_origin = project_ray_origin(mouse_pos)
	var ray_dir = project_ray_normal(mouse_pos)
	
	var normal = Vector3.UP
	if Manager.current_placement_axis == "X": normal = Vector3.RIGHT
	elif Manager.current_placement_axis == "Z": normal = Vector3.FORWARD
	
	var math_plane = Plane(normal, Manager.current_placement_fixed_value)
	var intersection = math_plane.intersects_ray(ray_origin, ray_dir)
	
	if intersection != null:
		Manager.placement_click_resolved.emit(intersection)
		Manager.end_plane_placement()
		helper_plane_mesh.hide()

# Dispara um raio para ler a potência do sinal no local clicado.
func _execute_probe_reading(mouse_pos: Vector2):
	var ray_origin = project_ray_origin(mouse_pos)
	var ray_dir = project_ray_normal(mouse_pos)
	
	var query = PhysicsRayQueryParameters3D.create(ray_origin, ray_origin + ray_dir * 5000)
	var result = get_world_3d().direct_space_state.intersect_ray(query)
	
	if result and Manager.engine:
		var dbm = Manager.engine.get_power_at_world_pos(result.position)
		Manager.power_probe_updated.emit(dbm, result.position)

# Atualiza as configurações de velocidade, sensibilidade e FOV.
func _on_camera_config_updated(new_speed: float, new_sens: float, new_fov: float):
	self.speed = new_speed
	self.sensitivity = new_sens
	self.fov = new_fov
	
	if Manager.DEBUG:
		print("[Camera] Valores atualizados: Speed=%s, Sens=%s, FOV=%s" % [speed, sensitivity, fov])
