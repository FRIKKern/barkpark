import assert from 'node:assert/strict';
import { test } from 'node:test';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { classifyPaths, dispatch, gate } from './barkdown-parity-dispatch.mjs';

const sha = 'a'.repeat(40), other = 'b'.repeat(40);
const input = { event: 'pull_request', base: sha, head: other };
const script = fileURLToPath(new URL('./barkdown-parity-dispatch.mjs', import.meta.url));

test('original editor paths and the dispatcher itself select the matrix', () => {
  for (const file of ['api/assets/paper-editor/src/canvas/table-node.js', 'api/lib/barkpark/portable_doc/render.ex',
    'api/priv/static/assets/bp-paper-editor.bundle.js', '.github/workflows/barkdown-parity.yml',
    'scripts/barkdown-parity-dispatch.mjs', 'scripts/barkdown-parity-dispatch.test.mjs']) {
    assert.equal(classifyPaths([file]).needed, true, file);
  }
  assert.equal(classifyPaths(['docs/PLAN.md', 'api/lib/barkpark/media.ex']).needed, false);
  assert.throws(() => classifyPaths(null));
  assert.throws(() => classifyPaths(['../escape']));
});

test('unknown refs or failed/truncated diffs refuse; empty diffs run the full matrix', () => {
  assert.equal(dispatch({ event: 'workflow_dispatch' }, () => { throw Error('unexpected git call'); }).needed, true);
  assert.throws(() => dispatch({ ...input, event: 'push' }, () => {}));
  assert.throws(() => dispatch({ ...input, head: 'missing' }, () => {}));
  for (const result of [{ status: 1, stdout: '' }, { status: 0, stdout: 'api/assets/paper-editor/index.js' },
    { status: 0, stdout: null }, { status: 0, error: Error('timeout'), stdout: '' }]) {
    assert.throws(() => dispatch(input, () => result));
  }
  assert.equal(dispatch(input, () => ({ status: 0, stdout: 'docs/x.md\0api/assets/paper-editor/new\nname.js\0' })).needed, true);
  assert.equal(dispatch(input, () => ({ status: 0, stdout: '' })).needed, true);
});

test('failed, cancelled, skipped and absent dependencies cannot become green', () => {
  for (const state of ['failure', 'cancelled', 'skipped', 'timed_out', '']) {
    assert.equal(gate(state, 'false', 'skipped'), false);
    assert.equal(gate('success', 'true', state), false);
  }
  assert.equal(gate('success', 'true', 'success'), true);
  assert.equal(gate('success', 'false', 'skipped'), true);
  assert.equal(gate('success', '', 'skipped'), false);
  assert.equal(gate('success', 'false', 'success'), false);
});

test('CLI emits only a boolean output and rejects an unavailable diff', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'bp-parity-dispatch-'));
  const output = path.join(root, 'output.txt');
  writeFileSync(output, '');
  const env = { ...process.env, GITHUB_OUTPUT: output, G2_EVENT: 'workflow_dispatch' };
  const explicit = spawnSync(process.execPath, [script, 'dispatch'], { cwd: root, env, encoding: 'utf8', windowsHide: true });
  assert.equal(explicit.status, 0, explicit.stderr);
  assert.equal(readFileSync(output, 'utf8'), 'needed=true\n');
  const unavailable = spawnSync(process.execPath, [script, 'dispatch'], {
    cwd: root, env: { ...env, G2_EVENT: 'pull_request', G2_BASE: sha, G2_HEAD: other }, encoding: 'utf8', windowsHide: true,
  });
  assert.equal(unavailable.status, 1);
  assert.match(unavailable.stderr, /Cannot establish changed paths/);
  assert.equal(readFileSync(output, 'utf8'), 'needed=true\n');
});

test('CLI gate labels an irrelevant diff and exits nonzero on a cancelled matrix', () => {
  const env = { ...process.env, G2_CHANGES_RESULT: 'success', G2_NEEDED: 'false', G2_MATRIX_RESULT: 'skipped' };
  const irrelevant = spawnSync(process.execPath, [script, 'gate'], { env, encoding: 'utf8', windowsHide: true });
  assert.equal(irrelevant.status, 0);
  assert.match(irrelevant.stdout, /NOT APPLICABLE.*No editor row ran/);
  const cancelled = spawnSync(process.execPath, [script, 'gate'], {
    env: { ...env, G2_NEEDED: 'true', G2_MATRIX_RESULT: 'cancelled' }, encoding: 'utf8', windowsHide: true,
  });
  assert.equal(cancelled.status, 1);
});

test('CLI uses real Git diffs for editor and documentation-only commits', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'bp-parity-git-'));
  const git = args => {
    const result = spawnSync('git', args, { cwd: root, encoding: 'utf8', windowsHide: true });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  const commit = message => {
    git(['add', '.']);
    git(['-c', 'user.name=Parity fixture', '-c', 'user.email=parity@example.invalid', 'commit', '--quiet', '-m', message]);
    return git(['rev-parse', 'HEAD']);
  };
  git(['init', '--quiet']);
  writeFileSync(path.join(root, 'README.md'), 'fixture\n');
  const base = commit('initial fixture');
  writeFileSync(path.join(root, 'README.md'), 'changed documentation\n');
  const docsHead = commit('documentation fixture');
  mkdirSync(path.join(root, 'api/assets/paper-editor'), { recursive: true });
  writeFileSync(path.join(root, 'api/assets/paper-editor/index.js'), 'fixture\n');
  const editorHead = commit('editor fixture');
  for (const [head, needed] of [[docsHead, false], [editorHead, true], [base, true]]) {
    const output = path.join(root, `output-${head}.txt`);
    const result = spawnSync(process.execPath, [script, 'dispatch'], {
      cwd: root, env: { ...process.env, G2_EVENT: 'pull_request', G2_BASE: base, G2_HEAD: head, GITHUB_OUTPUT: output },
      encoding: 'utf8', windowsHide: true,
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(result.stdout).needed, needed);
    assert.equal(readFileSync(output, 'utf8'), `needed=${needed}\n`);
  }
});

test('an older PR head runs merged helpers while the diff still names only its own changes', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'bp-parity-older-head-'));
  const git = args => {
    const result = spawnSync('git', args, { cwd: root, encoding: 'utf8', windowsHide: true });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  const commit = message => {
    git(['add', '.']);
    git(['commit', '--quiet', '-m', message]);
    return git(['rev-parse', 'HEAD']);
  };
  git(['init', '--quiet']);
  git(['config', 'user.name', 'Parity fixture']);
  git(['config', 'user.email', 'parity@example.invalid']);
  mkdirSync(path.join(root, 'empty-hooks'));
  git(['config', 'core.hooksPath', path.join(root, 'empty-hooks')]);
  writeFileSync(path.join(root, 'README.md'), 'initial fixture\n');
  const initial = commit('before helpers existed');
  mkdirSync(path.join(root, 'scripts'));
  for (const file of ['barkdown-parity-dispatch.mjs', 'node-test-floor.mjs']) {
    copyFileSync(new URL(`./${file}`, import.meta.url), path.join(root, 'scripts', file));
  }
  const base = commit('base introduces actual helpers');
  for (const [file, needed] of [['README.md', false], ['api/assets/paper-editor/index.js', true]]) {
    git(['checkout', '--quiet', '--detach', initial]);
    mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    writeFileSync(path.join(root, file), 'head-only change\n');
    const head = commit('older branch edit');
    const missing = spawnSync(process.execPath, ['scripts/barkdown-parity-dispatch.mjs', 'dispatch'], {
      cwd: root, encoding: 'utf8', windowsHide: true,
    });
    assert.notEqual(missing.status, 0);
    assert.match(missing.stderr, /MODULE_NOT_FOUND/);
    git(['checkout', '--quiet', '--detach', base]);
    git(['merge', '--quiet', '--no-ff', head, '-m', 'actual merged checkout']);
    const merged = git(['rev-parse', 'HEAD']);
    assert.notEqual(merged, head);
    assert.equal(git(['show', '-s', '--format=%P']), `${base} ${head}`);
    const output = path.join(root, `decision-${head}.txt`);
    const result = spawnSync(process.execPath, ['scripts/barkdown-parity-dispatch.mjs', 'dispatch'], {
      cwd: root, env: { ...process.env, G2_EVENT: 'pull_request', G2_BASE: base, G2_HEAD: head, GITHUB_OUTPUT: output },
      encoding: 'utf8', windowsHide: true,
    });
    assert.equal(result.status, 0, result.stderr);
    const decision = JSON.parse(result.stdout);
    assert.equal(decision.base, base);
    assert.equal(decision.head, head);
    assert.equal(decision.needed, needed);
    assert.deepEqual(decision.selected, needed ? [file] : []);
    assert.equal(readFileSync(output, 'utf8'), `needed=${needed}\n`);
  }
});

test('workflow routes real dependency results into an unconditional gate', () => {
  const workflow = readFileSync(new URL('../.github/workflows/barkdown-parity.yml', import.meta.url), 'utf8');
  const trigger = workflow.slice(workflow.indexOf('\non:'), workflow.indexOf('\npermissions:'));
  assert.match(trigger, /\n  pull_request:/);
  assert.doesNotMatch(trigger, /\n    paths:/);
  assert.doesNotMatch(workflow, /BARKDOWN_READ_TOKEN|continue-on-error/);
  const changesJob = workflow.slice(workflow.indexOf('\n  changes:'), workflow.indexOf('\n  parity:'));
  assert.doesNotMatch(changesJob, /\n\s+ref:/, 'merged checkout must carry base helpers for older PR heads');
  assert.match(changesJob, /fetch-depth: 0/);
  assert.ok(changesJob.includes('G2_BASE: ${{ github.event.pull_request.base.sha }}'));
  assert.ok(changesJob.includes('G2_HEAD: ${{ github.event.pull_request.head.sha }}'));
  const gateJob = workflow.slice(workflow.indexOf('\n  gate:'));
  assert.match(gateJob, /needs: \[changes, parity\]/);
  assert.match(gateJob, /if: always\(\)/);
  for (const [variable, expression] of [['G2_CHANGES_RESULT', 'needs.changes.result'],
    ['G2_NEEDED', 'needs.changes.outputs.needed'], ['G2_MATRIX_RESULT', 'needs.parity.result']]) {
    assert.ok(gateJob.includes(`${variable}: \${{ ${expression} }}`));
  }
  assert.match(gateJob, /run: node scripts\/barkdown-parity-dispatch\.mjs gate/);
});
