@tool
extends Node

var editor_plugin: EditorPlugin
var _handlers: Dictionary = {}

const COMMAND_MODULES := [
	"res://addons/godot_mcp/commands/collaboration_commands.gd",
	"res://addons/godot_mcp/commands/spatial_commands.gd",
	"res://addons/godot_mcp/commands/project_commands.gd",
	"res://addons/godot_mcp/commands/scene_commands.gd",
	"res://addons/godot_mcp/commands/node_commands.gd",
	"res://addons/godot_mcp/commands/script_commands.gd",
	"res://addons/godot_mcp/commands/editor_commands.gd",
	"res://addons/godot_mcp/commands/input_commands.gd",
	"res://addons/godot_mcp/commands/runtime_commands.gd",
	"res://addons/godot_mcp/commands/animation_commands.gd",
	"res://addons/godot_mcp/commands/tilemap_commands.gd",
	"res://addons/godot_mcp/commands/theme_commands.gd",
	"res://addons/godot_mcp/commands/profiling_commands.gd",
	"res://addons/godot_mcp/commands/batch_commands.gd",
	"res://addons/godot_mcp/commands/shader_commands.gd",
	"res://addons/godot_mcp/commands/export_commands.gd",
	"res://addons/godot_mcp/commands/resource_commands.gd",
	"res://addons/godot_mcp/commands/physics_commands.gd",
	"res://addons/godot_mcp/commands/scene_3d_commands.gd",
	"res://addons/godot_mcp/commands/particle_commands.gd",
	"res://addons/godot_mcp/commands/navigation_commands.gd",
	"res://addons/godot_mcp/commands/audio_commands.gd",
	"res://addons/godot_mcp/commands/animation_tree_commands.gd",
	"res://addons/godot_mcp/commands/analysis_commands.gd",
	"res://addons/godot_mcp/commands/test_commands.gd",
	"res://addons/godot_mcp/commands/android_commands.gd",
]

func _ready() -> void:
	_register_commands()

func _register_commands() -> void:
	for script_path in COMMAND_MODULES:
		var cmd: Node = load(script_path).new()
		cmd.editor_plugin = editor_plugin
		add_child(cmd)
		for method_name: String in cmd.get_commands():
			_handlers[method_name] = cmd.get_commands()[method_name]
	print("[Godot MCP] Registered %d commands" % _handlers.size())

func execute(method: String, params: Dictionary) -> Dictionary:
	if not _handlers.has(method):
		return {
			"error": {
				"code": -32601,
				"message": "Method not found: %s" % method,
			},
		}
	var activity: Node = editor_plugin.get("editor_activity")
	if activity and params.has("expected_scene_snapshot"):
		var validation: Dictionary = activity.validate_snapshot(str(params["expected_scene_snapshot"]))
		if validation.has("error"):
			return {"error": {"code": -32020, "message": str(validation["error"])}}
	var activity_token: int = -1
	if activity:
		activity_token = activity.begin_mcp(method)
	var response: Dictionary = await _handlers[method].call(params)
	if is_instance_valid(activity):
		activity.end_mcp(activity_token)
	return response

func get_available_methods() -> Array:
	return _handlers.keys()
