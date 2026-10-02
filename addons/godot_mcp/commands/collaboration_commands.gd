@tool
extends "res://addons/godot_mcp/commands/base_commands.gd"


func get_commands() -> Dictionary:
	return {
		"get_editor_activity": _get_editor_activity,
		"get_editor_selection": _get_editor_selection,
		"set_editor_selection": _set_editor_selection,
		"scene_snapshot": _scene_snapshot,
		"scene_diff": _scene_diff,
		"undo_last": _undo_last,
		"redo_last": _redo_last,
	}


func _activity() -> Node:
	return editor_plugin.get("editor_activity") as Node


func _wrap(value: Dictionary) -> Dictionary:
	if value.has("error"):
		return _err(str(value["error"]))
	return _ok(value)


func _get_editor_activity(params: Dictionary) -> Dictionary:
	return _wrap(_activity().read_activity(int(params.get("cursor", 0)), int(params.get("limit", 100))))


func _get_editor_selection(_params: Dictionary) -> Dictionary:
	return _ok(_activity().selection_state())


func _set_editor_selection(params: Dictionary) -> Dictionary:
	var root: Node = _edited_root()
	if root == null:
		return _err("No scene is open")
	var paths: Variant = params.get("node_paths", [])
	if not paths is Array:
		return _err("node_paths must be an array of paths relative to the scene root")
	var nodes: Array[Node] = []
	for path: Variant in paths:
		if not path is String:
			return _err("Every selection path must be a string")
		var node: Node = _resolve_node(path)
		if node == null or (node != root and not root.is_ancestor_of(node)):
			return _err("Selection node is outside the current scene or does not exist: %s" % str(path))
		nodes.append(node)
	# Resolve the whole request before changing the existing selection.
	var selection: EditorSelection = editor_plugin.get_editor_interface().get_selection()
	if bool(params.get("clear", true)):
		selection.clear()
	for node: Node in nodes:
		selection.add_node(node)
	var result: Dictionary = _activity().selection_state()
	_activity().record_event("selection_requested", result)
	return _ok(result)


func _scene_snapshot(params: Dictionary) -> Dictionary:
	var root: Node = _edited_root()
	var scope: Node = _resolve_node(str(params.get("root_path", ".")))
	return _wrap(_activity().create_snapshot(scope, root, int(params.get("max_depth", 12)), int(params.get("max_nodes", 2000))))


func _scene_diff(params: Dictionary) -> Dictionary:
	return _wrap(_activity().compare_snapshot(str(params.get("snapshot_id", "")), _edited_root()))


func _undo_last(params: Dictionary) -> Dictionary:
	return _wrap(_activity().change_history(false, int(params.get("expected_version", -1))))


func _redo_last(params: Dictionary) -> Dictionary:
	return _wrap(_activity().change_history(true, int(params.get("expected_version", -1))))
