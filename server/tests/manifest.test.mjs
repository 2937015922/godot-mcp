import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { z } from "zod";
import { TOOL_DEFINITIONS } from "../build/tool-manifest.js";
import { registerTools } from "../build/tools.js";
import { GodotRpcError } from "../build/godot-bridge.js";

function registeredTools(bridge) {
  const tools = new Map();
  registerTools({ tool(name, description, schema, handler) {
    assert.ok(!tools.has(name), `Duplicate MCP tool ${name}`);
    tools.set(name, { description, schema: z.object(schema), handler });
  } }, bridge);
  return tools;
}

test("manifest and routed Godot command modules expose matching methods without duplicates", async () => {
  const router = await readFile(new URL("../../addons/godot_mcp/command_router.gd", import.meta.url), "utf8");
  const paths = [...router.matchAll(/"res:\/\/([^"\n]+\/commands\/[^"\n]+\.gd)"/g)].map(match => match[1]);
  assert.ok(paths.length > 0, "Router must contain command modules");
  const commands = new Set();
  for (const modulePath of paths) {
    const source = await readFile(new URL("../../" + modulePath, import.meta.url), "utf8");
    const block = source.match(/func get_commands\(\) -> Dictionary:\s*return \{([\s\S]*?)\n\s*\}/);
    assert.ok(block, `${modulePath} must expose its command dictionary`);
    for (const match of block[1].matchAll(/"([^"]+)"\s*:\s*[_a-zA-Z][\w]*/g)) {
      assert.ok(!commands.has(match[1]), `Duplicate routed command ${match[1]}`);
      commands.add(match[1]);
    }
  }
  assert.equal(new Set(TOOL_DEFINITIONS.map(tool => tool.name)).size, TOOL_DEFINITIONS.length);
  assert.deepEqual([...new Set(TOOL_DEFINITIONS.map(tool => tool.method))].sort(), [...commands].sort());
});

test("new public schemas require identity parameters and expose bounded spatial options", () => {
  const tools = registeredTools({});
  const diff = tools.get("scene_diff").schema;
  assert.equal(diff.safeParse({}).success, false);
  assert.equal(diff.safeParse({ snapshot_id: "snapshot-1" }).success, true);
  const relationship = tools.get("get_spatial_relationship").schema;
  assert.equal(relationship.safeParse({ first_path: "A" }).success, false);
  assert.equal(relationship.safeParse({ first_path: "A", second_path: "B" }).success, true);
  const spatial = tools.get("get_scene_spatial_info").schema;
  assert.equal(spatial.safeParse({ node_path: ".", max_nodes: 10, max_depth: 2, include_multimesh_instances: true, max_instances: 8 }).success, true);
  assert.equal(spatial.safeParse({ include_multimesh_instances: "yes" }).success, false);
  assert.equal(tools.get("set_editor_selection").schema.safeParse({}).success, false);
});

test("guarded edits preserve the snapshot token when forwarding to the bridge", async () => {
  const calls = [];
  const tools = registeredTools({ async call(method, params) { calls.push({ method, params }); return { saved: true }; } });
  const save = tools.get("save_scene");
  const args = save.schema.parse({ expected_scene_snapshot: "snapshot-7" });
  const result = await save.handler(args);
  assert.deepEqual(calls, [{ method: "save_scene", params: { expected_scene_snapshot: "snapshot-7" } }]);
  assert.deepEqual(JSON.parse(result.content[0].text), { saved: true });
  assert.equal(result.isError, false);
});

test("MCP tool errors retain Godot conflict code and details", async () => {
  const tools = registeredTools({ async call() { throw new GodotRpcError("Stale snapshot", -32020, { changed: ["Wall"] }); } });
  const result = await tools.get("update_property").handler({ node_path: "Wall", property: "position", value: "Vector3(1, 0, 0)" });
  assert.equal(result.isError, true);
  assert.deepEqual(JSON.parse(result.content[0].text), { error: "Stale snapshot", code: -32020, data: { changed: ["Wall"] } });
});

test("bridge status is available without sending a command to an editor", async () => {
  const tools = registeredTools({ status() { return { connected: false, project: null }; }, async call() { throw new Error("Must not forward"); } });
  const result = await tools.get("get_bridge_status").handler({});
  assert.deepEqual(JSON.parse(result.content[0].text), { connected: false, project: null });
});
