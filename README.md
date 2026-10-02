# Godot MCP — collaboration fork 0.2.0

**Language:** **English** | [简体中文](README.zh.md)

Open-source Godot MCP server that lets AI assistants (Claude Code, Cursor, Codex, and more) control the Godot 4 editor directly through the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/).

This [fork](https://github.com/2937015922/godot-mcp) extends [mkdevkit/godot-mcp](https://github.com/mkdevkit/godot-mcp) with editor activity, scene snapshots and diffs, guarded edits, and 3D spatial inspection. It preserves the original 173 tools and adds 10 tools for **183 total**. The focus is sharing an editable Godot scene between a person and an AI assistant.

```
AI client  ←—stdio/MCP—→  Node.js server  ←—WebSocket:6505—→  Godot editor plugin
```

## Overview

| Component | Role |
|-----------|------|
| **Godot plugin** | WebSocket client that receives JSON-RPC requests and executes commands via editor APIs |
| **Node.js MCP server** | Speaks stdio to AI clients; runs a WebSocket server (default port 6505) to forward tool calls |
| **Command router** | `command_router.gd` aggregates 26 command modules with **182** handlers; the server also supplies `get_bridge_status` |
| **Editor collaboration** | A session-local activity journal, eight retained scene baselines, selection, undo/redo, and optional snapshot checks before edits |
| **Runtime services** | 3 autoloads (`MCPRuntimeBridge` / `MCPInputBridge` / `MCPScreenshotBridge`) use `user://` IPC for in-game inspection, input simulation, and screenshots |

### Core features

- **Live scene editing** — node operations work on the currently edited tree, including unsaved changes; supported node and batch operations use the editor undo stack
- **Scene handoff** — inspect selection and recent activity, compare a saved baseline, and reject supported edits when the inspected scene has changed
- **3D inspection** — world transforms, authored bounds, and spatial relationships, with explicit traversal limits and unavailable data
- **Native screenshots** — editor and game screenshots return PNG image content to MCP clients, with separate size/path metadata
- **Project handshake** — the server verifies the connected plugin's project identity; `GODOT_MCP_PROJECT` can pin it to one project
- **Smart type parsing** — strings like `Vector2(100, 200)`, `#ff0000`, `Color(1,0,0)` are converted automatically
- **Reconnect with backoff** — exponential backoff on the plugin side (1s → 60s)
- **Heartbeat** — bidirectional ping/pong to keep the WebSocket alive
- **JSON-RPC 2.0** — standard protocol between the Godot plugin and the Node.js server

## Tool categories

**183 MCP tools** across **27 categories**:

| Category | Tools | Highlights |
|----------|-------|------------|
| Collaboration | 7 | Editor activity/selection, scene snapshots/diffs, undo/redo |
| Spatial inspection | 2 | Authored world bounds, transforms, distances and AABB overlap |
| Bridge | 1 | Connection status and editor project identity |
| Project | 7 | Project info, file search, UID conversion, project settings |
| Scene | 10 | Scene tree, create/delete/instance scenes, play/stop, `@export` variables |
| Node | 14 | CRUD, properties, signals, groups, resource attachment |
| Script | 8 | Script CRUD, attach, validation, full-text search |
| Editor | 13 | Editor/game screenshots, camera control, error log, screenshot diff, auto-dismiss dialogs |
| Input | 7 | Keyboard/mouse/action simulation, input map (incl. deadzone) |
| Runtime | 19 | In-game scene tree, properties, signal watching, record/replay, UI clicks, navigation |
| Animation | 6 | Tracks, keyframes, AnimationPlayer CRUD |
| TileMap | 6 | Cell read/write, rect fill, used-cell queries |
| Theme/UI | 7 | Theme creation, Control layout, color/font/StyleBox overrides |
| Profiling | 2 | FPS, memory, draw calls, physics monitors |
| Batch/Refactor | 9 | Batch add nodes, batch property updates, cross-scene edits, dependency/cycle detection |
| Shader | 6 | Shader CRUD, material assignment, parameter read/write |
| Export | 3 | Export preset list, export command generation |
| Resource | 6 | `.tres` read/write, Autoload register/remove |
| Physics | 6 | Collision bodies, physics layers (incl. layer name resolution), RayCast |
| 3D Scene | 6 | Mesh instances, camera, lights, environment, GridMap |
| Particle | 5 | GPU particles, materials, gradients, presets (fire/smoke/spark) |
| Navigation | 6 | Nav regions/agents, mesh baking, pathfinding |
| Audio | 6 | Audio players, buses, effects |
| AnimationTree | 8 | State machines, transitions, blend trees, parameters |
| Analysis | 4 | Scene complexity, signal flow, unused resources, project stats |
| Testing/QA | 5 | Test scenarios, assertions, stress tests |
| Android | 4 | adb device list, APK export/deploy, preset details |

<details>
<summary>Expand to see all 183 tool names</summary>

**Collaboration:** `get_editor_activity` · `get_editor_selection` · `set_editor_selection` · `scene_snapshot` · `scene_diff` · `undo_last` · `redo_last`

**Spatial inspection:** `get_scene_spatial_info` · `get_spatial_relationship`

**Bridge:** `get_bridge_status`

**Project:** `get_project_info` · `get_filesystem_tree` · `search_files` · `get_project_settings` · `set_project_setting` · `uid_to_project_path` · `project_path_to_uid`

**Scene:** `get_scene_tree` · `get_scene_file_content` · `create_scene` · `open_scene` · `delete_scene` · `add_scene_instance` · `play_scene` · `stop_scene` · `save_scene` · `get_scene_exports`

**Node:** `add_node` · `delete_node` · `duplicate_node` · `move_node` · `update_property` · `get_node_properties` · `add_resource` · `set_anchor_preset` · `rename_node` · `connect_signal` · `disconnect_signal` · `get_node_groups` · `set_node_groups` · `find_nodes_in_group`

**Script:** `list_scripts` · `read_script` · `create_script` · `edit_script` · `attach_script` · `get_open_scripts` · `validate_script` · `search_in_files`

**Editor:** `get_editor_errors` · `get_editor_screenshot` · `get_game_screenshot` · `execute_editor_script` · `clear_output` · `get_signals` · `reload_plugin` · `reload_project` · `get_output_log` · `get_editor_camera` · `set_editor_camera` · `set_auto_dismiss` · `compare_screenshots`

**Input:** `simulate_key` · `simulate_mouse_click` · `simulate_mouse_move` · `simulate_action` · `simulate_sequence` · `get_input_actions` · `set_input_action`

**Runtime:** `get_game_scene_tree` · `get_game_node_properties` · `set_game_node_property` · `execute_game_script` · `capture_frames` · `monitor_properties` · `start_recording` · `stop_recording` · `replay_recording` · `find_nodes_by_script` · `get_autoload` · `batch_get_properties` · `find_ui_elements` · `click_button_by_text` · `wait_for_node` · `find_nearby_nodes` · `navigate_to` · `move_to` · `watch_signals`

**Animation:** `list_animations` · `create_animation` · `add_animation_track` · `set_animation_keyframe` · `get_animation_info` · `remove_animation`

**TileMap:** `tilemap_set_cell` · `tilemap_fill_rect` · `tilemap_get_cell` · `tilemap_clear` · `tilemap_get_info` · `tilemap_get_used_cells`

**Theme/UI:** `create_theme` · `set_theme_color` · `set_theme_constant` · `set_theme_font_size` · `set_theme_stylebox` · `get_theme_info` · `setup_control`

**Profiling:** `get_performance_monitors` · `get_editor_performance`

**Batch/Refactor:** `find_nodes_by_type` · `find_signal_connections` · `batch_set_property` · `find_node_references` · `get_scene_dependencies` · `cross_scene_set_property` · `find_script_references` · `detect_circular_dependencies` · `batch_add_nodes`

**Shader:** `create_shader` · `read_shader` · `edit_shader` · `assign_shader_material` · `set_shader_param` · `get_shader_params`

**Export:** `list_export_presets` · `export_project` · `get_export_info`

**Resource:** `read_resource` · `edit_resource` · `create_resource` · `get_resource_preview` · `add_autoload` · `remove_autoload`

**Physics:** `setup_physics_body` · `setup_collision` · `set_physics_layers` · `get_physics_layers` · `get_collision_info` · `add_raycast`

**3D Scene:** `add_mesh_instance` · `setup_camera_3d` · `setup_lighting` · `setup_environment` · `add_gridmap` · `set_material_3d`

**Particle:** `create_particles` · `set_particle_material` · `set_particle_color_gradient` · `apply_particle_preset` · `get_particle_info`

**Navigation:** `setup_navigation_region` · `setup_navigation_agent` · `bake_navigation_mesh` · `set_navigation_layers` · `get_navigation_info` · `get_navigation_path`

**Audio:** `add_audio_player` · `add_audio_bus` · `add_audio_bus_effect` · `set_audio_bus` · `get_audio_bus_layout` · `get_audio_info`

**AnimationTree:** `create_animation_tree` · `get_animation_tree_structure` · `set_tree_parameter` · `add_state_machine_state` · `remove_state_machine_state` · `add_state_machine_transition` · `remove_state_machine_transition` · `set_blend_tree_node`

**Analysis:** `analyze_scene_complexity` · `analyze_signal_flow` · `find_unused_resources` · `get_project_statistics`

**Testing/QA:** `run_test_scenario` · `assert_node_state` · `assert_screen_text` · `run_stress_test` · `get_test_report`

**Android:** `list_android_devices` · `deploy_to_android` · `get_android_build_info` · `get_android_preset_info`

</details>

## Working together in the editor

1. Call `get_bridge_status` to check the project, then `get_editor_selection` and `get_editor_activity` to see the editing context.
2. Capture a `scene_snapshot` of the scene or a focused subtree. Keep its `snapshot_id` while a person adjusts the scene in Godot.
3. Call `scene_diff` with that ID to inspect changes. Reading a diff does not replace the baseline. Node paths identify entries, so moves and renames appear as removals and additions.
4. Take a fresh whole-scene snapshot (`root_path: "."`) before an AI edit and pass its ID as `expected_scene_snapshot` on a supported operation. Save deliberately with `save_scene`; the normal node tools modify the live tree without automatically saving it.

The optional guard is available on `add_node`, `delete_node`, `duplicate_node`, `move_node`, `rename_node`, `update_property`, `add_resource`, `connect_signal`, `disconnect_signal`, `set_node_groups`, `batch_add_nodes`, `batch_set_property`, `add_scene_instance`, and `save_scene`. It requires a complete **whole-scene snapshot**. Changed captured content, a changed editor history version, or an expired, reloaded, incomplete, or subtree baseline rejects the edit. Subtree snapshots are only for scoped comparison with `scene_diff`. This is a check before the operation, not a lock on the editor or protection for every tool. Create a new baseline after each change.

The activity journal holds the latest **512 events** and reports cursor gaps. `source: editor` means an observation outside an MCP command; `mcp_window` means an observation while a command was active and can include simultaneous human edits. Only explicit command events use `mcp`. These labels do not prove who made a scene change. The journal and its **eight snapshots** are local to the editor session and are cleared when the plugin shuts down.

Snapshots have node, depth, property, collection, and byte limits. They capture stored node properties, resource summaries, group names, and persistent signal connections, including targets, methods, flags, and bound arguments. Script source, external file bytes, transient signal connections, and group persistence flags are outside this comparison. A snapshot is not a complete scene backup. Check `truncated`, `property_capture_complete`, and the diff's `complete`/`uncompared_paths` fields; completeness describes this captured scope. Incomplete snapshots cannot authorize guarded edits.

`undo_last` and `redo_last` act on the current scene's latest history action, which may be a human edit; pass the observed `expected_version` to reject a changed history. They preserve Godot's history-manager bookkeeping. Godot 4.7.2 does not expose its scoped manager operations to GDScript, so this version uses a checked adapter to the native History dock. If the required dock layout or callbacks are unavailable, the operation returns an error instead of manipulating the underlying UndoRedo directly. Other Godot versions require compatibility verification; the response's `backend` identifies the route used.

## 3D inspection

`get_scene_spatial_info` reports the edited scene's transforms, visibility flags, authored geometry/collision-shape bounds, and optional MultiMesh instance transforms. `get_spatial_relationship` compares two bounded subtree scans. Check `bounds_complete` and the reported unavailable/truncated fields before drawing conclusions.

Bounds include hidden geometry and disabled collision shapes. AABB overlap does not prove a physics contact, camera visibility, or a playable route. Native graphical Godot can supply individual MultiMesh transforms; Godot's headless renderer supplies dummy MultiMesh transforms, so per-instance inspection explicitly reports unavailable there. These tools inspect the authored editor scene; use the existing runtime tools for a running game.

`get_editor_screenshot` and `get_game_screenshot` return a native MCP `image/png` content block plus text metadata; image bytes are no longer embedded in the JSON text response. They require a graphical editor/game session, and the game screenshot requires a running game. Empty image results report an error. The native integration run retrieves both images, saves them under `tests/results/`, and validates their PNG headers.

## Project structure

```
godot-mcp/
├── addons/godot_mcp/              # Godot editor plugin (copy into your project)
│   ├── plugin.gd                  # Plugin entry; injects autoloads
│   ├── plugin.cfg
│   ├── websocket_client.gd        # WebSocket client + JSON-RPC dispatch
│   ├── command_router.gd          # Command router; registers all handlers
│   ├── commands/                  # 26 command modules (182 tool implementations)
│   │   ├── base_commands.gd       # Base class: Undo, runtime IPC, screenshots, etc.
│   │   ├── collaboration_commands.gd
│   │   ├── spatial_commands.gd
│   │   ├── project_commands.gd
│   │   ├── scene_commands.gd
│   │   ├── node_commands.gd
│   │   ├── script_commands.gd
│   │   ├── editor_commands.gd
│   │   ├── input_commands.gd
│   │   ├── runtime_commands.gd
│   │   ├── animation_commands.gd
│   │   ├── tilemap_commands.gd
│   │   ├── theme_commands.gd
│   │   ├── profiling_commands.gd
│   │   ├── batch_commands.gd
│   │   ├── shader_commands.gd
│   │   ├── export_commands.gd
│   │   ├── resource_commands.gd
│   │   ├── physics_commands.gd
│   │   ├── scene_3d_commands.gd
│   │   ├── particle_commands.gd
│   │   ├── navigation_commands.gd
│   │   ├── audio_commands.gd
│   │   ├── animation_tree_commands.gd
│   │   ├── analysis_commands.gd
│   │   ├── test_commands.gd
│   │   └── android_commands.gd
│   ├── services/                  # Editor observations and runtime autoload services
│   │   ├── editor_activity.gd     # Journal, scene snapshots/diffs, history guards
│   │   ├── mcp_runtime_bridge.gd  # In-game scene tree / properties / script execution
│   │   ├── mcp_input_bridge.gd    # Input event queue
│   │   └── mcp_screenshot_bridge.gd
│   └── utils/
│       ├── type_parser.gd         # Vector2 / Color type parsing
│       ├── node_utils.gd
│       ├── scene_safety.gd        # Property validation and subtree ownership
│       └── resource_utils.gd
├── server/                        # Node.js MCP server
│   ├── src/
│   │   ├── index.ts               # MCP stdio entry
│   │   ├── godot-bridge.ts        # WebSocket server + JSON-RPC
│   │   ├── tools.ts               # Tool registration
│   │   └── tool-manifest.ts       # 182 definitions; tools.ts adds bridge status
│   └── build/index.js             # Build output (MCP entry point)
├── scripts/install-local.ps1      # Windows local installation helper
├── tests/                         # Native Godot checks and editor fixture
├── .mcp.json.example              # Sample MCP client config
├── README.md                      # English docs (default)
└── README.zh.md                   # Chinese docs
```

## Requirements

- **Godot** 4.7.2 is the current development target; earlier Godot 4 releases need compatibility verification
- **Node.js** 18+
- Any MCP-capable client: Claude Code, Cursor, Codex CLI, Cline, Windsurf, etc.

## Usage

### Windows local installer

From this checkout, use PowerShell with your project directory and chosen port:

```powershell
.\scripts\install-local.ps1 -ProjectPath "D:\Games\MyGame" -Port 6505
```

Add `-GodotPath "C:\Tools\Godot\Godot.exe"` when supplying a local engine executable. Add `-ConfigureCodex` to opt into configuring the local Codex MCP entry. The manual steps below describe the same plugin/server components and apply to other clients.

### 1. Install the Godot plugin

Copy `addons/godot_mcp/` into your Godot project's `addons/` directory:

```bash
cp -r addons/godot_mcp /path/to/your-game/addons/
```

Enable it in Godot: **Project → Project Settings → Plugins → Godot MCP → Enable**

> Enabling the plugin injects 3 autoloads (`MCPRuntimeBridge`, etc.); they are removed when the plugin is disabled.

### 2. Build the MCP server

```bash
cd server
npm install
npm run build
```

The entry point after build is `server/build/index.js`.

### 3. Configure your AI client

Add the following to your MCP config file (**replace paths with your actual paths**):

| Client | Config location |
|--------|-----------------|
| Claude Code | `.mcp.json` in the project root |
| Cursor | Settings → MCP, or `~/.cursor/mcp.json` |
| Codex CLI | MCP section in `~/.codex/config.toml` |
| Cline / Roo Code | MCP settings in the extension |

```json
{
  "mcpServers": {
    "godot-mcp": {
      "command": "node",
      "args": ["D:/godot-mcp/server/build/index.js"],
      "env": {
        "GODOT_MCP_PORT": "6505",
        "GODOT_MCP_PROJECT": "D:/Games/MyGame"
      }
    }
  }
}
```

See also [`.mcp.json.example`](.mcp.json.example) in the repo.

`GODOT_MCP_PROJECT` is the absolute **project directory**, not the `project.godot` file. Use the matching 0.2.0 plugin and server: the server waits for the plugin handshake before forwarding commands and rejects a different pinned project or a second editor attempting to take over an active connection. Without the project setting, status still shows the connected project's identity but does not pin it.

The plugin and server must use the same port. The plugin reads `GODOT_MCP_PORT` from its launch environment first, then the project's `godot_mcp/network/port` setting, then defaults to 6505. The installer sets the project port; manual installations can set it in Project Settings or launch Godot with the environment variable. Setting an environment variable only in the MCP client does not change an already running editor's environment. Keep separate projects on separate ports.

### 4. Get started

1. **First**, open your project in Godot (with the plugin enabled)
2. Start your AI client and confirm the `godot-mcp` MCP server is connected
3. Ask the AI to operate the editor, for example:
   - "Get the current scene tree"
   - "Add a CharacterBody2D named Player under the root"
   - "Create a GDScript and attach it to Player"
   - "Play the current scene, then capture a game screenshot"
   - "Fill a grass area on the TileMap"

### 5. Tests

Run these from the repository root in PowerShell:

```powershell
npm --prefix server test
$env:GODOT_BIN = "C:\Tools\Godot\Godot.exe"
node server/tests/editor-integration.mjs
```

The integration harness creates an isolated project in `.local/editor-fixture` and uses port 6517 by default (`GODOT_TEST_PORT` overrides it). Its 21 checks exercise the actual MCP/server/editor path, scene differences and guards, ownership, undo/redo, persistence, open-scene protection, and starting/stopping a game. Use a graphical session to also retrieve editor/game screenshots:

```powershell
$env:GODOT_TEST_NATIVE = "1"
node server/tests/editor-integration.mjs
Remove-Item Env:GODOT_TEST_NATIVE
```

After the integration harness has prepared its fixture, the standalone Godot checks can reuse its installed addon:

```powershell
$repoPath = (Get-Location).Path
foreach ($testName in @("test_collaboration", "test_scene_safety", "test_spatial")) {
    & $env:GODOT_BIN --headless --path "$repoPath/.local/editor-fixture" --script "$repoPath/tests/$testName.gd"
}
```

The native development target is Godot 4.7.2. Headless and graphical checks cover different renderer behavior, particularly MultiMesh instances. These tests cover the listed workflows; they are not exhaustive validation of all 183 tools or human playtesting of a game. The integration result and local logs are written to `tests/results/editor-integration.json`.

## How it works

1. The AI client calls an MCP tool (e.g. `add_node`) over **stdio**
2. The Node.js server converts the request to **JSON-RPC** and sends it over **WebSocket** to the Godot plugin
3. The plugin's `command_router` dispatches to the matching handler, which calls **EditorInterface** and related APIs
4. The result travels back to the AI client along the same path

**Runtime tools** (e.g. `get_game_scene_tree`) additionally require:

- The editor to be in **Play** mode
- The `MCPRuntimeBridge` autoload polling `user://mcp_runtime_req.json` in the game process and writing responses

## Adding a tool

To add a new MCP tool:

1. Create or edit a command class under `addons/godot_mcp/commands/` and register the handler in `get_commands()`
2. Add the script path to the `COMMAND_MODULES` array in `command_router.gd`
3. Add the tool name, description, and parameter schema to `TOOL_DEFINITIONS` in `server/src/tool-manifest.ts`

Then rebuild the server:

```bash
cd server && npm run build
```

## Known limitations

- **Editor camera**: Godot 4.7 returns a `SubViewport`; camera tools use its actual `Camera3D`. `set_editor_camera` changes the live preview transform, but does not synchronize Godot's private orbit-navigation cursor. Subsequent mouse navigation can replace the preview; focus the selected node with F for normal human navigation.
- **Android tools**: `list_android_devices` runs `adb devices`; `deploy_to_android` uses headless Godot export and adb install (requires an Android export preset and adb on PATH)
- **Runtime tools**: call `play_scene` first; the game process must load the `MCPRuntimeBridge` autoload; `watch_signals` listens for signal emissions on specified nodes while the game is running
- **Cross-scene batch edits** (`cross_scene_set_property`): prevalidate and save closed `.tscn` files directly in the requested directory. If any target scene is open, the whole request is rejected before writing; use live scene edits or close the scene first. These disk writes have no editor undo. If a later save fails, earlier successful saves remain and are listed in the error's `updated_scenes`.
- **Scope**: the additional collaboration tools do not convert runtime-generated levels into editable `.tscn` files, merge competing edits automatically, or guarantee undo/guards for every inherited tool. Scene conversion and regeneration policies remain project work.
- **Compatibility**: editor APIs can differ across Godot minor versions. This fork has no DAP debugger, GDScript LSP integration, or general runtime pause/step feature imported from other bridges.

## Credits

The codebase and original tools come from [mkdevkit/godot-mcp](https://github.com/mkdevkit/godot-mcp), under MIT. Collaboration and spatial-inspection work was informed conceptually by [TomasLucasUTN/godot-mcp-bridge](https://github.com/TomasLucasUTN/godot-mcp-bridge), [satelliteoflove/godot-mcp](https://github.com/satelliteoflove/godot-mcp), and [NPGameDev/godot-mcp-toolkit](https://github.com/NPGameDev/godot-mcp-toolkit). No source code from those three projects was copied into this release; this fork does not incorporate their full feature sets. See [CHANGELOG.md](CHANGELOG.md) for this fork's changes.

## License

MIT
