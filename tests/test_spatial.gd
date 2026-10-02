extends SceneTree

# Run with the addon available at res://addons/godot_mcp:
# godot --headless --path <fixture-project> --script <absolute-path>/test_spatial.gd
class SpatialHarness:
	extends "res://addons/godot_mcp/commands/spatial_commands.gd"
	var scene: Node
	func _edited_root() -> Node:
		return scene

var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: " + message)


func _run() -> void:
	var scene := Node3D.new()
	scene.name = "SpatialFixture"
	root.add_child(scene)
	var harness := SpatialHarness.new()
	harness.scene = scene
	root.add_child(harness)
	var commands := harness.get_commands()
	_check(commands.has("get_scene_spatial_info") and commands.has("get_spatial_relationship"), "Tool registration")

	var a := MeshInstance3D.new()
	a.name = "A"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(2, 4, 6)
	a.mesh = mesh
	scene.add_child(a)
	a.position = Vector3(10, 2, 3)
	a.rotation.y = PI / 2.0
	a.scale = Vector3(-2, 1, 0.5)
	var response: Dictionary = harness._get_scene_spatial_info({"node_path": "A"})
	var result: Dictionary = response["result"]
	var bounds: Dictionary = result["aggregate_world_aabb"]
	_check(is_equal_approx(bounds["size"]["x"], 3.0), "Rotation and negative scale preserve world x extent")
	_check(is_equal_approx(bounds["size"]["y"], 4.0), "World y extent")
	_check(is_equal_approx(bounds["size"]["z"], 4.0), "Rotation and negative scale preserve world z extent")
	_check(is_equal_approx(bounds["center"]["x"], 10.0), "World bounds center")
	_check(result["bounds_complete"], "Single mesh bounds are complete")
	_check(result["nodes"][0]["path"] == "A", "Scene-relative paths")
	_check(result["nodes"][0]["world_transform"]["origin"]["y"] == 2.0, "Numeric transform output")

	var b := MeshInstance3D.new()
	b.name = "B"
	var cube := BoxMesh.new()
	cube.size = Vector3(2, 2, 2)
	b.mesh = cube
	b.position = Vector3(20, 2, 3)
	scene.add_child(b)
	result = harness._get_spatial_relationship({"first_path": "A", "second_path": "B"})["result"]
	_check(is_equal_approx(result["axis_gaps"]["x"], 7.5), "Separated boxes have the expected axis gap")
	_check(is_equal_approx(result["center_distance"], 10.0), "Center distance")
	_check(not result["aabb_overlap"] and not result["physics_overlap_tested"], "No false physics collision claim")
	b.position = a.position
	result = harness._get_spatial_relationship({"first_path": "A", "second_path": "B"})["result"]
	_check(result["aabb_overlap"], "Overlapping bounds detected")
	_check(is_zero_approx(result["aabb_distance"]), "Overlapping bounds have zero distance")
	b.position.x = 12.5
	result = harness._get_spatial_relationship({"first_path": "A", "second_path": "B"})["result"]
	_check(result["aabb_touching_or_overlapping"], "Touching bounds detected")
	_check(not result["aabb_overlap"], "Touching is distinguished from positive-volume overlap")

	var multimesh_node := MultiMeshInstance3D.new()
	multimesh_node.name = "Instances"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = cube
	mm.instance_count = 3
	mm.custom_aabb = AABB(Vector3(-1, -1, -1), Vector3(12, 2, 2))
	mm.set_instance_transform(0, Transform3D(Basis.IDENTITY, Vector3.ZERO))
	mm.set_instance_transform(1, Transform3D(Basis.IDENTITY, Vector3(5, 0, 0)))
	mm.set_instance_transform(2, Transform3D(Basis.IDENTITY, Vector3(10, 0, 0)))
	mm.visible_instance_count = 1
	multimesh_node.multimesh = mm
	multimesh_node.position.x = 100
	scene.add_child(multimesh_node)
	result = harness._get_scene_spatial_info({"node_path": "Instances"})["result"]
	_check(result["nodes"][0]["bounds_source"] == "multimesh_custom_aabb", "Use MultiMesh custom aggregate bounds")
	_check(is_equal_approx(result["aggregate_world_aabb"]["position"]["x"], 99.0), "MultiMesh aggregate gets world transform")
	_check(not result["nodes"][0]["multimesh"].has("instances"), "No instance enumeration by default")
	result = harness._get_scene_spatial_info({"node_path": "Instances", "include_multimesh_instances": true, "max_instances": 2})["result"]
	if DisplayServer.get_name() == "headless":
		_check(not result["nodes"][0]["multimesh"]["inspection_available"], "Headless dummy instance transforms are not reported as real data")
		_check(not result["nodes"][0]["multimesh"].has("instances"), "Unavailable instance inspection omits misleading coordinates")
	else:
		_check(result["inspected_instances"] == 2 and result["instance_limit_reached"], "Bounded explicit instance inspection")
		_check(result["nodes"][0]["multimesh"]["instances"][0]["draw_enabled"], "Visible instance flagged")
		_check(not result["nodes"][0]["multimesh"]["instances"][1]["draw_enabled"], "Undrawn allocated instance flagged")
		_check(is_equal_approx(result["nodes"][0]["multimesh"]["instances"][1]["world_aabb"]["center"]["x"], 105.0), "Per-instance world transform composition")
	var second_multimesh := MultiMeshInstance3D.new()
	second_multimesh.name = "MoreInstances"
	second_multimesh.multimesh = mm
	scene.add_child(second_multimesh)
	result = harness._get_scene_spatial_info({"include_multimesh_instances": true, "max_instances": 4})["result"]
	if DisplayServer.get_name() == "headless":
		_check(result["inspected_instances"] == 0, "Headless inspector does not enumerate dummy MultiMesh transforms")
	else:
		_check(result["inspected_instances"] == 4, "Instance limit is global across MultiMeshes")

	result = harness._get_scene_spatial_info({"max_nodes": 2})["result"]
	_check(result["visited_nodes"] == 2 and result["node_limit_reached"] and result["truncated"], "Node traversal limit")
	_check(not result["bounds_complete"], "Partial traversal does not claim complete bounds")
	result = harness._get_scene_spatial_info({"max_depth": 0})["result"]
	_check(result["visited_nodes"] == 1 and result["depth_limit_reached"], "Depth zero inspects only selected root")
	result = harness._get_scene_spatial_info({"node_path": "A", "max_depth": 999, "max_nodes": 9999, "max_instances": 9999})["result"]
	_check(result["limits"]["max_depth"] == 64 and result["limits"]["max_nodes"] == 2000 and result["limits"]["max_instances"] == 1000, "Hard request caps")

	var body := StaticBody3D.new()
	body.name = "Body"
	scene.add_child(body)
	var collision := CollisionShape3D.new()
	collision.name = "Shape"
	var shape := BoxShape3D.new()
	shape.size = Vector3(2, 4, 6)
	collision.shape = shape
	collision.disabled = true
	body.add_child(collision)
	result = harness._get_scene_spatial_info({"node_path": "Body"})["result"]
	_check(result["bounds_nodes"] == 1 and result["nodes"][1]["collision_disabled"], "Disabled authored collision bounds remain explicitly flagged")
	collision.shape = WorldBoundaryShape3D.new()
	result = harness._get_scene_spatial_info({"node_path": "Body"})["result"]
	_check(result["aggregate_world_aabb"] == null and not result["bounds_complete"], "Unbounded shape has no misleading finite bounds")
	_check(result["unavailable_bounds_nodes"] == 1, "Unsupported bounds counted")
	result = harness._get_spatial_relationship({"first_path": "A", "second_path": "Body"})["result"]
	_check(not result["comparison_available"], "Missing bounds cannot produce a relationship")
	_check(harness._get_scene_spatial_info({"node_path": "/root"}).has("error"), "Inspection cannot escape edited scene")
	_check(harness._get_scene_spatial_info({"node_path": "Missing"}).has("error"), "Missing node error")
	_check(harness._get_spatial_relationship({}).has("error"), "Relationship paths required")

	# Non-spatial nodes count towards traversal budgets, preventing unbounded work.
	var wrapper := Node.new()
	wrapper.name = "Wrapper"
	scene.add_child(wrapper)
	var child := Node3D.new()
	wrapper.add_child(child)
	result = harness._get_scene_spatial_info({"node_path": "Wrapper", "max_nodes": 1})["result"]
	_check(result["non_spatial_nodes"] == 1 and result["nodes"].is_empty() and result["truncated"], "Non-spatial traversal is bounded")

	harness.free()
	scene.free()
	print("SPATIAL_TESTS: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
