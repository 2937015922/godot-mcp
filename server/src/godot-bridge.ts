import { WebSocketServer, WebSocket } from "ws";
import path from "node:path";

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

export class GodotRpcError extends Error {
  constructor(message: string, readonly code?: number, readonly data?: unknown) {
    super(message);
    this.name = "GodotRpcError";
  }
}

function normalizeProject(value: string): string {
  const normalized = path.resolve(value).replaceAll("\\", "/").replace(/\/$/, "");
  return process.platform === "win32" ? normalized.toLowerCase() : normalized;
}

export class GodotBridge {
  private wss: WebSocketServer | null = null;
  private client: WebSocket | null = null;
  private ready = false;
  private project: Record<string, unknown> | null = null;
  private pending = new Map<number, PendingRequest>();
  private nextId = 1;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  readonly port: number;
  readonly expectedProject: string | undefined;

  constructor(port = Number(process.env.GODOT_MCP_PORT ?? 6505), expectedProject = process.env.GODOT_MCP_PROJECT) {
    if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error("Invalid GODOT_MCP_PORT");
    this.port = port;
    this.expectedProject = expectedProject ? normalizeProject(expectedProject) : undefined;
  }

  start(): void {
    if (this.wss) return;
    this.wss = new WebSocketServer({ port: this.port, host: "127.0.0.1" });
    this.wss.on("error", (error) => console.error("[godot-mcp] Bridge error: " + error.message));
    this.wss.on("connection", (ws) => {
      // Never allow a second editor to hijack an active session.
      if (this.client && this.client.readyState !== WebSocket.CLOSED) {
        ws.close(4009, "Another editor is already connected");
        return;
      }
      this.client = ws;
      this.ready = false;
      const handshake = setTimeout(() => {
        if (!this.ready && this.client === ws) ws.close(4008, "Plugin 0.2+ handshake required");
      }, 5000);
      ws.on("message", (data) => this.onMessage(ws, data.toString()));
      ws.on("close", () => {
        clearTimeout(handshake);
        if (this.client !== ws) return;
        this.client = null;
        this.ready = false;
        this.project = null;
        this.rejectAll(new Error("Godot editor disconnected"));
        console.error("[godot-mcp] Godot editor disconnected");
      });
      ws.on("error", () => ws.close());
    });
    this.heartbeatTimer = setInterval(() => {
      if (this.connected) this.client!.send(JSON.stringify({ jsonrpc: "2.0", method: "ping", params: {} }));
    }, 10_000);
    console.error("[godot-mcp] Listening on ws://127.0.0.1:" + this.port);
  }

  get connected(): boolean { return this.ready && this.client?.readyState === WebSocket.OPEN; }

  status(): Record<string, unknown> {
    return { connected: this.connected, expected_project: this.expectedProject ?? null, project: this.project, port: this.port, version: "0.2.0" };
  }

  async call(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
    if (!this.connected || !this.client) throw new Error("Godot editor not connected. Open the expected project with the matching Godot MCP 0.2+ plugin.");
    const id = this.nextId++;
    const client = this.client;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error("Request timeout: " + method));
      }, 30_000);
      this.pending.set(id, { resolve, reject, timer });
      client.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }), (error) => {
        if (!error) return;
        const request = this.pending.get(id);
        if (!request) return;
        clearTimeout(request.timer);
        this.pending.delete(id);
        request.reject(error);
      });
    });
  }

  close(): void {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = null;
    this.rejectAll(new Error("Server shutting down"));
    this.client?.close();
    this.client = null;
    this.ready = false;
    this.project = null;
    for (const client of this.wss?.clients ?? []) client.terminate();
    this.wss?.close();
    this.wss = null;
  }

  private onMessage(ws: WebSocket, text: string): void {
    if (ws !== this.client) return;
    let msg: { id?: number; method?: string; params?: Record<string, unknown>; result?: unknown; error?: { message?: string; code?: number; data?: unknown } };
    try { msg = JSON.parse(text); } catch { return; }
    if (!msg || typeof msg !== "object" || Array.isArray(msg)) return;
    if (msg.method === "godot_hello") {
      const projectPath = msg.params?.project_path;
      if (typeof projectPath !== "string" || (this.expectedProject && normalizeProject(projectPath) !== this.expectedProject)) {
        ws.close(4003, "Project does not match GODOT_MCP_PROJECT");
        return;
      }
      if (this.ready) return;
      this.project = msg.params ?? null;
      this.ready = true;
      console.error("[godot-mcp] Editor connected: " + projectPath);
      return;
    }
    if (msg.method === "ping") {
      ws.send(JSON.stringify({ jsonrpc: "2.0", method: "pong", params: {} }));
      return;
    }
    if (msg.method === "pong" || !this.ready || msg.id === undefined) return;
    const request = this.pending.get(msg.id);
    if (!request) return;
    this.pending.delete(msg.id);
    clearTimeout(request.timer);
    if (msg.error) request.reject(new GodotRpcError(msg.error.message ?? "Unknown Godot error", msg.error.code, msg.error.data));
    else request.resolve(Object.hasOwn(msg, "result") ? msg.result : {});
  }

  private rejectAll(error: Error): void {
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(error);
    }
    this.pending.clear();
  }
}
