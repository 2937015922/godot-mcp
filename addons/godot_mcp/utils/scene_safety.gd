@tool
extends RefCounted
## Shared validation and owner restoration for editor scene transactions.

static func node_type_error(type_name: String) -> String:
	if not ClassDB.class_exists(type_name) or not ClassDB.is_parent_class(type_name, "Node") or not ClassDB.can_instantiate(type_name):
		return "Expected an instantiable Node type: %s" % type_name
	return ""


static func property_error(object: Object, property: String, value: Variant) -> String:
	if property.is_empty():
		return "Missing property"
	if property in ["owner", "script", "scene_file_path"]:
		return "Use a dedicated scene operation for property: %s" % property
	for info in object.get_property_list():
		if str(info.name) != property:
			continue
		if info.usage & PROPERTY_USAGE_READ_ONLY:
			return "Property is read-only: %s" % property
		var expected: int = info.type
		var actual := typeof(value)
		if expected == TYPE_NIL or expected == actual:
			return ""
		if expected in [TYPE_FLOAT, TYPE_INT] and actual in [TYPE_FLOAT, TYPE_INT]:
			return ""
		if expected in [TYPE_STRING_NAME, TYPE_NODE_PATH] and actual == TYPE_STRING:
			return ""
		if expected == TYPE_OBJECT and value == null:
			return ""
		return "Invalid value type for %s: expected %s, got %s" % [property, type_string(expected), type_string(actual)]
	return "Unknown property: %s" % property


static func capture_owners(node: Node) -> Array:
	var owners: Array = [{"node": node, "owner": node.owner}]
	for child in node.get_children():
		owners.append_array(capture_owners(child))
	return owners


static func restore_owners(owners: Array) -> void:
	for entry in owners:
		var node: Node = entry.node
		var owner: Node = entry.owner
		if is_instance_valid(node):
			if is_instance_valid(owner) and owner.is_ancestor_of(node):
				node.owner = owner
			elif owner == null:
				node.owner = null


static func duplicate_owners(source: Node, duplicate: Node, scene_root: Node) -> Array:
	var owners: Array = []
	for entry in capture_owners(source):
		var source_node: Node = entry.node
		var duplicate_node := duplicate.get_node_or_null(source.get_path_to(source_node))
		var owner: Node = entry.owner
		if owner != null and owner != scene_root and (owner == source or source.is_ancestor_of(owner)):
			owner = duplicate.get_node_or_null(source.get_path_to(owner))
		if duplicate_node != null:
			owners.append({"node": duplicate_node, "owner": owner})
	return owners
