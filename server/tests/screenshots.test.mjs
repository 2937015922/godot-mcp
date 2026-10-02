import assert from "node:assert/strict";
import test from "node:test";
import { registerTools } from "../build/tools.js";

// A real one-pixel PNG, so the fixture satisfies the native MCP image contract.
const PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWZkAAAAASUVORK5CYII=";

function registeredTools(reply) {
  const handlers = new Map();
  const calls = [];
  registerTools({
    tool(name, _description, _schema, handler) { handlers.set(name, handler); },
  }, {
    async call(method, args) {
      calls.push({ method, args });
      return reply;
    },
  });
  return { handlers, calls };
}

for (const name of ["get_editor_screenshot", "get_game_screenshot"]) {
  test(`${name} exposes PNG pixels as native image content and keeps metadata readable`, async () => {
    const screenshot = {
      base64: PNG_BASE64,
      width: 1,
      height: 1,
      path: "C:/fixture/screenshot.png",
      meta: { target: name === "get_editor_screenshot" ? "editor" : "game" },
    };
    const { handlers, calls } = registeredTools(screenshot);
    const result = await handlers.get(name)({});
    assert.notEqual(result.isError, true);
    assert.deepEqual(calls, [{ method: name, args: {} }]);
    assert.equal(result.content.length, 2);
    const pixels = result.content.find(block => block.type === "image");
    assert.deepEqual(pixels, { type: "image", mimeType: "image/png", data: PNG_BASE64 });
    const metadata = result.content.find(block => block.type === "text");
    assert.ok(metadata, "Screenshot metadata should remain readable as text");
    assert.equal(metadata.text.includes(PNG_BASE64), false, "Image bytes must not also consume text context");
    const parsed = JSON.parse(metadata.text);
    assert.equal(Object.hasOwn(parsed, "base64"), false);
    assert.deepEqual(parsed, { width: 1, height: 1, path: screenshot.path, meta: screenshot.meta });
    assert.equal(screenshot.base64, PNG_BASE64, "Formatting must not mutate the bridge response");
  });

  test(`${name} rejects missing pixels and invalid dimensions as tool errors`, async t => {
    const cases = [
      ["empty pixel data", { base64: "", width: 1, height: 1 }],
      ["missing pixel data", { width: 1, height: 1 }],
      ["non-string pixel data", { base64: 123, width: 1, height: 1 }],
      ["zero width", { base64: PNG_BASE64, width: 0, height: 1 }],
      ["zero height", { base64: PNG_BASE64, width: 1, height: 0 }],
      ["negative width", { base64: PNG_BASE64, width: -1, height: 1 }],
      ["negative height", { base64: PNG_BASE64, width: 1, height: -1 }],
    ];
    for (const [description, reply] of cases) {
      await t.test(description, async () => {
        const { handlers } = registeredTools(reply);
        const result = await handlers.get(name)({});
        assert.equal(result.isError, true);
        assert.equal(result.content.some(block => block.type === "image"), false);
        assert.ok(result.content.some(block => block.type === "text" && block.text.length > 0));
      });
    }
  });
}

test("unrelated tools retain arbitrary base64 fields as ordinary JSON data", async () => {
  const reply = { base64: PNG_BASE64, width: 1, height: 1, path: "res://asset.bin", other: "project metadata" };
  const { handlers } = registeredTools(reply);
  const result = await handlers.get("get_project_info")({});
  assert.notEqual(result.isError, true);
  assert.equal(result.content.length, 1);
  assert.equal(result.content[0].type, "text");
  assert.deepEqual(JSON.parse(result.content[0].text), reply);
});
