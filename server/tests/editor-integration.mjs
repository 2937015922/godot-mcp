import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { spawn } from 'node:child_process';
import { cp, mkdir, writeFile, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { runPersistenceChecks } from './editor-persistence-checks.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const project = path.join(repo, '.local', 'editor-fixture');
const godot = process.env.GODOT_BIN;
if (!godot) throw new Error('Set GODOT_BIN to your Godot 4.7+ executable');
const port = process.env.GODOT_TEST_PORT ?? '6517';
const nativeRendering = process.env.GODOT_TEST_NATIVE === '1';
await mkdir(project, { recursive: true });
await cp(path.join(repo, 'tests/fixture'), project, { recursive: true, filter: p => !['.godot', 'addons', 'generated'].includes(path.basename(p)) });
await cp(path.join(repo, 'addons/godot_mcp'), path.join(project, 'addons/godot_mcp'), { recursive: true });
await mkdir(path.join(project, 'closed'), { recursive: true });
await mkdir(path.join(project, 'mixed'), { recursive: true });
const closedScene = '[gd_scene format=3]\n[node name="Closed" type="Node3D"]\nposition = Vector3(1, 2, 3)\n';
await writeFile(path.join(project, 'closed/a.tscn'), closedScene);
await writeFile(path.join(project, 'mixed/a.tscn'), closedScene);
await writeFile(path.join(project, 'mixed/z.tscn'), closedScene.replace('Closed', 'OpenTab'));
const log = [];
const checks = [];
const client = new Client({ name: 'godot-mcp-live-tests', version: '0.2.0' });
const transport = new StdioClientTransport({
  command: process.execPath, args: [path.join(repo, 'server/build/index.js')],
  env: { ...process.env, GODOT_MCP_PORT: port, GODOT_MCP_PROJECT: project }, stderr: 'pipe',
});
let editor;
let succeeded = false;
async function raw(name, args = {}) {
  const response = await client.callTool({ name, arguments: args });
  const value = JSON.parse(response.content.find(c => c.type === 'text').text);
  return { value, isError: response.isError === true };
}
async function call(name, args = {}) {
  const response = await raw(name, args);
  assert.equal(response.isError, false, `${name}: ${JSON.stringify(response.value)}`);
  return response.value;
}
async function fails(name, args = {}, pattern) {
  const response = await raw(name, args);
  assert.equal(response.isError, true, `${name} should reject`);
  if (pattern) assert.match(response.value.error, pattern);
  return response.value;
}
async function until(fn, timeout = 20000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await fn()) return;
    await new Promise(r => setTimeout(r, 100));
  }
  throw new Error('Timed out waiting for editor state');
}
async function check(name, fn) { log.push(`\nTEST_START ${name}\n`); await fn(); checks.push(name); log.push(`\nTEST_PASS ${name}\n`); console.log('PASS ' + name); }
async function expression(code) {
  const value = (await call('execute_editor_script', { code })).result;
  // GDScript string formatting varies between integral floats and integers.
  if (typeof value === 'string' && /^Vector3\([^)]+\)$/.test(value)) {
    return `Vector3(${value.slice(8, -1).split(',').map(Number).join(', ')})`;
  }
  return value;
}
async function position(node) { return expression(`get_node("${node}").position`); }
async function screenshot(name) {
  const response = await client.callTool({ name, arguments: {} });
  assert.notEqual(response.isError, true);
  const image = response.content.find(c => c.type === 'image');
  assert.equal(image?.mimeType, 'image/png');
  const buffer = Buffer.from(image.data, 'base64');
  assert.deepEqual([...buffer.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  assert(buffer.readUInt32BE(16) > 0 && buffer.readUInt32BE(20) > 0);
  assert(!response.content.some(c => c.type === 'text' && c.text.includes('base64')));
  await mkdir(path.join(repo, 'tests/results'), { recursive: true });
  await writeFile(path.join(repo, `tests/results/${name}.png`), buffer);
}
try {
  await client.connect(transport);
  transport.stderr?.on('data', b => log.push(b.toString()));
  editor = spawn(godot, [...(nativeRendering ? ['--rendering-method', 'gl_compatibility'] : ['--headless']), '--editor', '--path', project, '--log-file', path.join(project, 'editor.log'), 'scene.tscn'], { env: { ...process.env, GODOT_MCP_PORT: port }, windowsHide: true });
  editor.stdout.on('data', b => log.push(b.toString()));
  editor.stderr.on('data', b => log.push(b.toString()));
  await until(async () => (await call('get_bridge_status')).connected, 45000);
  await until(async () => (await call('get_scene_tree')).scene_path === 'res://scene.tscn');
  await check('native viewport camera uses the SubViewport Camera3D API', async () => {
    const before = await call('get_editor_camera');
    assert(before.cameras.length > 0);
    await fails('set_editor_camera', { viewport_index: 4 }, /between 0 and 3/);
    const result = await call('set_editor_camera', { x: 4, y: 5, z: 12, rotation_x: -0.2 });
    assert.equal(result.navigation_state_synchronized, false);
    await new Promise(resolve => setTimeout(resolve, 250));
    const after = (await call('get_editor_camera')).cameras[0];
    assert(Math.abs(after.position.x - 4) < 0.001);
    assert(Math.abs(after.position.y - 5) < 0.001);
    assert(Math.abs(after.position.z - 12) < 0.001);
    assert(Math.abs(after.rotation.x + 0.2) < 0.001);
  });
  await check('MCP handshake identifies the real Godot project', async () => {
    const info = await call('get_project_info');
    assert.match(JSON.stringify(info), /Godot MCP Collaboration Fixture/);
    assert.match(JSON.stringify(info), /4\.7/);
    const list = await client.listTools();
    assert.equal(list.tools.length, 183);
  });
  await check('scene diff captures a deferred external editor edit', async () => {
    const baseline = await call('scene_snapshot');
    if (!baseline.property_capture_complete) await writeFile(path.join(repo, '.local/incomplete-snapshot.json'), JSON.stringify(baseline, null, 2));
    assert.equal(baseline.property_capture_complete, true);
    const cursor = (await call('get_editor_activity', { limit: 512 })).latest_cursor;
    await expression('schedule_editor_move("BoxA", Vector3(1, 2, 3))');
    await until(async () => (await position('BoxA')) === 'Vector3(1, 2, 3)');
    const diff = await call('scene_diff', { snapshot_id: baseline.snapshot_id });
    assert(diff.changed.some(x => x.path === 'BoxA'));
    assert.deepEqual((await call('scene_diff', { snapshot_id: baseline.snapshot_id })).changed, diff.changed);
    const events = await call('get_editor_activity', { cursor, limit: 512 });
    assert(events.events.some(x => x.source === 'editor' && ['history_changed', 'version_changed'].includes(x.kind)));
    await fails('update_property', { node_path: 'BoxA', property: 'position', value: 'Vector3(9,9,9)', expected_scene_snapshot: baseline.snapshot_id }, /changed/i);
    assert.equal(await position('BoxA'), 'Vector3(1, 2, 3)');
    await call('undo_last');
    assert.equal(await position('BoxA'), 'Vector3(0, 0, 0)');
    await call('redo_last');
    assert.equal(await position('BoxA'), 'Vector3(1, 2, 3)');
    await call('undo_last');
  });
  await check('fresh snapshot permits a guarded edit; undo restores it', async () => {
    const snapshot = await call('scene_snapshot');
    await call('update_property', { node_path: 'BoxA', property: 'position', value: 'Vector3(2,0,0)', expected_scene_snapshot: snapshot.snapshot_id });
    assert.equal(await position('BoxA'), 'Vector3(2, 0, 0)');
    await call('undo_last');
    assert.equal(await position('BoxA'), 'Vector3(0, 0, 0)');
  });
  await check('selection validates whole request and reads current history', async () => {
    await call('set_editor_selection', { node_paths: ['BoxA'] });
    await fails('set_editor_selection', { node_paths: ['BoxB', 'Missing'] });
    const selected = await call('get_editor_selection');
    assert.deepEqual(selected.nodes.map(x => x.path), ['BoxA']);
    await fails('undo_last', { expected_version: selected.history.version + 900 }, /history changed/i);
  });
  await check('scene undo and redo leave a newer global history action unchanged', async () => {
    await call('update_property', { node_path: 'BoxA', property: 'position', value: 'Vector3(3,0,0)' });
    assert.deepEqual(await expression('simulate_global_action(42)'), { history_id: 0, value: 42 });
    await call('undo_last');
    assert.equal(await position('BoxA'), 'Vector3(0, 0, 0)');
    assert.deepEqual(await expression('simulate_global_action()'), { history_id: 0, value: 42 });
    await call('redo_last');
    assert.equal(await position('BoxA'), 'Vector3(3, 0, 0)');
    assert.deepEqual(await expression('simulate_global_action()'), { history_id: 0, value: 42 });
    await call('undo_last');
  });
  await check('native editor geometry query gives correct box separation', async () => {
    const spatial = await call('get_scene_spatial_info', { node_path: 'BoxA' });
    assert.equal(spatial.aggregate_world_aabb.size.x, 2);
    const relationship = await call('get_spatial_relationship', { first_path: 'BoxA', second_path: 'BoxB' });
    assert.equal(relationship.aabb_distance, 3);
    assert.equal(relationship.physics_overlap_tested, false);
    assert.equal(relationship.aabb_overlap, false);
  });
  await check('delete undo preserves descendants, owners and sibling order', async () => {
    const before = await expression('tree_details("BoxA")');
    await call('delete_node', { node_path: 'BoxA' });
    assert.equal(await expression('has_node("BoxA")'), false);
    await call('undo_last');
    assert.deepEqual(await expression('tree_details("BoxA")'), before);
    await call('redo_last');
    await call('undo_last');
    assert.deepEqual(await expression('tree_details("BoxA")'), before);
  });
  await check('reparent preserves world transform and undo local transform', async () => {
    await call('move_node', { node_path: 'BoxA', new_parent_path: 'Pivot' });
    assert.equal(await expression('get_node("Pivot/BoxA").global_position'), 'Vector3(0, 0, 0)');
    await call('undo_last');
    assert.equal(await position('BoxA'), 'Vector3(0, 0, 0)');
  });
  await check('invalid batch creates no partial content', async () => {
    await fails('batch_add_nodes', { nodes: [{ type: 'Node3D', name: 'Partial' }, { type: 'NoSuchGodotType', name: 'Invalid' }] });
    assert.equal(await expression('has_node("Partial")'), false);
  });
  await check('dependent parent-child batch is one undo action', async () => {
    await call('batch_add_nodes', { nodes: [{ type: 'Node3D', name: 'BatchRoot' }, { type: 'Node3D', name: 'BatchChild', parent_path: 'BatchRoot' }] });
    assert.equal(await expression('has_node("BatchRoot/BatchChild")'), true);
    await call('undo_last');
    assert.equal(await expression('has_node("BatchRoot")'), false);
    await call('redo_last');
    assert.equal(await expression('has_node("BatchRoot/BatchChild")'), true);
  });
  await check('save persists descendants and groups', async () => {
    await call('set_node_groups', { node_path: 'BoxA', groups: ['editable_prop'] });
    await call('save_scene');
    const text = await readFile(path.join(project, 'scene.tscn'), 'utf8');
    assert.match(text, /editable_prop/);
    assert.match(text, /name="Collision"/);
    assert.match(text, /name="BatchChild"/);
  });
  await runPersistenceChecks({ call, fails, expression, check, project });
  await check('open scenes reject disk overwrite and deletion', async () => {
    const before = await readFile(path.join(project, 'scene.tscn'), 'utf8');
    await fails('create_scene', { scene_path: 'res://scene.tscn', overwrite: true }, /open/i);
    await fails('delete_scene', { scene_path: 'res://scene.tscn' }, /open/i);
    assert.equal(await readFile(path.join(project, 'scene.tscn'), 'utf8'), before);
  });
  await check('cross-scene changes persist and reopened resource reads agree', async () => {
    const result = await call('cross_scene_set_property', { directory: 'res://closed', type: 'Node3D', property: 'position', value: 'Vector3(7,8,9)' });
    assert.equal(result.updated_scenes.length, 1);
    assert.equal(await expression('disk_property("res://closed/a.tscn", ".", "position")'), 'Vector3(7, 8, 9)');
  });
  await check('open-tab conflict rejects cross-scene batch before any save', async () => {
    await call('open_scene', { scene_path: 'res://mixed/z.tscn' });
    await until(async () => (await call('get_scene_tree')).scene_path === 'res://mixed/z.tscn');
    await call('open_scene', { scene_path: 'res://scene.tscn' });
    await until(async () => (await call('get_scene_tree')).scene_path === 'res://scene.tscn');
    const before = await readFile(path.join(project, 'mixed/a.tscn'), 'utf8');
    await fails('cross_scene_set_property', { directory: 'res://mixed', type: 'Node3D', property: 'position', value: 'Vector3(9,9,9)' }, /open scene/i);
    assert.equal(await readFile(path.join(project, 'mixed/a.tscn'), 'utf8'), before);
  });
  await check('game starts with runtime bridge and stops cleanly', async () => {
    if (nativeRendering) await screenshot('get_editor_screenshot');
    await call('play_scene', { mode: 'main' });
    await until(async () => !(await raw('get_game_scene_tree')).isError, 15000);
    const tree = await call('get_game_scene_tree');
    assert.match(JSON.stringify(tree), /BoxA/);
    if (nativeRendering) await screenshot('get_game_screenshot');
    await call('stop_scene');
    await until(async () => (await raw('get_game_scene_tree')).isError);
  });
  assert.doesNotMatch(log.join(''), /(?:SCRIPT )?ERROR:/, 'Editor log must be free of engine/script errors');
  succeeded = true;
  console.log(`EDITOR_INTEGRATION_OK ${checks.length}`);
} finally {
  if (editor && editor.exitCode === null) {
    try { await call('stop_scene'); } catch {}
    const closed = new Promise(resolve => editor.once('close', resolve));
    editor.kill();
    await closed;
  }
  await client.close();
  await mkdir(path.join(repo, 'tests/results'), { recursive: true });
  await writeFile(path.join(repo, 'tests/results/editor-integration.json'), JSON.stringify({ succeeded, checks, count: checks.length, log: log.join('') }, null, 2));
  if (!succeeded) console.error(log.join('').slice(-16000));
}
