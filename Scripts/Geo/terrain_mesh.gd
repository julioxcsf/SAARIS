extends RefCounted
## Gera a malha 3D do terreno a partir do heightfield.
##   - UV 0..1 cobrindo exatamente a regiao (o mapa de calor usa isso)
##   - normais por diferencas centrais (relevo visivel com a luz direcional)
##   - cor por altitude (verde -> marrom -> cinza) enquanto nao ha mapa de calor
##   - colisao trimesh (cliques de posicionamento e ponteira de potencia)

const COR_BAIXA := Color(0.20, 0.42, 0.20)
const COR_MEDIA := Color(0.45, 0.40, 0.25)
const COR_ALTA := Color(0.62, 0.60, 0.58)


func build(hf: Dictionary) -> MeshInstance3D:
	var res: int = hf.res
	var step: float = hf.step
	var off: Vector2 = hf.offset
	var heights: PackedFloat32Array = hf.heights
	var hmin: float = hf.hmin
	var hmax: float = hf.hmax
	var faixa: float = maxf(hmax - hmin, 1.0)

	var verts: PackedVector3Array = PackedVector3Array()
	var norms: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var cols: PackedColorArray = PackedColorArray()
	verts.resize(res * res)
	norms.resize(res * res)
	uvs.resize(res * res)
	cols.resize(res * res)

	var inv: float = 1.0 / float(res - 1)
	for iz in res:
		var izm: int = maxi(iz - 1, 0)
		var izp: int = mini(iz + 1, res - 1)
		for ix in res:
			var i: int = iz * res + ix
			var h: float = heights[i]
			verts[i] = Vector3(off.x + float(ix) * step, h, off.y + float(iz) * step)
			uvs[i] = Vector2(float(ix) * inv, float(iz) * inv)

			var hl: float = heights[iz * res + maxi(ix - 1, 0)]
			var hr: float = heights[iz * res + mini(ix + 1, res - 1)]
			var hu: float = heights[izm * res + ix]
			var hd: float = heights[izp * res + ix]
			norms[i] = Vector3(hl - hr, 2.0 * step, hu - hd).normalized()

			var t: float = clampf((h - hmin) / faixa, 0.0, 1.0)
			cols[i] = COR_BAIXA.lerp(COR_MEDIA, clampf(t * 2.0, 0.0, 1.0)).lerp(COR_ALTA, clampf(t * 2.0 - 1.0, 0.0, 1.0))

	# Triangulos (horario visto de cima = face frontal no Godot)
	var idx: PackedInt32Array = PackedInt32Array()
	idx.resize((res - 1) * (res - 1) * 6)
	var k: int = 0
	for iz in res - 1:
		for ix in res - 1:
			var a: int = iz * res + ix
			var b: int = a + 1
			var c: int = a + res
			var d: int = c + 1
			idx[k] = a; idx[k + 1] = b; idx[k + 2] = c
			idx[k + 3] = b; idx[k + 4] = d; idx[k + 5] = c
			k += 6

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx

	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh

	var sb: StaticBody3D = StaticBody3D.new()
	sb.name = "StaticBody3D"
	var col: CollisionShape3D = CollisionShape3D.new()
	col.name = "CollisionShape3D"
	col.shape = mesh.create_trimesh_shape()
	sb.add_child(col)
	mi.add_child(sb)
	return mi
