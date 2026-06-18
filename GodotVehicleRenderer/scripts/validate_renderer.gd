extends SceneTree

const ASSETS := [
	"cybertruck",
	"model-3-legacy",
	"model-3-refresh-poppyseed",
	"model-s-palladium",
	"model-x-palladium",
	"model-y-bayberry",
	"model-y-bayberry-e41",
	"model-y-bayberry-e80",
	"model-y-legacy",
	"semi",
]


func _initialize() -> void:
	call_deferred("_validate")


func _validate() -> void:
	var failures := 0
	for asset in ASSETS:
		var path := "res://vehicles/%s.glb" % asset
		var packed := load(path) as PackedScene
		if packed == null:
			push_error("Unable to load %s" % path)
			failures += 1
			continue
		var instance := packed.instantiate()
		var mesh_count := instance.find_children("*", "MeshInstance3D", true, false).size()
		if mesh_count == 0:
			push_error("No meshes found in %s" % path)
			failures += 1
		else:
			print("Validated %s (%d meshes)" % [asset, mesh_count])
		instance.free()
	quit(1 if failures > 0 else 0)
