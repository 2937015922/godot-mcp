# Changelog

## 0.2.0 — 2026-10-01

First collaboration release of the [2937015922/godot-mcp fork](https://github.com/2937015922/godot-mcp), based on [mkdevkit/godot-mcp](https://github.com/mkdevkit/godot-mcp). The original 173 tools remain available. Nine new Godot handlers and one server-only status tool bring the total to **183 MCP tools**.

### Added

- Editor activity and selection: `get_editor_activity`, `get_editor_selection`, and `set_editor_selection`. The journal retains 512 events, supports cursors, and reports gaps. `editor` and `mcp_window` describe observation context, not confirmed actor identity; explicit command events are marked `mcp`.
- `scene_snapshot` and `scene_diff`, retaining at most eight session-local baselines. Captures include bounded node properties, resource summaries, group names, and persistent signal connections with targets/methods/flags/bound arguments. Diffs report incomplete coverage instead of treating unobserved nodes as deletions; reading a diff preserves its baseline.
- Optional `expected_scene_snapshot` on selected node, batch, instance, and save tools, accepting only a complete whole-scene baseline. Changed captured content, changed scene history version, or an expired, reloaded, incomplete, or subtree baseline rejects the operation. Subtree snapshots remain available for scoped diffs only; the guard does not lock the editor.
- `undo_last` and `redo_last`, with optional `expected_version` checks. These use the current scene history, including actions made by a person, through the editor manager or a checked native History-dock adapter.
- `get_scene_spatial_info` and `get_spatial_relationship`: bounded authored-scene transforms, visibility flags, world AABBs, distances, and overlap. Optional MultiMesh expansion has a request-wide instance budget. Headless per-instance MultiMesh transforms are explicitly unavailable.
- `get_bridge_status`, project-identity handshake, optional `GODOT_MCP_PROJECT` pinning, and rejection of a second editor taking over an active bridge connection.
- Editor/game screenshots now return native MCP PNG image content with separate text metadata; empty captures are errors. Graphical integration checks retrieve both image types and validate their PNG headers.
- Plugin port selection supports the launch environment first, then the project's `godot_mcp/network/port`, then the default 6505.
- Windows local installer, automated server tests, native Godot checks, and an editor integration harness. See the READMEs for entry points; test commands are not a claim that every inherited tool has been validated.

### Fixed

- Node deletion/duplication/reparenting preserve subtree ownership through undo/redo. Structural operations register object references and restore sibling order; reparenting preserves world position and restores original local transforms on undo. Invalid root/cyclic operations and moves across instance ownership boundaries are rejected.
- Batch node creation and property edits validate before making changes and use one editor undo action. A batch can reference parents created earlier in the same request.
- Signal connections and groups are persistent and undoable. Resource assignment and anchor presets use undo; anchor restoration includes offsets.
- Scene saves check their result. Open scenes cannot be overwritten by scene creation or deleted through the scene-file tool.
- Undo/redo preserves the editor manager's separate action stacks and saved-state bookkeeping. The Godot 4.7.2 adapter invokes the native History dock rather than calling the underlying UndoRedo directly; unsupported dock layouts/callbacks are refused.
- `cross_scene_set_property` now actually packs and saves closed scene files. It rejects a request containing any open target scene before the first write and reports successfully saved paths if a later save fails.
- English and Chinese tool counts now match the manifest, including the inherited Runtime category's 19 tools.

### Scope and compatibility

- Godot 4.7.2 is the current development target. Other Godot 4 versions require compatibility checks. Both the plugin and server need this fork's 0.2.0 handshake.
- Cross-scene disk saves have no editor undo and are not an all-or-nothing filesystem transaction. A later I/O failure can leave earlier saves in place.
- Snapshots summarize bounded data; script source, external file bytes, transient signals, and group persistence flags are outside their comparison scope. They are not scene backups or a conflict-merging system. Scene conversion from runtime generation remains a separate project task. Existing tools outside the documented guarded set do not gain automatic snapshot protection.
- Scoped undo/redo on Godot 4.7.2 depends on the verified native History-dock adapter because manager operations are not bound to GDScript. It fails closed if the required controls/callbacks are unavailable; other engine versions need compatibility verification.
- Spatial bounds include hidden geometry and disabled collision shapes. AABB overlap is not a physics-contact test, occlusion result, or navigation validation. Rendering-dependent checks require native graphical Godot.
- Conceptual inspiration: [TomasLucasUTN/godot-mcp-bridge](https://github.com/TomasLucasUTN/godot-mcp-bridge), [satelliteoflove/godot-mcp](https://github.com/satelliteoflove/godot-mcp), and [NPGameDev/godot-mcp-toolkit](https://github.com/NPGameDev/godot-mcp-toolkit). No source code from these three projects was copied. Their DAP, LSP, debugger, and other full feature sets are not part of this release.

## 0.1.0 — upstream base

Original MIT-licensed Godot MCP editor integration and 173-tool manifest from mkdevkit. Upstream history is preserved in Git.
