import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { GodotRpcError, type GodotBridge } from "./godot-bridge.js";
import { TOOL_DEFINITIONS, type ToolParamDef } from "./tool-manifest.js";

function textResult(data: unknown, isError = false) {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }],
    isError,
  };
}

function screenshotResult(data: unknown) {
  const result = data as Record<string, unknown> | null;
  if (!result || typeof result.base64 !== "string" || !result.base64 ||
      typeof result.width !== "number" || result.width <= 0 ||
      typeof result.height !== "number" || result.height <= 0) {
    return textResult({ error: "Screenshot capture returned no image. Use a graphical Godot editor/game session." }, true);
  }
  const { base64, ...metadata } = result;
  return {
    content: [
      { type: "image" as const, mimeType: "image/png", data: base64 },
      { type: "text" as const, text: JSON.stringify(metadata, null, 2) },
    ],
    isError: false,
  };
}

function buildSchema(params: ToolParamDef[] = []): Record<string, z.ZodTypeAny> {
  const schema: Record<string, z.ZodTypeAny> = {};
  for (const p of params) {
    let field: z.ZodTypeAny;
    switch (p.type) {
      case "number":
        field = z.number();
        break;
      case "boolean":
        field = z.boolean();
        break;
      case "array":
        field = z.array(z.any());
        break;
      case "record":
        field = z.record(z.string());
        break;
      default:
        field = p.enum ? z.enum(p.enum as [string, ...string[]]) : z.string();
    }
    if (p.description) field = field.describe(p.description);
    if (!p.required) field = field.optional();
    schema[p.name] = field;
  }
  return schema;
}

export function registerTools(server: McpServer, bridge: GodotBridge): void {
  server.tool("get_bridge_status", "Connection status and verified editor project identity; works without an editor", {}, async () => textResult(bridge.status()));
  for (const def of TOOL_DEFINITIONS) {
    const schema = buildSchema(def.params);
    if (GUARDED_EDITS.has(def.name)) {
      schema.expected_scene_snapshot = z.string().optional().describe("Optional complete scene_snapshot ID; rejects this edit if the scene changed since that snapshot. Take a fresh snapshot after each edit.");
    }
    server.tool(def.name, def.description, schema, async (args) => {
      try {
        const result = await bridge.call(def.method, args as Record<string, unknown>);
        return def.name === "get_editor_screenshot" || def.name === "get_game_screenshot"
          ? screenshotResult(result) : textResult(result);
      } catch (e) {
        return textResult({ error: (e as Error).message, ...(e instanceof GodotRpcError ? { code: e.code, data: e.data } : {}) }, true);
      }
    });
  }
  console.error(`[godot-mcp] Registered ${TOOL_DEFINITIONS.length + 1} MCP tools`);
}

const GUARDED_EDITS = new Set(["add_node", "delete_node", "duplicate_node", "move_node", "rename_node", "update_property", "add_resource", "connect_signal", "disconnect_signal", "set_node_groups", "batch_add_nodes", "batch_set_property", "add_scene_instance", "save_scene"]);
