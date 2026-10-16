import { spawnSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

export function classifyPaths(paths) {
  if (!Array.isArray(paths)) throw new Error('Changed paths are unavailable');
  const selected = [];
  for (const file of paths) {
    if (typeof file !== 'string' || !file || file.startsWith('/') || file.split('/').includes('..') || file.includes('\0')) {
      throw new Error('Invalid changed path');
    }
    if (file.startsWith('api/assets/paper-editor/') ||
        file.startsWith('api/lib/barkpark/portable_doc/') ||
        file.startsWith('api/priv/static/assets/bp-paper-editor') ||
        file === '.github/workflows/barkdown-parity.yml' ||
        file === 'scripts/barkdown-parity-dispatch.mjs' ||
        file === 'scripts/barkdown-parity-dispatch.test.mjs') {
      selected.push(file);
    }
  }
  return { needed: selected.length > 0, selected };
}

export function dispatch({ event, base, head }, gitDiff) {
  if (event === 'workflow_dispatch') return { needed: true, reason: 'explicit dispatch', selected: [] };
  if (event !== 'pull_request') throw new Error('Unsupported parity event');
  if (!/^[a-f0-9]{40}$/.test(base || '') || !/^[a-f0-9]{40}$/.test(head || '')) {
    throw new Error('Missing full PR base/head');
  }
  const result = gitDiff(base, head);
  if (result.error || result.status !== 0 || typeof result.stdout !== 'string') {
    throw new Error('Cannot establish changed paths');
  }
  if (result.stdout && !result.stdout.endsWith('\0')) throw new Error('Truncated changed-path response');
  const paths = result.stdout ? result.stdout.slice(0, -1).split('\0') : [];
  // An empty result cannot establish that the diff is irrelevant. Run the rows.
  if (!paths.length) return { needed: true, reason: 'empty diff: conservative full matrix', selected: [], base, head };
  return { ...classifyPaths(paths), reason: 'PR changed paths', base, head };
}

export function gate(changesResult, needed, matrixResult) {
  if (changesResult !== 'success') return false;
  if (needed === 'true') return matrixResult === 'success';
  if (needed === 'false') return matrixResult === 'skipped';
  return false;
}

export function main(env, mode, gitDiff) {
  if (mode === 'gate') {
    if (!gate(env.G2_CHANGES_RESULT, env.G2_NEEDED, env.G2_MATRIX_RESULT)) {
      throw new Error('Parity dispatch or matrix did not establish a passing result');
    }
    if (env.G2_NEEDED === 'false') {
      console.log('::notice title=Barkdown parity gate: green — nothing ran::NOT APPLICABLE: this PR changed no declared editor/PortableDoc paths. No editor row ran; this is not a matrix pass.');
    } else {
      console.log('Barkdown parity matrix completed successfully.');
    }
    return;
  }
  if (mode !== 'dispatch') throw new Error('Expected dispatch or gate mode');
  const result = dispatch({ event: env.G2_EVENT, base: env.G2_BASE, head: env.G2_HEAD }, gitDiff);
  if (!env.GITHUB_OUTPUT) throw new Error('GITHUB_OUTPUT is required');
  // Only the boolean crosses the workflow-output boundary; filenames remain JSON.
  appendFileSync(env.GITHUB_OUTPUT, `needed=${result.needed}\n`);
  console.log(JSON.stringify(result));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main(process.env, process.argv[2], (base, head) => spawnSync('git', ['diff', '--name-only', '-z', `${base}...${head}`], {
      encoding: 'utf8', maxBuffer: 64e6, timeout: 60_000, windowsHide: true,
    }));
  } catch (error) {
    console.error(`::error::${error.message}`);
    process.exitCode = 1;
  }
}
