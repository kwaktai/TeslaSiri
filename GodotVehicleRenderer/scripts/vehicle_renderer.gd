extends Node3D

const ASSET_PATHS := {
	"model-3-legacy": "res://vehicles/model-3-legacy.glb",
	"model-3-refresh-poppyseed": "res://vehicles/model-3-refresh-poppyseed.glb",
	"model-y-legacy": "res://vehicles/model-y-legacy.glb",
	"model-y-bayberry": "res://vehicles/model-y-bayberry.glb",
	"model-y-bayberry-e41": "res://vehicles/model-y-bayberry-e41.glb",
	"model-y-bayberry-e80": "res://vehicles/model-y-bayberry-e80.glb",
	"model-s-palladium": "res://vehicles/model-s-palladium.glb",
	"model-x-palladium": "res://vehicles/model-x-palladium.glb",
	"semi": "res://vehicles/semi.glb",
	"cybertruck": "res://vehicles/cybertruck.glb",
}

const PAINTS := {
	"RedMulticoat": {"color": Color("0a0101"), "metallic": 0.1, "roughness": 0.04},
	"SolidBlack": {"color": Color("0e0e0e"), "metallic": 1.0, "roughness": 0.04},
	"SilverMetallic": {"color": Color("161616"), "metallic": 0.6, "roughness": 0.04},
	"MidnightSilver": {"color": Color("131416"), "metallic": 0.8, "roughness": 0.04},
	"DeepBlue": {"color": Color("000919"), "metallic": 0.7, "roughness": 0.04},
	"PearlWhite": {"color": Color("181818"), "metallic": 0.25, "roughness": 0.2},
	"TitaniumCopper": {"color": Color("181510"), "metallic": 0.8, "roughness": 0.04},
	"Red": {"color": Color("0a0101"), "metallic": 0.1, "roughness": 0.04},
	"Black": {"color": Color("0e0e0e"), "metallic": 1.0, "roughness": 0.04},
	"Silver": {"color": Color("161616"), "metallic": 0.6, "roughness": 0.04},
	"Grey": {"color": Color("131416"), "metallic": 0.8, "roughness": 0.04},
	"Blue": {"color": Color("000104"), "metallic": 0.6, "roughness": 0.04},
	"SignatureBlue": {"color": Color("000206"), "metallic": 0.2, "roughness": 0.04},
	"White": {"color": Color("141414"), "metallic": 0.2, "roughness": 0.3},
	"Titanium": {"color": Color("181510"), "metallic": 0.8, "roughness": 0.04},
	"Pearl": {"color": Color("131313"), "metallic": 0.01, "roughness": 0.04},
	"MetallicBlack": {"color": Color("0e0e0e"), "metallic": 1.0, "roughness": 0.04},
	"SteelGrey": {"color": Color("131416"), "metallic": 0.8, "roughness": 0.04},
	"Green": {"color": Color("060a0a"), "metallic": 0.8, "roughness": 0.04},
	"Brown": {"color": Color("181514"), "metallic": 0.8, "roughness": 0.04},
	"SigRed": {"color": Color("110305"), "metallic": 0.7, "roughness": 0.04},
	"MidnightCherryRed": {"color": Color("200006"), "metallic": 0.8, "roughness": 0.01},
	"Quicksilver": {"color": Color("2b2d35"), "metallic": 0.85, "roughness": 0.2},
	"UltraRed": {"color": Color("250006"), "metallic": 0.7, "roughness": 0.05},
	"StealthGrey": {"color": Color("121417"), "metallic": 0.88, "roughness": 0.1},
	"LunarSilver": {"color": Color("343438"), "metallic": 0.898, "roughness": 0.28},
	"GlacierBlue": {"color": Color("12161f"), "metallic": 0.7, "roughness": 0.1},
	"DiamondBlack": {"color": Color("040404"), "metallic": 0.75, "roughness": 0.02},
	"FrostBlue": {"color": Color("111317"), "metallic": 0.716, "roughness": 0.05},
	"SilkroadSilver": {"color": Color("2d2c2d"), "metallic": 0.826, "roughness": 0.204},
	"MarineBlue": {"color": Color("01050a"), "metallic": 0.85, "roughness": 0.02},
	"GarnetRed": {"color": Color("1d0305"), "metallic": 0.8, "roughness": 0.05},
}

const ARTICULATION_NODES := {
	"door_lf": ["Door_LF_Spatial", "Door_LF_Locator"],
	"door_lr": ["Door_LR_Spatial", "Door_LR_Locator"],
	"door_rf": ["Door_RF_Spatial", "Door_RF_Locator"],
	"door_rr": ["Door_RR_Spatial", "Door_RR_Locator"],
	"window_lf": ["Window_LF_Spatial", "Window_LF_Locator"],
	"window_lr": ["Window_LR_Spatial", "Window_LR_Locator"],
	"window_rf": ["Window_RF_Spatial", "Window_RF_Locator"],
	"window_rr": ["Window_RR_Spatial", "Window_RR_Locator"],
	"frunk": ["Hood_Spatial", "Hood_Locator", "Hood_locator"],
	"trunk": ["Trunk_Spatial", "Trunk_Locator"],
	"charge_port": ["Charge_Cap_Spatial", "Charge_Port_Spatial", "Charge_Cap_LongRange_Spatial", "ChargeCap_Global_Rotation_Locator"],
}

var _world: WorldEnvironment
var _floor: MeshInstance3D
var _model_holder: Node3D
var _model_instance: Node3D
var _host_bridge: Node
var _current_asset := ""
var _appearance := "dark"
var _exterior_color := "SilverMetallic"
var _paint_override := ""
var _reduce_motion := false
var _state := {
	"door_lf": false,
	"door_lr": false,
	"door_rf": false,
	"door_rr": false,
	"window_lf": false,
	"window_lr": false,
	"window_rf": false,
	"window_rr": false,
	"frunk": false,
	"trunk": false,
	"charge_port": false,
}
var _articulation_nodes := {}
var _rest_transforms := {}
var _articulation_tween: Tween


func _ready() -> void:
	Engine.max_fps = 30
	_create_stage()
	_apply_appearance()
	_load_vehicle("model-3-refresh-poppyseed")
	set_process(true)


func _process(_delta: float) -> void:
	if _host_bridge != null:
		set_process(false)
		return
	var root := get_tree().root
	var candidate := root.get_node_or_null("__swiftgodotkit_bridge__")
	if candidate == null:
		candidate = root.find_child("__swiftgodotkit_bridge__", true, false)
	if candidate == null:
		return
	_host_bridge = candidate
	var signal_name := StringName("messageFromHost")
	if not _host_bridge.has_signal(signal_name):
		signal_name = StringName("message_from_host")
	if _host_bridge.has_signal(signal_name):
		_host_bridge.connect(signal_name, Callable(self, "_on_host_message"))
	_emit_to_host({"type": "renderer_ready", "asset": _current_asset})


func _create_stage() -> void:
	_world = WorldEnvironment.new()
	_world.name = "WorldEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 2.15
	_world.environment = environment
	add_child(_world)

	var key_light := DirectionalLight3D.new()
	key_light.name = "KeyLight"
	key_light.rotation_degrees = Vector3(-48.0, -34.0, 0.0)
	key_light.light_energy = 2.2
	key_light.shadow_enabled = true
	add_child(key_light)

	var fill_light := DirectionalLight3D.new()
	fill_light.name = "FillLight"
	fill_light.rotation_degrees = Vector3(-28.0, 142.0, 0.0)
	fill_light.light_energy = 1.15
	fill_light.shadow_enabled = false
	add_child(fill_light)

	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.fov = 28.0
	camera.position = Vector3(7.6, 3.3, 8.4)
	camera.look_at_from_position(camera.position, Vector3(0.0, 0.85, 0.0), Vector3.UP)
	camera.current = true
	add_child(camera)

	_floor = MeshInstance3D.new()
	_floor.name = "StudioFloor"
	var plane := PlaneMesh.new()
	plane.size = Vector2(18.0, 18.0)
	_floor.mesh = plane
	_floor.position.y = -0.025
	_floor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_floor)


func _on_host_message(message: Dictionary) -> void:
	if String(message.get("type", "")) != "vehicle_state":
		return
	var asset := String(message.get("asset", _current_asset))
	_appearance = String(message.get("appearance", _appearance))
	_exterior_color = String(message.get("exterior_color", _exterior_color))
	_paint_override = String(message.get("paint_override", ""))
	_reduce_motion = bool(message.get("reduce_motion", false))
	for key in _state.keys():
		_state[key] = bool(message.get(key, false))
	_apply_appearance()
	if asset != _current_asset:
		_load_vehicle(asset)
	else:
		_apply_paint()
		_apply_articulations()


func _load_vehicle(asset: String) -> void:
	if not ASSET_PATHS.has(asset):
		_emit_to_host({"type": "renderer_error", "code": "unknown_asset", "asset": asset})
		return
	if _model_holder != null:
		_model_holder.free()
	_model_holder = Node3D.new()
	_model_holder.name = "VehicleModel"
	add_child(_model_holder)
	var packed := load(ASSET_PATHS[asset]) as PackedScene
	if packed == null:
		_emit_to_host({"type": "renderer_error", "code": "load_failed", "asset": asset})
		return
	_model_instance = packed.instantiate() as Node3D
	if _model_instance == null:
		_emit_to_host({"type": "renderer_error", "code": "instantiate_failed", "asset": asset})
		return
	_model_holder.add_child(_model_instance)
	_current_asset = asset
	_hide_embedded_studio_geometry()
	_frame_model()
	_bind_articulations()
	_apply_paint()
	_apply_articulations(false)
	_emit_to_host({"type": "model_loaded", "asset": asset})


func _hide_embedded_studio_geometry() -> void:
	for child in _model_instance.find_children("*", "MeshInstance3D", true, false):
		var lower_name := String(child.name).to_lower()
		if lower_name == "floor" or lower_name.contains("ground_plane"):
			child.visible = false


func _frame_model() -> void:
	var bounds := _model_bounds(_model_instance)
	if bounds.size.length_squared() <= 0.0001:
		return
	var center := bounds.get_center()
	_model_instance.position -= Vector3(center.x, bounds.position.y, center.z)
	var normalized_span: float = maxf(maxf(bounds.size.x, bounds.size.z), bounds.size.y * 2.4)
	var model_scale: float = 6.35 / maxf(normalized_span, 0.001)
	_model_holder.scale = Vector3.ONE * model_scale
	_model_holder.rotation_degrees = Vector3(0.0, -8.0, 0.0)


func _model_bounds(root: Node3D) -> AABB:
	var has_bounds := false
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	var inverse_root := root.global_transform.affine_inverse()
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if not mesh_instance.visible:
			continue
		var local_bounds := mesh_instance.get_aabb()
		var relative := inverse_root * mesh_instance.global_transform
		for x in [0.0, 1.0]:
			for y in [0.0, 1.0]:
				for z in [0.0, 1.0]:
					var corner := local_bounds.position + Vector3(local_bounds.size.x * x, local_bounds.size.y * y, local_bounds.size.z * z)
					var point := relative * corner
					minimum = minimum.min(point)
					maximum = maximum.max(point)
					has_bounds = true
	if not has_bounds:
		return AABB()
	return AABB(minimum, maximum - minimum)


func _paint_values() -> Dictionary:
	var values: Dictionary = PAINTS.get(_exterior_color, PAINTS["SilverMetallic"]).duplicate()
	if not _paint_override.is_empty():
		values["color"] = Color(_paint_override)
	return values


func _apply_paint() -> void:
	if _model_instance == null:
		return
	var values := _paint_values()
	for child in _model_instance.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		for surface in mesh_instance.mesh.get_surface_count():
			var material := mesh_instance.get_active_material(surface)
			if not material is StandardMaterial3D:
				continue
			var material_name := String(material.resource_name).to_lower()
			if not _is_paint_material(material_name):
				continue
			var replacement := material.duplicate() as StandardMaterial3D
			replacement.albedo_color = values["color"]
			replacement.metallic = float(values["metallic"])
			replacement.roughness = float(values["roughness"])
			mesh_instance.set_surface_override_material(surface, replacement)


func _is_paint_material(name: String) -> bool:
	return name.contains("paint") or name == "exterior" or name.begins_with("exterior_")


func _bind_articulations() -> void:
	_articulation_nodes.clear()
	_rest_transforms.clear()
	for key in ARTICULATION_NODES:
		var node := _find_first_node(ARTICULATION_NODES[key])
		if node != null:
			_articulation_nodes[key] = node
			_rest_transforms[key] = node.transform


func _find_first_node(names: Array) -> Node3D:
	for node_name in names:
		var candidate := _model_instance.find_child(String(node_name), true, false)
		if candidate is Node3D:
			return candidate
	return null


func _apply_articulations(animated := true) -> void:
	if _articulation_tween != null and _articulation_tween.is_valid():
		_articulation_tween.kill()
	var duration := 0.0 if _reduce_motion or not animated else 0.46
	if duration > 0.0:
		_articulation_tween = create_tween().set_parallel(true)
		_articulation_tween.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	for key in _articulation_nodes:
		var target := _target_transform(key, bool(_state.get(key, false)))
		var node: Node3D = _articulation_nodes[key]
		if duration > 0.0:
			_articulation_tween.tween_property(node, "transform", target, duration)
		else:
			node.transform = target


func _target_transform(key: String, is_open: bool) -> Transform3D:
	var rest: Transform3D = _rest_transforms[key]
	if not is_open:
		return rest
	var rotation_offset := Vector3.ZERO
	var translation_offset := Vector3.ZERO
	match key:
		"door_lf", "door_lr":
			rotation_offset.y = deg_to_rad(58.0)
		"door_rf", "door_rr":
			rotation_offset.y = deg_to_rad(-58.0)
		"frunk":
			rotation_offset.z = deg_to_rad(-38.0)
		"trunk":
			rotation_offset.z = deg_to_rad(52.0)
		"charge_port":
			rotation_offset.y = deg_to_rad(72.0)
		"window_lf", "window_lr", "window_rf", "window_rr":
			translation_offset.y = -0.42
	if _current_asset == "model-x-palladium" and key in ["door_lr", "door_rr"]:
		rotation_offset = Vector3(deg_to_rad(-56.0), 0.0, 0.0)
	var target := rest
	target.basis = rest.basis * Basis.from_euler(rotation_offset)
	target.origin = rest.origin + translation_offset
	return target


func _apply_appearance() -> void:
	if _world == null or _floor == null:
		return
	var is_dark := _appearance != "light"
	var environment := _world.environment
	environment.background_color = Color("050405") if is_dark else Color("faf7f3")
	environment.ambient_light_color = Color("8f95a2") if is_dark else Color("fff4ea")
	environment.ambient_light_energy = 1.35 if is_dark else 1.15
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color("111014") if is_dark else Color("eee9e2")
	floor_material.metallic = 0.22
	floor_material.roughness = 0.36
	_floor.material_override = floor_material


func _emit_to_host(message: Dictionary) -> void:
	if _host_bridge == null:
		return
	if _host_bridge.has_method("emitMessageToHost"):
		_host_bridge.call("emitMessageToHost", message)
	elif _host_bridge.has_method("emit_message_to_host"):
		_host_bridge.call("emit_message_to_host", message)
