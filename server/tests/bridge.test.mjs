import assert from "node:assert/strict";
import { once } from "node:events";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import WebSocket from "ws";
import { GodotBridge, GodotRpcError } from "../build/godot-bridge.js";

const PROJECT = path.resolve(os.tmpdir(), "godot-mcp-test-project");

async function freePort() {
  const probe = net.createServer();
  probe.listen(0, "127.0.0.1");
  await once(probe, "listening");
  const port = probe.address().port;
  await new Promise((resolve, reject) => probe.close(error => error ? reject(error) : resolve()));
  return port;
}

async function waitFor(predicate, description) {
  const deadline = Date.now() + 2500;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error("Timed out: " + description);
    await delay(5);
  }
}

function nextMessage(socket, predicate = () => true) {
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      clearTimeout(timer);
      socket.off("message", onMessage);
      socket.off("error", onError);
      socket.off("close", onClose);
    };
    const onError = error => { cleanup(); reject(error); };
    const onClose = () => onError(new Error("Socket closed before expected message"));
    const onMessage = raw => {
      const value = JSON.parse(raw.toString());
      if (!predicate(value)) return;
      cleanup();
      resolve(value);
    };
    const timer = setTimeout(() => onError(new Error("Expected WebSocket message was not received")), 2500);
    socket.on("message", onMessage);
    socket.on("error", onError);
    socket.on("close", onClose);
  });
}

async function fixture(t, expectedProject = PROJECT) {
  const bridge = new GodotBridge(await freePort(), expectedProject);
  t.after(() => bridge.close());
  bridge.start();
  return bridge;
}

async function openSocket(t, bridge) {
  const socket = new WebSocket(`ws://127.0.0.1:${bridge.port}`);
  t.after(() => socket.terminate());
  await once(socket, "open", { signal: AbortSignal.timeout(2500) });
  return socket;
}

function hello(socket, projectPath = PROJECT) {
  socket.send(JSON.stringify({ jsonrpc: "2.0", method: "godot_hello", params: {
    project_path: projectPath, project_name: "Bridge test fixture", plugin_version: "0.2.0",
  } }));
}

async function connectedEditor(t, bridge) {
  const socket = await openSocket(t, bridge);
  hello(socket);
  await waitFor(() => bridge.connected, "editor handshake");
  return socket;
}

test("bridge requires handshake and accepts normalized expected project", { timeout: 5000 }, async t => {
  const bridge = await fixture(t);
  const editor = await openSocket(t, bridge);
  assert.equal(bridge.connected, false);
  await assert.rejects(bridge.call("get_scene_tree"), /not connected/);
  const spelling = process.platform === "win32" ? PROJECT.toUpperCase().replaceAll("\\", "/") + "/" : PROJECT + "/";
  hello(editor, spelling);
  await waitFor(() => bridge.connected, "normalized project accepted");
  assert.equal(bridge.status().project.project_name, "Bridge test fixture");
  assert.equal(bridge.status().project.project_path, spelling);
  const inbound = nextMessage(editor);
  const result = bridge.call("get_scene_spatial_info", { node_path: "City", max_nodes: 2 });
  const request = await inbound;
  assert.deepEqual(request.params, { node_path: "City", max_nodes: 2 });
  assert.equal(request.method, "get_scene_spatial_info");
  editor.send(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: { nodes: [], truncated: true } }));
  assert.deepEqual(await result, { nodes: [], truncated: true });
});

test("mismatched project is rejected and a correct editor can subsequently connect", { timeout: 5000 }, async t => {
  const bridge = await fixture(t);
  const wrongEditor = await openSocket(t, bridge);
  const closed = once(wrongEditor, "close");
  hello(wrongEditor, path.join(PROJECT, "another-project"));
  const [code, reason] = await closed;
  assert.equal(code, 4003);
  assert.match(reason.toString(), /Project does not match/);
  assert.equal(bridge.connected, false);
  await waitFor(() => bridge.status().project === null, "mismatch cleanup");
  await connectedEditor(t, bridge);
  assert.equal(bridge.connected, true);
});

test("handshake without a project identity is refused", { timeout: 5000 }, async t => {
  const bridge = await fixture(t);
  const editor = await openSocket(t, bridge);
  const closed = once(editor, "close");
  editor.send(JSON.stringify({ jsonrpc: "2.0", method: "godot_hello", params: {} }));
  assert.equal((await closed)[0], 4003);
  assert.equal(bridge.connected, false);
});

test("second editor cannot hijack the first editor or reject its pending request", { timeout: 5000 }, async t => {
  const bridge = await fixture(t);
  const first = await connectedEditor(t, bridge);
  const inbound = nextMessage(first);
  const pending = bridge.call("scene_snapshot", { max_nodes: 10 });
  const request = await inbound;
  const second = new WebSocket(`ws://127.0.0.1:${bridge.port}`);
  t.after(() => second.terminate());
  const closed = once(second, "close");
  await once(second, "open");
  hello(second);
  const [code] = await closed;
  assert.equal(code, 4009);
  assert.equal(bridge.connected, true);
  first.send(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: { snapshot_id: "kept-first-session" } }));
  assert.deepEqual(await pending, { snapshot_id: "kept-first-session" });
});

test("Godot errors retain message, error code and structured data", { timeout: 5000 }, async t => {
  const bridge = await fixture(t);
  const editor = await connectedEditor(t, bridge);
  const inbound = nextMessage(editor);
  const pending = bridge.call("update_property", { expected_scene_snapshot: "stale" });
  const rejected = assert.rejects(pending, error => {
    assert.ok(error instanceof GodotRpcError);
    assert.equal(error.message, "Scene changed since snapshot");
    assert.equal(error.code, -32020);
    assert.deepEqual(error.data, { paths: ["Door"], observed_version: 8 });
    return true;
  });
  const request = await inbound;
  editor.send(JSON.stringify({ jsonrpc: "2.0", id: request.id, error: {
    message: "Scene changed since snapshot", code: -32020, data: { paths: ["Door"], observed_version: 8 },
  } }));
  await rejected;
});

test("editor disconnect rejects pending requests and clears verified project", { timeout: 5000 }, async t => {
  const bridge = await fixture(t);
  const editor = await connectedEditor(t, bridge);
  const inbound = nextMessage(editor);
  const pending = bridge.call("scene_snapshot");
  const rejected = assert.rejects(pending, /Godot editor disconnected/);
  await inbound;
  editor.close();
  await rejected;
  assert.equal(bridge.connected, false);
  assert.equal(bridge.status().project, null);
});

test("shutdown rejects pending work and leaves the bridge disconnected", { timeout: 5000 }, async t => {
  const bridge = await fixture(t);
  const editor = await connectedEditor(t, bridge);
  const inbound = nextMessage(editor);
  const pending = bridge.call("save_scene");
  const rejected = assert.rejects(pending, /Server shutting down/);
  await inbound;
  bridge.close();
  await rejected;
  assert.equal(bridge.connected, false);
  assert.equal(bridge.status().project, null);
});

test("ping receives pong while unsolicited pong and malformed messages do not consume requests", { timeout: 5000 }, async t => {
  const bridge = await fixture(t);
  const editor = await connectedEditor(t, bridge);
  const pong = nextMessage(editor, message => message.method === "pong");
  editor.send(JSON.stringify({ jsonrpc: "2.0", method: "ping", params: {} }));
  assert.deepEqual(await pong, { jsonrpc: "2.0", method: "pong", params: {} });
  const inbound = nextMessage(editor);
  const pending = bridge.call("get_scene_tree");
  const request = await inbound;
  editor.send("not JSON");
  editor.send("[]");
  editor.send("null");
  editor.send(JSON.stringify({ jsonrpc: "2.0", method: "pong", id: request.id }));
  editor.send(JSON.stringify({ jsonrpc: "2.0", id: request.id + 100, result: "unrelated" }));
  editor.send(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: "correct" }));
  assert.equal(await pending, "correct");
});

test("valid falsy JSON-RPC results, including null, retain their value", { timeout: 5000 }, async t => {
  const bridge = await fixture(t);
  const editor = await connectedEditor(t, bridge);
  for (const value of [false, 0, "", null]) {
    const inbound = nextMessage(editor);
    const pending = bridge.call("get_node_properties");
    const request = await inbound;
    editor.send(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: value }));
    assert.equal(await pending, value);
  }
});

test("invalid ports are rejected before starting a listener", () => {
  for (const port of [-1, 65536, NaN, 1.5]) assert.throws(() => new GodotBridge(port), /Invalid GODOT_MCP_PORT/);
});
