@tool
extends "res://addons/godot_mcp/commands/base_commands.gd"

const SceneSafety = preload("res://addons/godot_mcp/utils/scene_safety.gd")

func get_commands() -> Dictionary:
	return {
		"find_nodes_by_type": _find_nodes_by_type,
		"find_signal_connections": _find_signal_connections,
		"batch_set_property": _batch_set_property,
		"find_node_references": _find_node_references,
		"get_scene_dependencies": _get_scene_dependencies,
		"cross_scene_set_property": _cross_scene_set_property,
		"find_script_references": _find_script_references,
		"detect_circular_dependencies": _detect_circular_dependencies,
		"batch_add_nodes": _batch_add_nodes,
	}


func _find_nodes_by_type(p: Dictionary) -> Dictionary:
	var type_name: String = p.get("type", "Node")
	var results: Array = []
	NodeUtils.collect_by_type(_edited_root(), type_name, results)
	return _ok({"type": type_name, "nodes": results})


func _find_signal_connections(_p: Dictionary) -> Dictionary:
	var root := _edited_root()
	if root == null:
		return _err("No scene open")
	var connections: Array = []
	_collect_signals(root, connections)
	return _ok({"connections": connections})


func _collect_signals(node: Node, out: Array) -> void:
	for sig in node.get_signal_list():
		for conn in node.get_signal_connection_list(sig.name):
			out.append({
				"from": str(node.get_path()),
				"signal": sig.name,
				"to": str(conn.callable.get_object()),
				"method": conn.callable.get_method(),
			})
	for child in node.get_children():
		_collect_signals(child, out)


func _batch_set_property(p: Dictionary) -> Dictionary:
	var type_name: String = p.get("type", "")
	var property: String = p.get("property", "")
	var value = _parse_value(str(p.get("value", "")))
	var results: Array = []
	var root := _edited_root()
	if root == null:
		return _err("No scene open")
	NodeUtils.collect_by_type(root, type_name, results, 2147483647)
	var nodes: Array[Node] = []
	for item in results:
		var node := _resolve_node(item["path"])
		if node == null:
			return _err("Node disappeared during validation")
		var error := SceneSafety.property_error(node, property, value)
		if not error.is_empty():
			return _err(error, -32000, {"node_path": item.path})
		nodes.append(node)
	if nodes.is_empty():
		return _ok({"updated": 0})
	var undo := editor_plugin.get_undo_redo()
	undo.create_action("MCP Batch Set Property", UndoRedo.MERGE_DISABLE, root)
	for node in nodes:
		undo.add_do_property(node, property, value)
		undo.add_undo_property(node, property, node.get(property))
	undo.commit_action()
	return _ok({"updated": nodes.size()})


func _find_node_references(p: Dictionary) -> Dictionary:
	var pattern: String = p.get("pattern", "")
	var matches: Array = []
	_search_in_dir("res://", pattern, matches)
	return _ok({"matches": matches})


func _search_in_dir(path: String, pattern: String, matches: Array) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.begins_with("."):
			f = dir.get_next()
			continue
		var full := path.path_join(f)
		if dir.current_is_dir():
			_search_in_dir(full, pattern, matches)
		elif f.ends_with(".tscn") or f.ends_with(".gd"):
			var content := FileAccess.get_file_as_string(full)
			if content.contains(pattern):
				matches.append(full)
		f = dir.get_next()
	dir.list_dir_end()


func _get_scene_dependencies(p: Dictionary) -> Dictionary:
	var scene_path := _norm_res(p.get("scene_path", ""))
	if scene_path.is_empty() and _edited_root():
		scene_path = _edited_root().scene_file_path
	var deps: Array = []
	if ResourceLoader.exists(scene_path):
		var state := ResourceLoader.load(scene_path)
		if state is PackedScene:
			for ext in ResourceLoader.get_dependencies(scene_path):
				deps.append(ext)
	return _ok({"scene": scene_path, "dependencies": deps})


func _cross_scene_set_property(p: Dictionary) -> Dictionary:
	var directory := _norm_res(p.get("directory", "res://"))
	var property: String = p.get("property", "")
	var value: Variant = _parse_value(str(p.get("value", "")))
	var type_name: String = p.get("type", "")
	if property.is_empty() or type_name.is_empty():
		return _err("Missing property or type")
	var updated: Array = []
	var dir := DirAccess.open(directory)
	if dir == null:
		return _err("Invalid directory")
	var paths: Array[String] = []
	for file in dir.get_files():
		if file.ends_with(".tscn"):
			paths.append(directory.path_join(file).simplify_path())
	paths.sort()
	# Refuse before loading or changing anything. An open tab can contain edits
	# absent from disk, including tabs that are not currently selected.
	var open_paths := editor_plugin.get_editor_interface().get_open_scenes()
	for path in paths:
		for open_path in open_paths:
			if path.to_lower() == str(open_path).simplify_path().to_lower():
				return _err("Cross-scene update includes an open scene; close it or use live batch_set_property", -32000, {"scene_path": path, "updated_scenes": []})
	var pending: Array = []
	for path in paths:
		var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		if packed == null:
			return _err("Failed to load scene: %s" % path)
		# Preserve nested scene ownership and inherited scene metadata on repack.
		var inst := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		if inst == null:
			return _err("Failed to instantiate scene: %s" % path)
		var matches: Array[Node] = []
		_collect_matching(inst, type_name, matches)
		for node in matches:
			var error := SceneSafety.property_error(node, property, value)
			if not error.is_empty():
				inst.free()
				return _err(error, -32000, {"scene_path": path, "updated_scenes": []})
		for node in matches:
			node.set(property, value)
		if not matches.is_empty():
			var output := PackedScene.new()
			var error := output.pack(inst)
			if error != OK:
				inst.free()
				return _err("Failed to pack scene: %s (%d)" % [path, error])
			pending.append({"path": path, "scene": output})
		inst.free()
	# All files have passed validation before the first save. Report any partial
	# save failure honestly instead of claiming a successful full batch.
	for entry in pending:
		var error := ResourceSaver.save(entry.scene, entry.path)
		if error != OK:
			return _err("Failed to save scene: %s (%d)" % [entry.path, error], -32000, {"updated_scenes": updated})
		updated.append(entry.path)
	if not updated.is_empty():
		editor_plugin.get_editor_interface().get_resource_filesystem().scan()
	return _ok({"updated_scenes": updated})


func _collect_matching(node: Node, type_name: String, matches: Array[Node]) -> void:
	if node.get_class() == type_name or node.is_class(type_name):
		matches.append(node)
	for child in node.get_children():
		_collect_matching(child, type_name, matches)


func _find_script_references(p: Dictionary) -> Dictionary:
	var script_path := _norm_res(p.get("script_path", ""))
	var matches: Array = []
	_search_in_dir("res://", script_path, matches)
	return _ok({"script": script_path, "references": matches})


func _detect_circular_dependencies(p: Dictionary) -> Dictionary:
	var scene_path := _norm_res(p.get("scene_path", ""))
	var visited := {}
	var stack := {}
	var cycles: Array = []
	_detect_cycle(scene_path, visited, stack, cycles, [])
	return _ok({"cycles": cycles})


func _batch_add_nodes(p: Dictionary) -> Dictionary:
	var nodes_data: Array = p.get("nodes", [])
	if nodes_data.is_empty():
		return _err("Missing non-empty 'nodes' array")
	var root := _edited_root()
	if root == null:
		return _err("No scene open")
	var created: Array = []
	var staged: Array = []
	var staged_by_path := {}
	for i in nodes_data.size():
		if not nodes_data[i] is Dictionary:
			_free_staged(staged)
			return _err("Node entry must be an object", -32000, {"index": i})
		var entry: Dictionary = nodes_data[i]
		var node_type: String = entry.get("type", "")
		var error := SceneSafety.node_type_error(node_type)
		if not error.is_empty():
			_free_staged(staged)
			return _err(error, -32000, {"index": i})
		var requested_parent: String = entry.get("parent_path", ".")
		var parent := _resolve_node(requested_parent)
		var parent_key := requested_parent.trim_prefix(str(root.get_path()) + "/").trim_prefix("./")
		if parent == null:
			parent = staged_by_path.get(parent_key)
		if parent == null or (parent != root and not root.is_ancestor_of(parent) and not staged_by_path.values().has(parent)):
			_free_staged(staged)
			return _err("Parent must belong to the edited scene or an earlier batch entry", -32000, {"index": i})
		var node: Node = ClassDB.instantiate(node_type)
		node.name = str(entry.get("name", node_type))
		if parent == root:
			parent_key = ""
		elif root.is_ancestor_of(parent):
			parent_key = str(root.get_path_to(parent))
		var key := parent_key.path_join(str(node.name)) if not parent_key.is_empty() else str(node.name)
		if staged_by_path.has(key) or root.has_node(NodePath(key)):
			node.free()
			_free_staged(staged)
			return _err("Duplicate node path in batch: %s" % key, -32000, {"index": i})
		var properties: Variant = entry.get("properties", {})
		if not properties is Dictionary:
			node.free()
			_free_staged(staged)
			return _err("Properties must be an object", -32000, {"index": i})
		var parsed := {}
		for property in properties:
			var value: Variant = _parse_value(str(properties[property]))
			error = SceneSafety.property_error(node, str(property), value)
			if property == "name":
				error = "Set the entry name field instead of properties.name"
			if not error.is_empty():
				node.free()
				_free_staged(staged)
				return _err(error, -32000, {"index": i})
			parsed[property] = value
		staged.append({"node": node, "parent": parent, "properties": parsed, "type": node_type})
		staged_by_path[key] = node
	var undo := editor_plugin.get_undo_redo()
	undo.create_action("MCP Batch Add Nodes", UndoRedo.MERGE_DISABLE, root)
	for entry in staged:
		undo.add_do_method(entry.parent, "add_child", entry.node, true)
		undo.add_do_method(entry.node, "set_owner", root)
		for property in entry.properties:
			undo.add_do_property(entry.node, property, entry.properties[property])
		undo.add_do_reference(entry.node)
	# Children must detach before their parents when undoing dependent entries.
	for i in range(staged.size() - 1, -1, -1):
		undo.add_undo_method(staged[i].parent, "remove_child", staged[i].node)
	undo.commit_action()
	for i in staged.size():
		created.append({"index": i, "path": str(staged[i].node.get_path()), "type": staged[i].type})
	return _ok({"created": created, "count": created.size(), "errors": []})


func _free_staged(staged: Array) -> void:
	for entry in staged:
		entry.node.free()


func _detect_cycle(path: String, visited: Dictionary, stack: Dictionary, cycles: Array, chain: Array) -> void:
	if path.is_empty() or not ResourceLoader.exists(path):
		return
	if stack.has(path):
		cycles.append(chain + [path])
		return
	if visited.has(path):
		return
	visited[path] = true
	stack[path] = true
	var next_chain := chain + [path]
	for dep in ResourceLoader.get_dependencies(path):
		if dep.ends_with(".tscn"):
			_detect_cycle(dep, visited, stack, cycles, next_chain)
	stack.erase(path)
