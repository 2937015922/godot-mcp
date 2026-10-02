extends SceneTree

const Safety = preload("res://addons/godot_mcp/utils/scene_safety.gd")
var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
		push_error(label)


func _run() -> void:
	for path in ["node_commands", "scene_commands", "batch_commands"]:
		var script = load("res://addons/godot_mcp/commands/%s.gd" % path)
		_check(script != null and script.can_instantiate(), "%s compiles" % path)
	_check(Safety.node_type_error("Node3D").is_empty(), "Node3D accepted")
	_check(not Safety.node_type_error("StandardMaterial3D").is_empty(), "non-Node rejected")
	_check(not Safety.node_type_error("MissingClass").is_empty(), "unknown class rejected")
	var scene := Node3D.new()
	scene.name = "Scene"
	root.add_child(scene)
	var parent := Node3D.new()
	parent.name = "Parent"
	scene.add_child(parent)
	parent.owner = scene
	var child := MeshInstance3D.new()
	child.name = "Child"
	parent.add_child(child)
	child.owner = scene
	child.mesh = BoxMesh.new()
	var internal := Node3D.new()
	internal.name = "Internal"
	child.add_child(internal)
	internal.owner = parent
	_check(Safety.property_error(parent, "position", Vector3.ONE).is_empty(), "Vector3 property accepted")
	_check(not Safety.property_error(parent, "position", "oops").is_empty(), "wrong property type rejected")
	_check(not Safety.property_error(parent, "nonexistent", 1).is_empty(), "unknown property rejected")
	_check(not Safety.property_error(parent, "owner", scene).is_empty(), "ownership cannot be changed as generic property")
	var owners := Safety.capture_owners(parent)
	scene.remove_child(parent)
	_check(parent.owner == null and child.owner == null, "detaching subtree clears outer ownership")
	scene.add_child(parent)
	Safety.restore_owners(owners)
	_check(parent.owner == scene and child.owner == scene and internal.owner == parent, "restore full subtree ownership")
	var packed := PackedScene.new()
	_check(packed.pack(scene) == OK, "restored subtree packs")
	var loaded := packed.instantiate()
	_check(loaded.has_node("Parent/Child"), "saved subtree still contains child")
	loaded.free()
	var duplicate := parent.duplicate()
	var duplicate_owners := Safety.duplicate_owners(parent, duplicate, scene)
	scene.add_child(duplicate)
	Safety.restore_owners(duplicate_owners)
	_check(duplicate.owner == scene and duplicate.get_node("Child").owner == scene, "duplicate scene-owned descendants preserved")
	_check(duplicate.get_node("Child/Internal").owner == duplicate, "duplicate internal owners remapped")
	child.add_to_group("persistent", true)
	child.add_to_group("temporary", false)
	var group_scene := PackedScene.new()
	var group_snapshot := child.duplicate(Node.DUPLICATE_GROUPS)
	_check(group_scene.pack(group_snapshot) == OK, "group persistence snapshot packs")
	group_snapshot.free()
	var groups := group_scene.get_state().get_node_groups(0)
	_check("persistent" in groups and "temporary" not in groups, "PackedScene distinguishes persistent and transient groups")
	scene.free()
	print(JSON.stringify({"suite": "scene_safety", "checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)
