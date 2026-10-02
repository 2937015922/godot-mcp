extends SceneTree

var failures: Array[String] = []


class TestActivity extends "res://addons/godot_mcp/services/editor_activity.gd":
	var test_root: Node

	func _current_root() -> Node:
		return test_root


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
		push_error(label)


func _run() -> void:
	var tracker: Node = TestActivity.new()
	var scene: Node3D = Node3D.new()
	scene.name = "TestScene"
	root.add_child(scene)
	tracker.test_root = scene
	var mesh: MeshInstance3D = MeshInstance3D.new()
	mesh.name = "EditableMesh"
	mesh.mesh = BoxMesh.new()
	mesh.material_override = StandardMaterial3D.new()
	scene.add_child(mesh)
	mesh.owner = scene

	var baseline: Dictionary = tracker.create_snapshot(scene, scene, 12, 100)
	var baseline_id: String = baseline["snapshot_id"]
	var unchanged: Dictionary = tracker.compare_snapshot(baseline_id, scene)
	_check(unchanged["changed"].is_empty(), "unchanged snapshots are stable")
	_check(unchanged["complete"], "plain 3D primitives have complete property capture")
	_check(tracker.validate_snapshot(baseline_id).get("valid", false), "complete unchanged whole-scene baseline can guard edits")
	var subtree: Dictionary = tracker.create_snapshot(mesh, scene, 12, 100)
	_check(tracker.validate_snapshot(subtree["snapshot_id"]).has("error"), "subtree snapshots cannot guard unrelated scene edits")
	mesh.position.x = 0.00000001
	_check(tracker.compare_snapshot(baseline_id, scene)["changed"].size() == 1, "numeric transforms preserve sub-string-rounding changes")
	_check(tracker.validate_snapshot(baseline_id).has("error"), "edit guards refuse even small unobserved changes")
	mesh.position = Vector3(4.0, 2.0, -1.0)
	mesh.material_override.albedo_color = Color.RED
	var first: Dictionary = tracker.compare_snapshot(baseline_id, scene)
	_check(first["changed"].size() == 1, "transform/material edits identify exactly the edited node")
	if first["changed"].size() == 1:
		var properties: Dictionary = first["changed"][0]["changes"]["properties"]
		_check(properties["before"]["transform"] != properties["after"]["transform"], "snapshot records transform edits")
		_check(properties["before"]["material_override"] != properties["after"]["material_override"], "snapshot records resource edits")
	_check(tracker.compare_snapshot(baseline_id, scene)["changed"] == first["changed"], "reading diff preserves the baseline")

	var other: Node3D = Node3D.new()
	root.add_child(other)
	_check(tracker.compare_snapshot(baseline_id, other).has("error"), "reject snapshots from another scene")
	_check(tracker.compare_snapshot("missing", scene).has("error"), "reject expired/unknown snapshot IDs")

	var cut: Dictionary = tracker.create_snapshot(scene, scene, 12, 2)
	var early: Node3D = Node3D.new()
	early.name = "InsertedBeforeMesh"
	scene.add_child(early)
	scene.move_child(early, 0)
	var cut_diff: Dictionary = tracker.compare_snapshot(cut["snapshot_id"], scene)
	_check(cut_diff["removed"].is_empty(), "a node pushed out of traversal budget is not reported removed")
	_check("EditableMesh" in cut_diff["uncompared_paths"], "out-of-window nodes are explicitly uncompared")
	mesh.free()
	var deletion: Dictionary = tracker.compare_snapshot(cut["snapshot_id"], scene)
	_check("EditableMesh" in deletion["removed"], "actual absence is still detected with a truncated window")

	var incomplete: Dictionary = tracker.create_snapshot(scene, scene, 0, 100)
	_check(tracker.validate_snapshot(incomplete["snapshot_id"]).has("error"), "truncated baselines cannot authorize guarded mutations")
	var later: Node3D = Node3D.new()
	later.name = "NewChild"
	scene.add_child(later)
	var incomplete_diff: Dictionary = tracker.compare_snapshot(incomplete["snapshot_id"], scene)
	_check(not incomplete_diff["complete"], "depth limits produce an explicit incomplete diff")
	for index: int in range(9):
		tracker.create_snapshot(scene, scene, 12, 100)
	_check(tracker.compare_snapshot(baseline_id, scene).has("error"), "old snapshot IDs expire at capacity")

	tracker.begin_mcp("test")
	tracker.record_event("history_changed", {})
	tracker.end_mcp()
	var activity: Dictionary = tracker.read_activity(0, 100)
	_check(activity["events"][0]["source"] == "mcp", "command events identify explicit MCP execution")
	_check(activity["events"][1]["source"] == "mcp_window", "observed history changes do not claim an exact actor")
	var first_command: int = tracker.begin_mcp("first_async")
	var second_command: int = tracker.begin_mcp("second_async")
	tracker.end_mcp(first_command)
	tracker.record_event("while_second", {})
	tracker.end_mcp(second_command)
	var concurrent: Dictionary = tracker.read_activity(activity["next_cursor"], 100)
	_check(concurrent["events"][2]["command"] == "first_async", "overlapping async commands finish their own token")
	_check(concurrent["events"][3]["command"] == "second_async", "remaining async observation keeps correct command")
	var quiet_cursor: int = tracker.read_activity(0, 100)["latest_cursor"]
	var poll_command: int = tracker.begin_mcp("get_editor_activity")
	tracker.end_mcp(poll_command)
	_check(tracker.read_activity(quiet_cursor, 100)["events"].is_empty(), "activity polling does not manufacture activity")
	for index: int in range(520):
		tracker.record_event("test", {"index": index})
	var page: Dictionary = tracker.read_activity(0, 10)
	_check(page["gap"] and page["events"].size() == 10 and page["has_more"], "bounded activity reports gaps and pagination")
	var following: Dictionary = tracker.read_activity(page["next_cursor"], 10)
	_check(following["events"][0]["cursor"] == page["next_cursor"] + 1, "activity cursor pages without duplicates")
	_check(tracker.read_activity(999999, 10).has("error"), "reject activity cursor outside session")

	tracker.free()
	scene.free()
	other.free()
	if failures.is_empty():
		print("COLLABORATION_TESTS_OK")
	else:
		print("COLLABORATION_TEST_FAILURES: ", failures)
	quit(0 if failures.is_empty() else 1)
