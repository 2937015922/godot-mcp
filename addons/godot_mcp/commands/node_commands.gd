@tool
extends "res://addons/godot_mcp/commands/base_commands.gd"

const SceneSafety = preload("res://addons/godot_mcp/utils/scene_safety.gd")


func get_commands() -> Dictionary:
	return {
		"add_node": _add_node,
		"delete_node": _delete_node,
		"duplicate_node": _duplicate_node,
		"move_node": _move_node,
		"rename_node": _rename_node,
		"update_property": _update_property,
		"get_node_properties": _get_node_properties,
		"get_signals": _get_signals,
		"add_resource": _add_resource,
		"set_anchor_preset": _set_anchor_preset,
		"connect_signal": _connect_signal,
		"disconnect_signal": _disconnect_signal,
		"get_node_groups": _get_node_groups,
		"set_node_groups": _set_node_groups,
		"find_nodes_in_group": _find_nodes_in_group,
	}


func _add_node(params: Dictionary) -> Dictionary:
	var node_type: String = params.get("type", "Node")
	var node_name: String = params.get("name", "")
	var parent_path: String = params.get("parent_path", ".")
	var properties: Dictionary = params.get("properties", {})

	var type_error := SceneSafety.node_type_error(node_type)
	if not type_error.is_empty():
		return _err(type_error)

	var root := _edited_root()
	if root == null:
		return _err("No scene is open")

	var parent := _scene_node(parent_path)
	if parent == null:
		return _err("Parent node not found: %s" % parent_path)

	var node: Node = ClassDB.instantiate(node_type)
	if not node_name.is_empty():
		node.name = node_name
	var parsed_properties := {}
	for key in properties:
		var value: Variant = TypeParser.parse(str(properties[key]))
		var error := SceneSafety.property_error(node, str(key), value)
		if not error.is_empty():
			node.free()
			return _err(error)
		parsed_properties[key] = value

	editor_plugin.get_undo_redo().create_action("MCP Add Node", UndoRedo.MERGE_DISABLE, root)
	editor_plugin.get_undo_redo().add_do_method(parent, "add_child", node, true)
	editor_plugin.get_undo_redo().add_do_method(node, "set_owner", root)
	for key in parsed_properties:
		editor_plugin.get_undo_redo().add_do_property(node, key, parsed_properties[key])
	editor_plugin.get_undo_redo().add_do_reference(node)
	editor_plugin.get_undo_redo().add_undo_method(parent, "remove_child", node)
	editor_plugin.get_undo_redo().commit_action()

	return _ok({
		"path": str(node.get_path()),
		"type": node_type,
		"name": node.name,
	})


func _delete_node(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var node := _scene_node(node_path)
	if node == null:
		return _err("Node not found: %s" % node_path)
	if node == _edited_root():
		return _err("Cannot delete scene root")

	var parent := node.get_parent()
	var old_index := node.get_index()
	var owners := SceneSafety.capture_owners(node)
	editor_plugin.get_undo_redo().create_action("MCP Delete Node", UndoRedo.MERGE_DISABLE, _edited_root())
	editor_plugin.get_undo_redo().add_do_method(parent, "remove_child", node)
	editor_plugin.get_undo_redo().add_undo_method(parent, "add_child", node, true)
	editor_plugin.get_undo_redo().add_undo_method(parent, "move_child", node, old_index)
	editor_plugin.get_undo_redo().add_undo_method(self, "_restore_owners", owners)
	editor_plugin.get_undo_redo().add_undo_reference(node)
	editor_plugin.get_undo_redo().commit_action()

	return _ok({"deleted": node_path})


func _duplicate_node(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var node := _scene_node(node_path)
	if node == null:
		return _err("Node not found: %s" % node_path)
	if node == _edited_root():
		return _err("Cannot duplicate scene root")

	var dup := node.duplicate(Node.DUPLICATE_USE_INSTANTIATION | Node.DUPLICATE_SIGNALS | Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS)
	if dup == null:
		return _err("Could not duplicate node")
	var owners := SceneSafety.duplicate_owners(node, dup, _edited_root())
	var parent := node.get_parent()
	editor_plugin.get_undo_redo().create_action("MCP Duplicate Node", UndoRedo.MERGE_DISABLE, _edited_root())
	editor_plugin.get_undo_redo().add_do_method(parent, "add_child", dup, true)
	editor_plugin.get_undo_redo().add_do_method(self, "_restore_owners", owners)
	editor_plugin.get_undo_redo().add_do_reference(dup)
	editor_plugin.get_undo_redo().add_undo_method(parent, "remove_child", dup)
	editor_plugin.get_undo_redo().commit_action()

	return _ok({"path": str(dup.get_path()), "name": dup.name})


func _move_node(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var new_parent_path: String = params.get("new_parent_path", ".")
	var node := _scene_node(node_path)
	if node == null:
		return _err("Node not found: %s" % node_path)
	if node == _edited_root():
		return _err("Cannot move scene root")
	var new_parent := _scene_node(new_parent_path)
	if new_parent == null:
		return _err("New parent not found: %s" % new_parent_path)
	if node == new_parent or node.is_ancestor_of(new_parent):
		return _err("Cannot move a node beneath itself or a descendant")

	var old_parent := node.get_parent()
	if old_parent == new_parent:
		return _ok({"path": str(node.get_path()), "moved": false})
	var old_index := node.get_index()
	var old_name := node.name
	var owners := SceneSafety.capture_owners(node)
	for entry in owners:
		var owner: Node = entry.owner
		if owner != null and owner != node and not node.is_ancestor_of(owner) and owner != new_parent and not owner.is_ancestor_of(new_parent):
			return _err("Reparenting would cross an instance ownership boundary; make the subtree local first")
	var local_transform: Variant = node.transform if node is Node3D or node is Node2D else (node.position if node is Control else null)
	editor_plugin.get_undo_redo().create_action("MCP Move Node", UndoRedo.MERGE_DISABLE, _edited_root())
	editor_plugin.get_undo_redo().add_do_method(node, "reparent", new_parent, true)
	editor_plugin.get_undo_redo().add_do_method(self, "_restore_owners", owners)
	editor_plugin.get_undo_redo().add_undo_method(node, "reparent", old_parent, true)
	editor_plugin.get_undo_redo().add_undo_method(old_parent, "move_child", node, old_index)
	editor_plugin.get_undo_redo().add_undo_property(node, "name", old_name)
	editor_plugin.get_undo_redo().add_undo_method(self, "_restore_owners", owners)
	if node is Node3D or node is Node2D:
		editor_plugin.get_undo_redo().add_undo_property(node, "transform", local_transform)
	elif node is Control:
		editor_plugin.get_undo_redo().add_undo_property(node, "position", local_transform)
	editor_plugin.get_undo_redo().commit_action()

	return _ok({"path": str(node.get_path())})


func _rename_node(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var new_name: String = params.get("new_name", "")
	var node := _scene_node(node_path)
	if node == null:
		return _err("Node not found: %s" % node_path)
	if new_name.is_empty():
		return _err("Missing 'new_name'")

	var old_name := node.name
	editor_plugin.get_undo_redo().create_action("MCP Rename Node")
	editor_plugin.get_undo_redo().add_do_property(node, "name", new_name)
	editor_plugin.get_undo_redo().add_undo_property(node, "name", old_name)
	editor_plugin.get_undo_redo().commit_action()

	return _ok({"path": str(node.get_path()), "name": new_name})


func _update_property(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var property: String = params.get("property", "")
	var value_text: String = str(params.get("value", ""))
	var node := _scene_node(node_path)
	if node == null:
		return _err("Node not found: %s" % node_path)
	if property.is_empty():
		return _err("Missing 'property'")

	var parsed := TypeParser.parse(value_text)
	var error := SceneSafety.property_error(node, property, parsed)
	if not error.is_empty():
		return _err(error)
	var old_value = node.get(property)
	editor_plugin.get_undo_redo().create_action("MCP Update Property")
	editor_plugin.get_undo_redo().add_do_property(node, property, parsed)
	editor_plugin.get_undo_redo().add_undo_property(node, property, old_value)
	editor_plugin.get_undo_redo().commit_action()

	return _ok({
		"node_path": str(node.get_path()),
		"property": property,
		"value": _serialize_value(parsed),
	})


func _get_node_properties(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var node := _resolve_node(node_path)
	if node == null:
		return _err("Node not found: %s" % node_path)

	var props := {}
	for info in node.get_property_list():
		if info.usage & PROPERTY_USAGE_EDITOR:
			var name: String = info.name
			props[name] = _serialize_value(node.get(name))
	return _ok({"node_path": str(node.get_path()), "type": node.get_class(), "properties": props})


func _get_signals(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var node := _resolve_node(node_path)
	if node == null:
		return _err("Node not found: %s" % node_path)

	var signals_out: Array = []
	for sig_info in node.get_signal_list():
		var connections: Array = []
		for conn in node.get_signal_connection_list(sig_info.name):
			connections.append({
				"target": str(conn.callable.get_object()),
				"method": conn.callable.get_method(),
			})
		signals_out.append({
			"name": sig_info.name,
			"connections": connections,
		})
	return _ok({"node_path": str(node.get_path()), "signals": signals_out})


func _add_resource(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var resource_type: String = params.get("resource_type", "")
	var node := _scene_node(node_path)
	if node == null:
		return _err("Node not found")
	if not ClassDB.class_exists(resource_type) or not ClassDB.is_parent_class(resource_type, "Resource") or not ClassDB.can_instantiate(resource_type):
		return _err("Unknown resource type: %s" % resource_type)
	var res: Resource = ClassDB.instantiate(resource_type)
	var property := ""
	if node is CollisionShape2D and res is Shape2D:
		property = "shape"
	elif node is CollisionShape3D and res is Shape3D:
		property = "shape"
	elif node is MeshInstance3D and res is Mesh:
		property = "mesh"
	elif node is Sprite2D and res is Texture2D:
		property = "texture"
	else:
		return _err("Cannot auto-assign %s to %s" % [resource_type, node.get_class()])
	_undo_property(node, property, res)
	return _ok({"node_path": node_path, "resource_type": resource_type})


func _set_anchor_preset(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var preset_name: String = params.get("preset", "center")
	var node := _scene_node(node_path)
	if node == null or not node is Control:
		return _err("Control node required")
	var preset_map := {
		"top_left": Control.PRESET_TOP_LEFT,
		"center": Control.PRESET_CENTER,
		"full_rect": Control.PRESET_FULL_RECT,
		"bottom_right": Control.PRESET_BOTTOM_RIGHT,
	}
	if not preset_map.has(preset_name):
		return _err("Unknown preset: %s" % preset_name)
	var props := ["anchor_left", "anchor_top", "anchor_right", "anchor_bottom", "offset_left", "offset_top", "offset_right", "offset_bottom"]
	var before: Array = []
	for property in props:
		before.append(node.get(property))
	node.set_anchors_preset(preset_map[preset_name])
	var after: Array = []
	for property in props:
		after.append(node.get(property))
	for i in props.size():
		node.set(props[i], before[i])
	var undo := editor_plugin.get_undo_redo()
	undo.create_action("MCP Set Anchor Preset", UndoRedo.MERGE_DISABLE, _edited_root())
	for i in props.size():
		undo.add_do_property(node, props[i], after[i])
		undo.add_undo_property(node, props[i], before[i])
	undo.commit_action()
	return _ok({"node_path": node_path, "preset": preset_name})


func _connect_signal(params: Dictionary) -> Dictionary:
	var from_path: String = params.get("from_path", "")
	var signal_name: String = params.get("signal", "")
	var to_path: String = params.get("to_path", "")
	var method_name: String = params.get("method", "")
	var from_node := _scene_node(from_path)
	var to_node := _scene_node(to_path)
	if from_node == null or to_node == null:
		return _err("Source or target node not found")
	if not from_node.has_signal(signal_name) or not to_node.has_method(method_name):
		return _err("Signal or target method does not exist")
	var callable := Callable(to_node, method_name)
	if from_node.is_connected(signal_name, callable):
		return _err("Signal is already connected")
	var undo := editor_plugin.get_undo_redo()
	undo.create_action("MCP Connect Signal", UndoRedo.MERGE_DISABLE, _edited_root())
	undo.add_do_method(from_node, "connect", signal_name, callable, Object.CONNECT_PERSIST)
	undo.add_undo_method(from_node, "disconnect", signal_name, callable)
	undo.commit_action()
	return _ok({"connected": true})


func _disconnect_signal(params: Dictionary) -> Dictionary:
	var from_path: String = params.get("from_path", "")
	var signal_name: String = params.get("signal", "")
	var to_path: String = params.get("to_path", "")
	var method_name: String = params.get("method", "")
	var from_node := _scene_node(from_path)
	var to_node := _scene_node(to_path)
	if from_node == null or to_node == null:
		return _err("Source or target node not found")
	var callable := Callable(to_node, method_name)
	if not from_node.has_signal(signal_name) or not from_node.is_connected(signal_name, callable):
		return _err("Signal connection does not exist")
	var flags := 0
	for connection in from_node.get_signal_connection_list(signal_name):
		if connection.callable == callable:
			flags = connection.flags
	var undo := editor_plugin.get_undo_redo()
	undo.create_action("MCP Disconnect Signal", UndoRedo.MERGE_DISABLE, _edited_root())
	undo.add_do_method(from_node, "disconnect", signal_name, callable)
	undo.add_undo_method(from_node, "connect", signal_name, callable, flags)
	undo.commit_action()
	return _ok({"disconnected": true})


func _get_node_groups(params: Dictionary) -> Dictionary:
	var node := _resolve_node(params.get("node_path", ""))
	if node == null:
		return _err("Node not found")
	return _ok({"groups": node.get_groups()})


func _set_node_groups(params: Dictionary) -> Dictionary:
	var node := _scene_node(params.get("node_path", ""))
	if node == null:
		return _err("Node not found")
	var groups: Array = params.get("groups", [])
	var previous := {}
	var packed := PackedScene.new()
	# Pack a detached duplicate: packing an owned child directly asks Godot to
	# resolve its external scene owner and can lose inherited group metadata.
	var group_snapshot := node.duplicate(Node.DUPLICATE_GROUPS)
	if group_snapshot == null:
		return _err("Could not inspect persistent groups")
	var pack_error := packed.pack(group_snapshot)
	group_snapshot.free()
	if pack_error != OK:
		return _err("Could not inspect persistent groups")
	var persistent_groups := packed.get_state().get_node_groups(0)
	for g in node.get_groups():
		if not str(g).begins_with("_"):
			previous[str(g)] = str(g) in persistent_groups
	var next := {}
	for g in groups:
		if str(g).is_empty() or str(g).begins_with("_"):
			return _err("Group names must be non-empty and must not start with '_' (reserved by Godot)")
		next[str(g)] = true
	var undo := editor_plugin.get_undo_redo()
	undo.create_action("MCP Set Node Groups", UndoRedo.MERGE_DISABLE, _edited_root())
	undo.add_do_method(self, "_apply_groups", node, next)
	undo.add_undo_method(self, "_apply_groups", node, previous)
	undo.commit_action()
	return _ok({"groups": groups})


func _find_nodes_in_group(params: Dictionary) -> Dictionary:
	var group: String = params.get("group", "")
	var results: Array = []
	NodeUtils.collect_in_group(_edited_root(), group, results)
	return _ok({"group": group, "nodes": results})


func _scene_node(path: String) -> Node:
	var root := _edited_root()
	var node := _resolve_node(path)
	return node if root != null and node != null and (root == node or root.is_ancestor_of(node)) else null


func _restore_owners(owners: Array) -> void:
	SceneSafety.restore_owners(owners)


func _apply_groups(node: Node, groups: Dictionary) -> void:
	for group in node.get_groups():
		if not str(group).begins_with("_"):
			node.remove_from_group(group)
	for group in groups:
		node.add_to_group(group, groups[group])
