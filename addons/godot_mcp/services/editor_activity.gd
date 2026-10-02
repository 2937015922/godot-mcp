@tool
extends Node
## Session-local editor observations and bounded, explicit scene baselines.
## Sources describe observation windows; only command events identify MCP.

const MAX_EVENTS: int = 512
const MAX_SNAPSHOTS: int = 8
const MAX_PROPERTIES: int = 128
const MAX_ITEMS: int = 32
const MAX_CAPTURE_BYTES: int = 2 * 1024 * 1024
const MAX_VALUES_PER_NODE: int = 8192

var _plugin: EditorPlugin
var _events: Array[Dictionary] = []
var _cursor: int = 0
var _commands: Array[Dictionary] = []
var _command_counter: int = 0
var _connections: Array[Dictionary] = []
var _snapshots: Dictionary = {}
var _snapshot_order: Array[String] = []
var _snapshot_counter: int = 0
var _session: String = str(Time.get_ticks_usec())
var _remaining_values: int = MAX_VALUES_PER_NODE


func setup(plugin: EditorPlugin) -> void:
	shutdown()
	_plugin = plugin
	_connect_signal(plugin, "scene_changed", _on_scene_changed)
	_connect_signal(plugin, "scene_saved", _on_scene_saved)
	_connect_signal(plugin, "scene_closed", _on_scene_closed)
	_connect_signal(plugin.get_editor_interface().get_selection(), "selection_changed", _on_selection_changed)
	_connect_signal(plugin.get_undo_redo(), "history_changed", _on_history_changed)
	_connect_signal(plugin.get_undo_redo(), "version_changed", _on_version_changed)
	record_event("tracking_started", {})


func shutdown() -> void:
	for item: Dictionary in _connections:
		var source: Object = item["object"]
		var callback: Callable = item["callback"]
		var signal_name: String = item["signal"]
		if is_instance_valid(source) and source.is_connected(signal_name, callback):
			source.disconnect(signal_name, callback)
	_connections.clear()
	_snapshots.clear()
	_snapshot_order.clear()
	_commands.clear()
	_plugin = null


func _connect_signal(source: Object, signal_name: String, callback: Callable) -> void:
	if source.has_signal(signal_name) and not source.is_connected(signal_name, callback):
		source.connect(signal_name, callback)
		_connections.append({"object": source, "signal": signal_name, "callback": callback})


func begin_mcp(command: String) -> int:
	_command_counter += 1
	_commands.append({"command": command, "token": _command_counter})
	if command != "get_editor_activity":
		record_event("command_started", {"command": command, "token": _command_counter})
	return _command_counter


func end_mcp(token: int = -1) -> void:
	for index: int in range(_commands.size() - 1, -1, -1):
		var command: Dictionary = _commands[index]
		if token == -1 or int(command["token"]) == token:
			if str(command["command"]) != "get_editor_activity":
				record_event("command_finished", command)
			_commands.remove_at(index)
			return


func record_event(kind: String, details: Dictionary) -> void:
	_cursor += 1
	var event: Dictionary = {
		"cursor": _cursor,
		"time_unix": Time.get_unix_time_from_system(),
		"kind": kind,
		"source": "mcp_window" if not _commands.is_empty() else "editor",
		"scene_path": _current_scene_path(),
		"details": details.duplicate(true),
	}
	if not _commands.is_empty():
		event["active_commands"] = _commands.duplicate(true)
		if _commands.size() == 1:
			event["command"] = _commands[0]["command"]
	if kind in ["command_started", "command_finished", "selection_requested", "history_operation"] and not _commands.is_empty():
		event["source"] = "mcp"
		if details.has("command"):
			event["command"] = details["command"]
	_events.append(event)
	if _events.size() > MAX_EVENTS:
		_events.pop_front()


func read_activity(cursor: int = 0, limit: int = 100) -> Dictionary:
	if cursor < 0 or cursor > _cursor:
		return {"error": "Cursor is outside this editor session; read again with cursor 0"}
	var earliest: int = int(_events[0]["cursor"]) if not _events.is_empty() else _cursor + 1
	var items: Array[Dictionary] = []
	var next_cursor: int = cursor
	for event: Dictionary in _events:
		if int(event["cursor"]) > cursor:
			items.append(event.duplicate(true))
			next_cursor = int(event["cursor"])
			if items.size() >= clampi(limit, 1, MAX_EVENTS):
				break
	return {
		"session_id": _session, "events": items, "next_cursor": next_cursor,
		"latest_cursor": _cursor, "earliest_cursor": earliest,
		"has_more": next_cursor < _cursor,
		"gap": cursor < earliest - 1,
		"capacity": MAX_EVENTS,
		"source_note": "editor and mcp_window describe observation context, not actor identity. mcp_window may include concurrent human edits; only explicit command events use mcp.",
	}


func selection_state() -> Dictionary:
	var items: Array[Dictionary] = []
	var root: Node = _current_root()
	if is_instance_valid(_plugin):
		for node: Node in _plugin.get_editor_interface().get_selection().get_selected_nodes():
			if is_instance_valid(node):
				items.append({
					"path": str(root.get_path_to(node)) if root != null and (root == node or root.is_ancestor_of(node)) else str(node.get_path()),
					"name": str(node.name), "type": node.get_class(),
				})
	return {"scene_path": _current_scene_path(), "nodes": items, "history": history_state()}


func history_state() -> Dictionary:
	var root: Node = _current_root()
	if root == null:
		return {}
	var manager: EditorUndoRedoManager = _plugin.get_undo_redo()
	var history_id: int = manager.get_object_history_id(root)
	if history_id <= 0:
		return {"history_id": history_id, "available": false}
	var history: UndoRedo = manager.get_history_undo_redo(history_id)
	if history == null:
		return {"history_id": history_id, "available": false}
	return {
		"history_id": history_id, "available": true,
		"version": history.get_version(), "can_undo": history.has_undo(), "can_redo": history.has_redo(),
		"current_action": history.get_current_action_name() if history.get_current_action() >= 0 else "",
	}


func change_history(redo: bool, expected_version: int = -1) -> Dictionary:
	var root: Node = _current_root()
	if root == null:
		return {"error": "No scene is open"}
	var manager: EditorUndoRedoManager = _plugin.get_undo_redo()
	if manager.is_committing_action():
		return {"error": "An editor action is still being committed"}
	var history_id: int = manager.get_object_history_id(root)
	if history_id <= 0:
		return {"error": "The current scene has no editable scene history"}
	var history: UndoRedo = manager.get_history_undo_redo(history_id)
	if history == null:
		return {"error": "The current scene has no undo history"}
	if expected_version >= 0 and expected_version != history.get_version():
		return {"error": "Scene history changed since expected_version; inspect editor activity before retrying"}
	if (redo and not history.has_redo()) or (not redo and not history.has_undo()):
		return {"error": "Nothing to redo in this scene" if redo else "Nothing to undo in this scene"}
	var index: int = history.get_current_action() + (1 if redo else 0)
	var action_name: String = history.get_action_name(index)
	var operation: Dictionary = _apply_editor_history(manager, history, history_id, redo)
	if operation.has("error"):
		return operation
	var result: Dictionary = {"operation": "redo" if redo else "undo", "action": action_name, "history": history_state(), "backend": operation["backend"]}
	record_event("history_operation", result)
	return result


func _apply_editor_history(manager: EditorUndoRedoManager, history: UndoRedo, history_id: int, redo: bool) -> Dictionary:
	# The manager owns additional action stacks and saved-version bookkeeping.
	# Calling history.undo()/redo() directly corrupts those stacks after a save.
	var method: String = "redo_history" if redo else "undo_history"
	if manager.has_method(method):
		if bool(manager.call(method, history_id)):
			return {"backend": "editor_history_manager"}
		return {"error": "The editor history manager did not apply the operation"}
	# Godot 4.7.2 does not bind the manager's scoped undo/redo to GDScript.
	# Its native HistoryDock invokes those exact methods when Scene is enabled
	# and Global disabled. Do not route through global menu shortcuts: those
	# can select a newer global/remote action instead of this scene's history.
	var controls: Dictionary = _history_dock_controls()
	if controls.has("error"):
		return controls
	var scene_filter: CheckBox = controls["scene"]
	var global_filter: CheckBox = controls["global"]
	var actions: ItemList = controls["actions"]
	var previous_scene_filter: bool = scene_filter.button_pressed
	var previous_global_filter: bool = global_filter.button_pressed
	var before_action: int = history.get_current_action()
	var expected_action: int = before_action + (1 if redo else -1)
	# The native dock lists newest actions first, followed by "The Beginning".
	var target_index: int = history.get_history_count() - 1 - expected_action
	scene_filter.set_pressed_no_signal(true)
	global_filter.set_pressed_no_signal(false)
	_refresh_history_dock(scene_filter)
	if actions.item_count != history.get_history_count() + 1 or target_index < 0 or target_index >= actions.item_count:
		_restore_history_dock_filters(scene_filter, global_filter, previous_scene_filter, previous_global_filter)
		return {"error": "Native HistoryDock layout does not match the current scene history; operation refused"}
	# Hidden docks normally postpone refreshing their version. Native seek_history
	# loops until its version reaches the selected index; refresh it synchronously
	# on every manager version signal, even while the dock is hidden.
	var refresh: Callable = _refresh_history_dock.bind(scene_filter)
	manager.version_changed.connect(refresh)
	actions.select(target_index)
	actions.item_selected.emit(target_index)
	manager.version_changed.disconnect(refresh)
	_restore_history_dock_filters(scene_filter, global_filter, previous_scene_filter, previous_global_filter)
	if history.get_current_action() != expected_action:
		return {"error": "Native HistoryDock did not reach the expected scene history version"}
	return {"backend": "native_history_dock"}


func _history_dock_controls() -> Dictionary:
	var base: Control = _plugin.get_editor_interface().get_base_control()
	var docks: Array[Node] = base.find_children("*", "HistoryDock", true, false)
	if docks.size() != 1:
		return {"error": "This editor does not expose the supported native HistoryDock; scoped undo/redo is unavailable"}
	var dock: Node = docks[0]
	var filters: Array[Node] = dock.find_children("*", "CheckBox", true, false)
	var lists: Array[Node] = dock.find_children("*", "ItemList", true, false)
	if filters.size() != 2 or lists.size() != 1:
		return {"error": "Unsupported native HistoryDock control layout; scoped undo/redo is unavailable"}
	# Godot constructs the Scene and Global filters in this order. Verify they
	# still connect to native dock callbacks before relying on that layout.
	for filter: Node in filters:
		if not _has_native_dock_callback(filter, "toggled", dock):
			return {"error": "Unsupported native HistoryDock filter callbacks; operation refused"}
	if not _has_native_dock_callback(lists[0], "item_selected", dock):
		return {"error": "Unsupported native HistoryDock selection callback; operation refused"}
	return {"scene": filters[0], "global": filters[1], "actions": lists[0]}


func _has_native_dock_callback(source: Node, signal_name: String, dock: Node) -> bool:
	for connection: Dictionary in source.get_signal_connection_list(signal_name):
		var callback: Callable = connection["callable"]
		if callback.is_valid() and callback.is_custom() and callback.get_object() == dock:
			return true
	return false


func _refresh_history_dock(scene_filter: CheckBox) -> void:
	scene_filter.toggled.emit(scene_filter.button_pressed)


func _restore_history_dock_filters(scene_filter: CheckBox, global_filter: CheckBox, scene_enabled: bool, global_enabled: bool) -> void:
	scene_filter.set_pressed_no_signal(scene_enabled)
	global_filter.set_pressed_no_signal(global_enabled)
	_refresh_history_dock(scene_filter)


func create_snapshot(scope: Node, scene_root: Node, max_depth: int = 12, max_nodes: int = 2000) -> Dictionary:
	if scope == null or scene_root == null or (scope != scene_root and not scene_root.is_ancestor_of(scope)):
		return {"error": "Snapshot root must belong to the currently edited scene"}
	_snapshot_counter += 1
	var snapshot_id: String = "%s:%d" % [_session, _snapshot_counter]
	var snapshot: Dictionary = capture(scope, clampi(max_depth, 0, 64), clampi(max_nodes, 1, 5000))
	snapshot["snapshot_id"] = snapshot_id
	snapshot["scene_path"] = scene_root.scene_file_path
	snapshot["scene_instance_id"] = scene_root.get_instance_id()
	snapshot["root_instance_id"] = scope.get_instance_id()
	snapshot["root_path"] = str(scene_root.get_path_to(scope))
	snapshot["activity_cursor"] = _cursor
	if is_instance_valid(_plugin):
		snapshot["history_version"] = history_state().get("version", -1)
	_snapshots[snapshot_id] = snapshot
	_snapshot_order.append(snapshot_id)
	if _snapshot_order.size() > MAX_SNAPSHOTS:
		_snapshots.erase(_snapshot_order.pop_front())
	var result: Dictionary = snapshot.duplicate(true)
	result.erase("scene_instance_id")
	result.erase("root_instance_id")
	result["baseline_capacity"] = MAX_SNAPSHOTS
	return result


func compare_snapshot(snapshot_id: String, scene_root: Node) -> Dictionary:
	if not _snapshots.has(snapshot_id):
		return {"error": "Unknown or expired snapshot_id; create a fresh scene_snapshot"}
	var before: Dictionary = _snapshots[snapshot_id]
	if scene_root == null or scene_root.get_instance_id() != int(before["scene_instance_id"]) or scene_root.scene_file_path != str(before["scene_path"]):
		return {"error": "Snapshot belongs to a different or reloaded scene; create a fresh scene_snapshot"}
	var scope: Node = scene_root.get_node_or_null(NodePath(str(before["root_path"])))
	if scope == null or scope.get_instance_id() != int(before["root_instance_id"]):
		return {"error": "Snapshot root was removed, replaced, or renamed; create a fresh scene_snapshot"}
	var after: Dictionary = capture(scope, int(before["max_depth"]), int(before["max_nodes"]))
	var changes: Dictionary = compare_captures(before, after, scope)
	changes.merge({
		"snapshot_id": snapshot_id, "scene_path": before["scene_path"], "root_path": before["root_path"],
		"baseline_cursor": before["activity_cursor"], "current_cursor": _cursor,
		"baseline_retained": true,
	})
	return changes


func validate_snapshot(snapshot_id: String) -> Dictionary:
	if _snapshots.has(snapshot_id) and str(_snapshots[snapshot_id]["root_path"]) != ".":
		return {"error": "An edit guard requires a whole-scene snapshot (root_path '.'); subtree snapshots are only for scoped comparison"}
	var diff: Dictionary = compare_snapshot(snapshot_id, _current_root())
	if diff.has("error"):
		return diff
	if not bool(diff["complete"]):
		return {"error": "Snapshot contains omitted nodes or properties and cannot guard an edit; capture the whole scene with sufficient limits or inspect and explicitly reissue the edit without a guard"}
	if not diff["added"].is_empty() or not diff["removed"].is_empty() or not diff["changed"].is_empty():
		return {"error": "Scene changed since the expected snapshot; inspect scene_diff and create a fresh baseline before editing"}
	if is_instance_valid(_plugin) and _snapshots[snapshot_id].get("history_version", -1) != history_state().get("version", -1):
		return {"error": "Scene history changed since the expected snapshot; inspect editor activity and capture a fresh baseline"}
	return {"valid": true, "snapshot_id": snapshot_id}


func capture(scope: Node, max_depth: int, max_nodes: int) -> Dictionary:
	var nodes: Dictionary = {}
	var stack: Array[Dictionary] = [{"node": scope, "depth": 0}]
	var truncated: bool = false
	var property_capture_complete: bool = true
	var capture_bytes: int = 0
	while not stack.is_empty():
		if nodes.size() >= max_nodes:
			truncated = true
			break
		var entry: Dictionary = stack.pop_back()
		var node: Node = entry["node"]
		var depth: int = entry["depth"]
		var path: String = str(scope.get_path_to(node))
		var node_data: Dictionary = _capture_node(node)
		var node_bytes: int = JSON.stringify(node_data).to_utf8_buffer().size() + path.length() + 8
		if capture_bytes + node_bytes > MAX_CAPTURE_BYTES:
			truncated = true
			break
		capture_bytes += node_bytes
		nodes[path] = node_data
		if _has_omitted_value(nodes[path]):
			property_capture_complete = false
		var children: Array[Node] = node.get_children()
		if depth >= max_depth:
			if not children.is_empty():
				truncated = true
			continue
		# Godot's child order is part of the scene, and each node records its index.
		for index: int in range(children.size() - 1, -1, -1):
			stack.append({"node": children[index], "depth": depth + 1})
	return {
		"nodes": nodes, "node_count": nodes.size(), "truncated": truncated,
		"property_capture_complete": property_capture_complete,
		"capture_bytes": capture_bytes, "capture_byte_limit": MAX_CAPTURE_BYTES,
		"max_depth": max_depth, "max_nodes": max_nodes,
		"scope": "stored node properties, ownership, group names and persistent signals; group persistence flags, script source and external asset bytes excluded; resources summarized to depth 2, arrays to 32 entries; truncation is reported per property",
	}


func compare_captures(before: Dictionary, after: Dictionary, scope: Node) -> Dictionary:
	var old_nodes: Dictionary = before["nodes"]
	var new_nodes: Dictionary = after["nodes"]
	var added: Array[Dictionary] = []
	var removed: Array[String] = []
	var changed: Array[Dictionary] = []
	var unobserved: Array[String] = []
	for path: String in new_nodes:
		if not old_nodes.has(path):
			if bool(before["truncated"]):
				unobserved.append(path)
			else:
				added.append({"path": path, "node": new_nodes[path]})
			continue
		var fields: Dictionary = {}
		var previous: Dictionary = old_nodes[path]
		var current: Dictionary = new_nodes[path]
		for key: String in current:
			if not previous.has(key) or previous[key] != current[key]:
				fields[key] = {"before": previous.get(key), "after": current[key]}
		for key: String in previous:
			if not current.has(key):
				fields[key] = {"before": previous[key], "after": null}
		if not fields.is_empty():
			changed.append({"path": path, "changes": fields})
	for path: String in old_nodes:
		if not new_nodes.has(path):
			# A traversal budget can hide an existing node. Confirm actual absence
			# before reporting deletion, rather than trusting the truncated window.
			if scope.get_node_or_null(NodePath(path)) == null:
				removed.append(path)
			else:
				unobserved.append(path)
	return {
		"added": added, "removed": removed, "changed": changed,
		"uncompared_paths": unobserved,
		"baseline_truncated": before["truncated"], "current_truncated": after["truncated"],
		"property_capture_complete": bool(before.get("property_capture_complete", false)) and bool(after.get("property_capture_complete", false)),
		"complete": not bool(before["truncated"]) and not bool(after["truncated"]) and bool(before.get("property_capture_complete", false)) and bool(after.get("property_capture_complete", false)),
		"note": "Paths are identities: renames and moves appear as removal/addition. Additions are conservative when the baseline was truncated. Reading a diff never advances its baseline.",
	}


func _capture_node(node: Node) -> Dictionary:
	_remaining_values = MAX_VALUES_PER_NODE
	var properties: Dictionary = {}
	var count: int = 0
	var omitted: int = 0
	for info: Dictionary in node.get_property_list():
		if (int(info["usage"]) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var property: String = str(info["name"])
		if count >= MAX_PROPERTIES:
			omitted += 1
			continue
		properties[property] = _summarize(node.get(property), 0, {})
		count += 1
	var groups: Array[String] = []
	for group: StringName in node.get_groups():
		if not str(group).begins_with("_"):
			groups.append(str(group))
	groups.sort()
	return {
		"type": node.get_class(), "name": str(node.name), "index": node.get_index(),
		"owner_path": str(node.get_path_to(node.owner)) if node.owner != null else "",
		"scene_file_path": node.scene_file_path, "groups": groups,
		"persistent_signals": _capture_connections(node),
		"properties": properties, "omitted_properties": omitted,
	}


func _capture_connections(node: Node) -> Dictionary:
	var connections: Array[Dictionary] = []
	for signal_info: Dictionary in node.get_signal_list():
		for connection: Dictionary in node.get_signal_connection_list(signal_info.name):
			if (int(connection.flags) & Object.CONNECT_PERSIST) == 0:
				continue
			if connections.size() >= 128:
				return {"connections": connections, "truncated": true}
			var callback: Callable = connection.callable
			var target: Object = callback.get_object()
			connections.append({
				"signal": str(signal_info.name), "flags": int(connection.flags),
				"target": str(node.get_path_to(target)) if target is Node else str(callback.get_object_id()),
				"method": str(callback.get_method()),
				"bound_arguments": _summarize(callback.get_bound_arguments(), 0, {}),
				"unbound_arguments": callback.get_unbound_arguments_count(),
			})
	return {"connections": connections, "truncated": false}


func _summarize(value: Variant, depth: int, seen: Dictionary) -> Variant:
	_remaining_values -= 1
	if _remaining_values < 0:
		return {"truncated": true, "reason": "node property value budget"}
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT:
			return value
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return {"type": type_string(typeof(value)), "value": [value.x, value.y]}
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return {"type": type_string(typeof(value)), "value": [value.x, value.y, value.z]}
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_QUATERNION:
			return {"type": type_string(typeof(value)), "value": [value.x, value.y, value.z, value.w]}
		TYPE_COLOR:
			return {"type": "Color", "value": [value.r, value.g, value.b, value.a]}
		TYPE_RECT2, TYPE_RECT2I, TYPE_AABB:
			return {"type": type_string(typeof(value)), "position": _summarize(value.position, depth, seen), "size": _summarize(value.size, depth, seen)}
		TYPE_BASIS:
			return {"type": "Basis", "x": _summarize(value.x, depth, seen), "y": _summarize(value.y, depth, seen), "z": _summarize(value.z, depth, seen)}
		TYPE_TRANSFORM3D:
			return {"type": "Transform3D", "basis": _summarize(value.basis, depth, seen), "origin": _summarize(value.origin, depth, seen)}
		TYPE_TRANSFORM2D:
			return {"type": "Transform2D", "x": _summarize(value.x, depth, seen), "y": _summarize(value.y, depth, seen), "origin": _summarize(value.origin, depth, seen)}
		TYPE_PLANE:
			return {"type": "Plane", "normal": _summarize(value.normal, depth, seen), "d": value.d}
		TYPE_PROJECTION:
			return {"type": "Projection", "x": _summarize(value.x, depth, seen), "y": _summarize(value.y, depth, seen), "z": _summarize(value.z, depth, seen), "w": _summarize(value.w, depth, seen)}
		TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH:
			var string_value: String = str(value)
			if string_value.length() > 2048:
				return {"preview": string_value.substr(0, 2048), "length": string_value.length(), "hash": hash(string_value), "truncated": true}
			return string_value
		TYPE_OBJECT:
			if value == null or not is_instance_valid(value):
				return null
			if value is Node:
				return {"node_path": str(value.get_path()) if value.is_inside_tree() else str(value.name)}
			if value is Resource:
				var resource: Resource = value
				var result: Dictionary = {"type": resource.get_class(), "path": resource.resource_path, "name": resource.resource_name, "local_to_scene": resource.resource_local_to_scene}
				if depth >= 2 or seen.has(resource.get_instance_id()):
					result["truncated"] = true
					return result
				var nested_seen: Dictionary = seen.duplicate()
				nested_seen[resource.get_instance_id()] = true
				var resource_properties: Dictionary = {}
				var omitted: int = 0
				for info: Dictionary in resource.get_property_list():
					if (int(info["usage"]) & PROPERTY_USAGE_STORAGE) == 0:
						continue
					var property: String = str(info["name"])
					if property in ["resource_path", "resource_name", "resource_local_to_scene", "source_code", "script/source"]:
						continue
					if resource_properties.size() >= MAX_PROPERTIES:
						omitted += 1
						continue
					resource_properties[property] = _summarize(resource.get(property), depth + 1, nested_seen)
				result["properties"] = resource_properties
				result["omitted_properties"] = omitted
				return result
			return {"type": value.get_class(), "truncated": true, "reason": "non-resource object properties excluded"}
		TYPE_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
			if depth >= 4:
				return {"size": value.size(), "hash": hash(value), "truncated": true}
			var items: Array = []
			for index: int in range(mini(value.size(), MAX_ITEMS)):
				items.append(_summarize(value[index], depth + 1, seen))
			return {"items": items, "size": value.size(), "hash": hash(value), "truncated": value.size() > MAX_ITEMS}
		TYPE_DICTIONARY:
			if depth >= 4:
				return {"size": value.size(), "hash": hash(value), "truncated": true}
			var entries: Dictionary = {}
			for key: Variant in value:
				if entries.size() >= MAX_ITEMS:
					break
				entries[str(key)] = _summarize(value[key], depth + 1, seen)
			return {"entries": entries, "size": value.size(), "truncated": value.size() > MAX_ITEMS}
		_:
			return str(value)


func _has_omitted_value(value: Variant) -> bool:
	if value is Dictionary:
		if bool(value.get("truncated", false)) or int(value.get("omitted_properties", 0)) > 0:
			return true
		for key: Variant in value:
			if _has_omitted_value(value[key]):
				return true
	elif value is Array:
		for item: Variant in value:
			if _has_omitted_value(item):
				return true
	return false


func _current_root() -> Node:
	return _plugin.get_editor_interface().get_edited_scene_root() if is_instance_valid(_plugin) else null


func _current_scene_path() -> String:
	var root: Node = _current_root()
	return root.scene_file_path if root != null else ""


func _on_scene_changed(root: Node) -> void:
	record_event("scene_changed", {"path": root.scene_file_path if root != null else ""})


func _on_scene_saved(path: String) -> void:
	record_event("scene_saved", {"path": path})


func _on_scene_closed(path: String) -> void:
	for snapshot_id: String in _snapshot_order.duplicate():
		if str(_snapshots[snapshot_id]["scene_path"]) == path:
			_snapshots.erase(snapshot_id)
			_snapshot_order.erase(snapshot_id)
	record_event("scene_closed", {"path": path})


func _on_selection_changed() -> void:
	record_event("selection_changed", selection_state())


func _on_history_changed() -> void:
	record_event("history_changed", {"current_scene_history": history_state(), "scope": "manager signal may concern any open scene or global history"})


func _on_version_changed() -> void:
	record_event("version_changed", {"current_scene_history": history_state(), "scope": "manager signal may concern any open scene or global history"})
