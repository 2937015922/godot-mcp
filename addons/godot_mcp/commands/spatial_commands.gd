@tool
extends "res://addons/godot_mcp/commands/base_commands.gd"

## Read-only, bounded inspection of the currently edited scene. AABBs describe
## authored geometry, not physics contacts, camera visibility, or runtime state.

func get_commands() -> Dictionary:
	return {
		"get_scene_spatial_info": _get_scene_spatial_info,
		"get_spatial_relationship": _get_spatial_relationship,
	}


func _get_scene_spatial_info(p: Dictionary) -> Dictionary:
	var node := _resolve_scene_node(str(p.get("node_path", ".")))
	if node == null:
		return _err("Node not found in the currently edited scene")
	return _ok(_scan(node, p))


func _get_spatial_relationship(p: Dictionary) -> Dictionary:
	if not p.has("first_path") or not p.has("second_path"):
		return _err("first_path and second_path are required")
	var first := _resolve_scene_node(str(p["first_path"]))
	var second := _resolve_scene_node(str(p["second_path"]))
	if first == null or second == null:
		return _err("Both nodes must exist in the currently edited scene")
	# Relationship inspection never expands MultiMeshes into individual instances.
	var scan_params := p.duplicate()
	scan_params["include_multimesh_instances"] = false
	var a := _scan(first, scan_params)
	var b := _scan(second, scan_params)
	a.erase("nodes")
	b.erase("nodes")
	var result := {
		"first": a, "second": b,
		"space": "world", "physics_overlap_tested": false,
		"bounds_complete": bool(a["bounds_complete"]) and bool(b["bounds_complete"]),
		"comparison_available": false,
		"note": "Axis-aligned authored bounds only; includes hidden geometry and disabled collision shapes. Overlap does not establish a physics collision.",
	}
	if a["aggregate_world_aabb"] == null or b["aggregate_world_aabb"] == null:
		result["reason"] = "One or both subtrees have no supported finite bounds within the traversal limits"
		return _ok(result)
	var box_a := _dict_aabb(a["aggregate_world_aabb"])
	var box_b := _dict_aabb(b["aggregate_world_aabb"])
	var delta := box_b.get_center() - box_a.get_center()
	var gap := Vector3(
		maxf(0.0, maxf(box_a.position.x - box_b.end.x, box_b.position.x - box_a.end.x)),
		maxf(0.0, maxf(box_a.position.y - box_b.end.y, box_b.position.y - box_a.end.y)),
		maxf(0.0, maxf(box_a.position.z - box_b.end.z, box_b.position.z - box_a.end.z))
	)
	var overlap_extent := box_a.end.min(box_b.end) - box_a.position.max(box_b.position)
	result["comparison_available"] = true
	result["center_delta"] = _vec(delta)
	result["center_distance"] = delta.length()
	result["axis_gaps"] = _vec(gap)
	result["aabb_distance"] = gap.length()
	result["aabb_overlap"] = overlap_extent.x > 0.0 and overlap_extent.y > 0.0 and overlap_extent.z > 0.0
	result["aabb_touching_or_overlapping"] = overlap_extent.x >= 0.0 and overlap_extent.y >= 0.0 and overlap_extent.z >= 0.0
	result["overlap_extents"] = _vec(overlap_extent.max(Vector3.ZERO))
	return _ok(result)


func _resolve_scene_node(path: String) -> Node:
	var scene := _edited_root()
	var node := _resolve_node(path)
	if scene == null or node == null:
		return null
	if node != scene and not scene.is_ancestor_of(node):
		return null
	return node


func _scan(node: Node, p: Dictionary) -> Dictionary:
	var state := {
		"max_depth": clampi(int(p.get("max_depth", 6)), 0, 64),
		"max_nodes": clampi(int(p.get("max_nodes", 200)), 1, 2000),
		"max_instances": clampi(int(p.get("max_instances", 100)), 1, 1000),
		"include_instances": bool(p.get("include_multimesh_instances", false)),
		"nodes": [], "visited_nodes": 0, "non_spatial_nodes": 0,
		"node_limit_reached": false, "depth_limit_reached": false,
		"omitted_subtrees": 0, "inspected_instances": 0,
		"instance_limit_reached": false, "bounds_nodes": 0,
		"unavailable_bounds_nodes": 0, "aggregate": null,
	}
	_visit(node, 0, state)
	var truncated: bool = state["node_limit_reached"] or state["depth_limit_reached"]
	var result := {
		"root_path": _scene_path(node), "source": "edited_scene", "space": "world",
		"nodes": state["nodes"], "visited_nodes": state["visited_nodes"],
		"non_spatial_nodes": state["non_spatial_nodes"],
		"bounds_nodes": state["bounds_nodes"],
		"unavailable_bounds_nodes": state["unavailable_bounds_nodes"],
		"aggregate_world_aabb": null,
		"bounds_complete": not truncated and int(state["unavailable_bounds_nodes"]) == 0,
		"truncated": truncated,
		"node_limit_reached": state["node_limit_reached"],
		"depth_limit_reached": state["depth_limit_reached"],
		"omitted_subtrees": state["omitted_subtrees"],
		"inspected_instances": state["inspected_instances"],
		"instance_limit_reached": state["instance_limit_reached"],
		"limits": {"max_depth": state["max_depth"], "max_nodes": state["max_nodes"], "max_instances": state["max_instances"]},
		"bounds_policy": "Finite authored mesh/culling and collision-debug bounds, including hidden nodes and disabled shapes; no physics query or camera-visibility test. Runtime-only nodes are not present.",
	}
	if state["aggregate"] != null:
		result["aggregate_world_aabb"] = _aabb_dict(state["aggregate"])
	return result


func _visit(node: Node, depth: int, state: Dictionary) -> void:
	state["visited_nodes"] += 1
	if node is Node3D:
		var spatial := node as Node3D
		var info := {
			"path": _scene_path(node), "name": str(node.name), "class": node.get_class(),
			"depth": depth, "position": _vec(spatial.position),
			"world_position": _vec(spatial.global_position),
			"local_transform": _transform_dict(spatial.transform),
			"world_transform": _transform_dict(spatial.global_transform),
			"visible": spatial.visible, "visible_in_tree": spatial.is_visible_in_tree(),
			"world_aabb": null,
		}
		var bounds := _local_bounds(spatial)
		info["bounds_status"] = bounds["status"]
		info["bounds_source"] = bounds.get("source", "")
		info["bounds_reason"] = bounds.get("reason", "")
		if spatial is CollisionShape3D:
			info["collision_disabled"] = spatial.disabled
		if bounds.has("aabb"):
			var world_box := _transform_aabb(bounds["aabb"], spatial.global_transform)
			if world_box.position.is_finite() and world_box.size.is_finite():
				info["local_aabb"] = _aabb_dict(bounds["aabb"])
				info["world_aabb"] = _aabb_dict(world_box)
				state["bounds_nodes"] += 1
				if state["aggregate"] == null:
					state["aggregate"] = world_box
				else:
					var aggregate: AABB = state["aggregate"]
					state["aggregate"] = aggregate.merge(world_box)
			else:
				info["bounds_status"] = "unavailable"
				info["bounds_reason"] = "Non-finite bounds or transform"
		if info["bounds_status"] == "unavailable":
			state["unavailable_bounds_nodes"] += 1
		if spatial is MultiMeshInstance3D:
			info["multimesh"] = _multimesh_info(spatial, state)
		state["nodes"].append(info)
	else:
		state["non_spatial_nodes"] += 1
	var child_count := node.get_child_count()
	if depth >= int(state["max_depth"]):
		if child_count > 0:
			state["depth_limit_reached"] = true
			state["omitted_subtrees"] += child_count
		return
	for index in range(child_count):
		if int(state["visited_nodes"]) >= int(state["max_nodes"]):
			state["node_limit_reached"] = true
			state["omitted_subtrees"] += child_count - index
			return
		_visit(node.get_child(index), depth + 1, state)


func _local_bounds(node: Node3D) -> Dictionary:
	if node is CollisionShape3D:
		var shape: Shape3D = node.shape
		if shape == null:
			return {"status": "unavailable", "reason": "CollisionShape3D has no shape resource"}
		if shape is WorldBoundaryShape3D:
			return {"status": "unavailable", "reason": "WorldBoundaryShape3D is unbounded; a finite AABB would be misleading"}
		var debug_mesh: ArrayMesh = shape.get_debug_mesh()
		if debug_mesh == null or debug_mesh.get_surface_count() == 0:
			return {"status": "unavailable", "reason": "Shape has no finite debug mesh bounds"}
		return _bounds(debug_mesh.get_aabb(), "collision_debug_mesh", "Shape debug bounds; solver margins and physics contacts are not evaluated")
	if node is MultiMeshInstance3D:
		var mm: MultiMesh = node.multimesh
		if mm == null or mm.mesh == null or mm.instance_count == 0:
			return {"status": "unavailable", "reason": "MultiMesh requires a mesh and at least one allocated instance"}
		if mm.transform_format != MultiMesh.TRANSFORM_3D:
			return {"status": "unavailable", "reason": "MultiMesh uses 2D transforms"}
		if node.custom_aabb != AABB():
			return _bounds(node.custom_aabb, "geometry_custom_aabb", "Authored culling bounds may differ from visible geometry")
		if mm.custom_aabb != AABB():
			return _bounds(mm.custom_aabb, "multimesh_custom_aabb", "Authored culling bounds may differ from visible geometry")
		var mm_box := mm.get_aabb()
		if mm_box == AABB():
			return {"status": "unavailable", "reason": "Engine MultiMesh visibility AABB is empty; it may need a rendering update or an authored custom_aabb"}
		return _bounds(mm_box, "multimesh_engine_aabb", "Engine aggregate visibility bounds; instances are not enumerated")
	if node is MeshInstance3D and node.mesh == null:
		return {"status": "unavailable", "reason": "MeshInstance3D has no mesh resource"}
	if node is GeometryInstance3D:
		if node.custom_aabb != AABB():
			return _bounds(node.custom_aabb, "geometry_custom_aabb", "Authored culling bounds may differ from visible geometry")
		return _bounds(node.get_aabb(), "geometry_engine_aabb", "Engine local bounds; animated deformation and shader displacement are not separately evaluated")
	if node is GridMap or node is CollisionPolygon3D:
		return {"status": "unavailable", "reason": "%s bounds are not supported by this inspector" % node.get_class()}
	return {"status": "not_applicable", "reason": "Node has no directly supported geometry; descendants are inspected separately"}


func _bounds(box: AABB, source: String, reason: String) -> Dictionary:
	if not box.position.is_finite() or not box.size.is_finite():
		return {"status": "unavailable", "source": source, "reason": "Non-finite local bounds"}
	return {"status": "available", "aabb": box.abs(), "source": source, "reason": reason}


func _multimesh_info(node: MultiMeshInstance3D, state: Dictionary) -> Dictionary:
	var mm := node.multimesh
	if mm == null:
		return {"instance_count": 0, "reason": "No MultiMesh resource"}
	var result := {
		"instance_count": mm.instance_count, "visible_instance_count": mm.visible_instance_count,
		"inspection_requested": state["include_instances"],
	}
	if not bool(state["include_instances"]):
		return result
	result["inspection_available"] = false
	if mm.transform_format != MultiMesh.TRANSFORM_3D:
		result["reason"] = "Per-instance inspection requires 3D transforms"
		return result
	if DisplayServer.get_name() == "headless":
		result["reason"] = "Headless rendering returns dummy MultiMesh transforms; open the project in a graphical editor for per-instance inspection"
		return result
	result["inspection_available"] = true
	var remaining := int(state["max_instances"]) - int(state["inspected_instances"])
	var count := mini(mm.instance_count, remaining)
	var instances: Array = []
	for index in range(count):
		var local := mm.get_instance_transform(index)
		var world := node.global_transform * local
		var item := {
			"index": index, "local_transform": _transform_dict(local),
			"world_transform": _transform_dict(world),
			"draw_enabled": mm.visible_instance_count < 0 or index < mm.visible_instance_count,
			"world_aabb": null,
		}
		if mm.mesh != null:
			item["world_aabb"] = _aabb_dict(_transform_aabb(mm.mesh.get_aabb(), world))
		instances.append(item)
	state["inspected_instances"] += count
	result["instances"] = instances
	result["instances_truncated"] = count < mm.instance_count
	result["inspection_scope"] = "First allocated indices, sharing max_instances across the entire request"
	if count < mm.instance_count:
		state["instance_limit_reached"] = true
	return result


func _transform_aabb(box: AABB, transform: Transform3D) -> AABB:
	# Eight corners handle rotation, non-uniform/negative scale, and shear.
	var result := AABB(transform * box.get_endpoint(0), Vector3.ZERO)
	for index in range(1, 8):
		result = result.expand(transform * box.get_endpoint(index))
	return result


func _scene_path(node: Node) -> String:
	var scene := _edited_root()
	return str(scene.get_path_to(node)) if scene != null else str(node.get_path())


func _vec(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}


func _transform_dict(value: Transform3D) -> Dictionary:
	return {"origin": _vec(value.origin), "basis": {"x": _vec(value.basis.x), "y": _vec(value.basis.y), "z": _vec(value.basis.z)}}


func _aabb_dict(value: AABB) -> Dictionary:
	return {"position": _vec(value.position), "size": _vec(value.size), "end": _vec(value.end), "center": _vec(value.get_center())}


func _dict_aabb(value: Dictionary) -> AABB:
	var pos: Dictionary = value["position"]
	var size: Dictionary = value["size"]
	return AABB(Vector3(pos["x"], pos["y"], pos["z"]), Vector3(size["x"], size["y"], size["z"]))
