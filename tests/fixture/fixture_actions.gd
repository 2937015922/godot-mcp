@tool
extends Node3D
## Test-only deferred editor actions, intentionally outside the MCP call window.

func schedule_editor_move(path: String, target: Vector3) -> bool:
	get_tree().create_timer(0.2).timeout.connect(_external_move.bind(path, target))
	return true

func _external_move(path: String, target: Vector3) -> void:
	var tracker: Node = get_tree().root.find_child("MCPEditorActivity", true, false)
	var plugin: EditorPlugin = tracker.get("_plugin")
	var manager: EditorUndoRedoManager = plugin.get_undo_redo()
	var node: Node3D = get_node(path)
	manager.create_action("Fixture external editor move", UndoRedo.MERGE_DISABLE, self)
	manager.add_do_property(node, "position", target)
	manager.add_undo_property(node, "position", node.position)
	manager.commit_action()

func tree_details(path: String) -> Dictionary:
	var node: Node = get_node(path)
	var data: Dictionary = {"index": node.get_index(), "owner": str(node.owner.name) if node.owner else "", "children": []}
	for child: Node in node.find_children("*", "", true, false):
		data.children.append({"path": str(node.get_path_to(child)), "owner": str(child.owner.name) if child.owner else ""})
	return data

func disk_property(path: String, node_path: String, property: String) -> Variant:
	var packed: PackedScene = ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	var instance: Node = packed.instantiate()
	var value: Variant = instance.get_node(node_path).get(property)
	instance.free()
	return value


func simulate_global_action(value: int = -1) -> Dictionary:
	# A plain RefCounted is outside all scenes and belongs to GLOBAL_HISTORY.
	# Retain it on the editor service, keeping fixture data out of scene snapshots.
	# Passing a nonnegative value commits an action; no argument only reads it.
	var tracker: Node = get_tree().root.find_child("MCPEditorActivity", true, false)
	var plugin: EditorPlugin = tracker.get("_plugin")
	var manager: EditorUndoRedoManager = plugin.get_undo_redo()
	var target: RefCounted = tracker.get_meta("fixture_global_target") as RefCounted if tracker.has_meta("fixture_global_target") else null
	if target == null:
		target = RefCounted.new()
		target.set_meta("value", 0)
		tracker.set_meta("fixture_global_target", target)
	var history_id: int = manager.get_object_history_id(target)
	if history_id != EditorUndoRedoManager.GLOBAL_HISTORY:
		return {"error": "Fixture target was not assigned to GLOBAL_HISTORY", "history_id": history_id}
	if value >= 0:
		manager.create_action("Fixture global action", UndoRedo.MERGE_DISABLE, target)
		manager.add_do_method(target, "set_meta", "value", value)
		manager.add_undo_method(target, "set_meta", "value", int(target.get_meta("value")))
		manager.commit_action()
	return {"history_id": history_id, "value": int(target.get_meta("value"))}
