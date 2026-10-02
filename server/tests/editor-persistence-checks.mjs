// Optional extension for editor-integration.mjs. Call while scene.tscn is active.
// The caller owns the editor/server lifecycle and passes its existing helpers.
import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

export async function runPersistenceChecks({ call, fails, expression, check, project }) {
  await check('resource assignment undo restores original resource and redo saves replacement', async () => {
    const original = await expression('get_node("BoxA").mesh.get_instance_id()');
    await call('add_resource', { node_path: 'BoxA', resource_type: 'SphereMesh' });
    assert.equal(await expression('get_node("BoxA").mesh.is_class("SphereMesh")'), true);
    await call('undo_last');
    assert.equal(await expression('get_node("BoxA").mesh.get_instance_id()'), original);
    await call('redo_last');
    await call('save_scene');
    assert.equal(await expression('disk_property("res://scene.tscn", "BoxA", "mesh").is_class("SphereMesh")'), true);
    await call('undo_last');
    assert.equal(await expression('get_node("BoxA").mesh.get_instance_id()'), original);
  });

  await check('persistent signal connection supports undo redo and disconnect undo', async () => {
    await call('add_node', { type: 'Timer', name: 'PersistenceTimer' });
    const args = { from_path: 'PersistenceTimer', signal: 'timeout', to_path: '.', method: 'reset_physics_interpolation' };
    const connected = () => expression('get_node("PersistenceTimer").is_connected("timeout", Callable(get_node("."), "reset_physics_interpolation"))');
    const baseline = await call('scene_snapshot');
    await call('connect_signal', args);
    assert.equal(await connected(), true);
    const diff = await call('scene_diff', { snapshot_id: baseline.snapshot_id });
    assert(diff.changed.some(node => node.path === 'PersistenceTimer' && node.changes.persistent_signals));
    await fails('save_scene', { expected_scene_snapshot: baseline.snapshot_id }, /changed/i);
    await call('undo_last');
    assert.equal(await connected(), false);
    await call('redo_last');
    assert.equal(await connected(), true);
    await call('disconnect_signal', args);
    assert.equal(await connected(), false);
    await call('undo_last');
    assert.equal(await connected(), true);
    await call('save_scene');
    const source = await readFile(path.join(project, 'scene.tscn'), 'utf8');
    assert.match(source, /\[connection signal="timeout" from="PersistenceTimer" to="\." method="reset_physics_interpolation"/);
  });

  await check('group undo preserves transient membership and persistence flags', async () => {
    await expression('get_node("PersistenceTimer").add_to_group("runtime_only", false)');
    await call('set_node_groups', { node_path: 'PersistenceTimer', groups: ['saved_group'] });
    assert.equal(await expression('get_node("PersistenceTimer").is_in_group("saved_group")'), true);
    assert.equal(await expression('get_node("PersistenceTimer").is_in_group("runtime_only")'), false);
    await call('undo_last');
    assert.equal(await expression('get_node("PersistenceTimer").is_in_group("runtime_only")'), true);
    assert.equal(await expression('get_node("PersistenceTimer").is_in_group("saved_group")'), false);
    await call('save_scene');
    let source = await readFile(path.join(project, 'scene.tscn'), 'utf8');
    assert.doesNotMatch(source, /runtime_only|saved_group/);
    await call('redo_last');
    await call('save_scene');
    source = await readFile(path.join(project, 'scene.tscn'), 'utf8');
    assert.match(source, /saved_group/);
    assert.doesNotMatch(source, /runtime_only/);
    await call('delete_node', { node_path: 'PersistenceTimer' });
  });

  await check('batch property update restores all original values with one undo', async () => {
    const visibility = () => expression('[get_node("BoxA").visible, get_node("BoxB").visible]');
    const before = await visibility();
    await call('batch_set_property', { type: 'MeshInstance3D', property: 'visible', value: 'false' });
    assert.deepEqual(await visibility(), [false, false]);
    await call('undo_last');
    assert.deepEqual(await visibility(), before);
    await call('redo_last');
    assert.deepEqual(await visibility(), [false, false]);
    await call('undo_last');
  });

  await check('invalid property in later batch entry leaves no partial scene edits', async () => {
    await fails('batch_add_nodes', { nodes: [
      { type: 'Node3D', name: 'MustNotExist' },
      { type: 'Node3D', name: 'InvalidProperty', properties: { position: 'not a vector' } },
    ] });
    assert.equal(await expression('has_node("MustNotExist")'), false);
    assert.equal(await expression('has_node("InvalidProperty")'), false);
  });

  await check('cross-scene validation error leaves earlier valid file unchanged', async () => {
    const directory = path.join(project, 'invalid-batch');
    await mkdir(directory, { recursive: true });
    const first = '[gd_scene format=3]\n[node name="Valid" type="Node3D"]\nposition = Vector3(1, 2, 3)\n';
    const last = '[gd_scene format=3]\n[node name="Invalid" type="Node"]\n';
    await writeFile(path.join(directory, 'a.tscn'), first);
    await writeFile(path.join(directory, 'z.tscn'), last);
    await fails('cross_scene_set_property', { directory: 'res://invalid-batch', type: 'Node', property: 'position', value: 'Vector3(9, 9, 9)' }, /Unknown property/);
    assert.equal(await readFile(path.join(directory, 'a.tscn'), 'utf8'), first);
    assert.equal(await readFile(path.join(directory, 'z.tscn'), 'utf8'), last);
  });
}
