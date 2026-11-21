// The walk of every part count (tests/counts.mjs) is not one of the fast tests, so these hold what makes it run: the
// package script, CI's step, and the rule that decides when a pull request needs it.
import { execFileSync } from 'node:child_process'
import { globSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import config from '../vitest.config.ts'
import { changedSince, main, walk, WALK_SECONDS, walkInclude, walkNeeded } from './counts.mjs'

// The walk step in js-tests.yml, whole, with the comment above it: the one allowed form. Any edit to either is red
// here until this pin is changed on purpose, in the same change; the red says so, and so does the comment.
const STEP = `      # BarkUI's fast tests hold for every number of parts the showroom allows, 1 to MOST_PARTS
      # (js/packages/barkui/check/jobs.mjs): the walk runs them once per count, about a minute, so it is
      # not one of the fast tests. On a pull request the walk decides from the files changed since the base
      # (walkNeeded in js/packages/barkui/tests/counts.mjs): it is skipped only when every changed file is
      # in another package; on main it always walks. Its bound is inside the walk (WALK_SECONDS); the
      # step's timeout is the backstop. This comment and the step are pinned whole, byte for byte, by STEP in
      # js/packages/barkui/tests/counts.test.mjs: an edit here is red until STEP is changed in the same change.
      - name: "BarkUI: the fast tests hold at every part count"
        timeout-minutes: 15
        run: |
          if [ "\${{ github.event_name }}" = "pull_request" ]; then
            pnpm --filter @barkpark/barkui run test:counts --since "origin/\${{ github.base_ref }}"
          else
            pnpm --filter @barkpark/barkui run test:counts
          fi
`

const repo = (p) => new URL(`../../../../${p}`, import.meta.url)

/** The job of a workflow that holds the line at `at`: its name, its text, and its own keys (the lines at the job's
    key depth, two spaces in from its name), read from the indentation the file is written in. */
function jobOf(wf, at) {
  const lines = wf.split('\n')
  const line = wf.slice(0, at).split('\n').length - 1
  const top = lines.findIndex((l) => l === 'jobs:')
  let start = line
  while (start > top && !/^  [\w-]+:\s*$/.test(lines[start])) start--
  let end = line + 1
  while (end < lines.length && !/^ {0,2}\S/.test(lines[end])) end++
  const own = lines.slice(start + 1, end)
  return {
    name: start > top ? lines[start].trim().slice(0, -1) : null,
    from: lines.slice(0, start).join('\n').length + (start ? 1 : 0),
    text: lines.slice(start, end).join('\n'),
    keys: own.map((l) => l.match(/^    ([\w-]+):/)?.[1]).filter(Boolean),
  }
}

describe('the walk of every part count', () => {
  it('runs for any change to this package, and for any change outside the js packages', () => {
    for (const f of ['parts/button/part.css', 'check/jobs.mjs', 'build/showroom.mjs', 'tests/jobs.test.mjs', 'docs/PARTS.md', 'package.json'])
      expect(walkNeeded([`js/packages/barkui/${f}`]), f).toBe(true)
    for (const f of ['.github/workflows/js-tests.yml', 'js/pnpm-lock.yaml', 'js/package.json', 'api/priv/barkui/tokens.css', '.github/required-checks.json'])
      expect(walkNeeded([f]), f).toBe(true)
    expect(walkNeeded(['js/packages/core/src/index.ts', 'js/packages/barkui/check/run.mjs'])).toBe(true)
  })

  it('is skipped only when every changed file is in another package, and walks when the list is empty', () => {
    expect(walkNeeded(['js/packages/core/src/index.ts', 'js/test-harnesses/workerd/src/a.ts'])).toBe(false)
    expect(walkNeeded(['js/packages/barkui-other/x.mjs'])).toBe(false)
    expect(walkNeeded([])).toBe(true)
    expect(walkNeeded([''])).toBe(true)
  })

  it('runs when a file of this package moves into another package: the old path is in the list', () => {
    const root = mkdtempSync(join(tmpdir(), 'barkui-counts-git-'))
    try {
      const git = (...a) => execFileSync('git', ['-C', root, '-c', 'user.name=t', '-c', 'user.email=t@t', ...a], { encoding: 'utf8' })
      git('init', '-q', '-b', 'main')
      const from = 'js/packages/barkui/docs/PARTS.md'
      mkdirSync(join(root, dirname(from)), { recursive: true })
      writeFileSync(join(root, from), 'The part folder and the check.\n'.repeat(20))
      git('add', '-A')
      git('commit', '-q', '-m', 'base')
      mkdirSync(join(root, 'js/packages/core'), { recursive: true })
      git('mv', from, 'js/packages/core/zz-PARTS.md')
      git('commit', '-q', '-m', 'move out')
      const changed = changedSince('HEAD~1', root)
      expect(changed).toContain(from)
      expect(walkNeeded(changed)).toBe(true)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('runs the same test files as vitest.config.ts, in a subfolder of tests/ too', () => {
    const scratch = mkdtempSync(join(tmpdir(), 'barkui-counts-include-'))
    try {
      const pkg = walkInclude()[0].replace(/^n\*\//, '').replace(/\/tests\/.*$/, '')
      for (const f of ['tests/a.test.mjs', 'tests/sub/b.test.mjs']) {
        mkdirSync(join(scratch, 'n01', pkg, dirname(f)), { recursive: true })
        writeFileSync(join(scratch, 'n01', pkg, f), '')
      }
      const walked = walkInclude().flatMap((p) => globSync(p, { cwd: scratch })).map((f) => f.slice(`n01/${pkg}/`.length)).sort()
      const fast = config.test.include.flatMap((p) => globSync(p, { cwd: join(scratch, 'n01', pkg) })).sort()
      expect(walkInclude()).toEqual(config.test.include.map((p) => `n*/${pkg}/${p}`))
      expect(walked).toEqual(['tests/a.test.mjs', 'tests/sub/b.test.mjs'])
      expect(walked).toEqual(fast)
    } finally {
      rmSync(scratch, { recursive: true, force: true })
    }
  })

  it('is one package script, which CI runs as one pinned step after the fast tests, in a job nothing lets pass', () => {
    expect(JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).scripts['test:counts']).toBe('node tests/counts.mjs')
    const wf = readFileSync(repo('.github/workflows/js-tests.yml'), 'utf8')
    const at = wf.indexOf('      - name: "BarkUI: the fast tests hold at every part count"\n')
    expect(at).toBeGreaterThan(0)
    expect(wf.indexOf('      - name: "BarkUI: the fast tests hold at every part count"', at + 1)).toBe(-1)
    // The block runs from the blank line above the comment to the first blank line after the step, and it is the pin.
    const block = wf.slice(wf.lastIndexOf('\n\n', at) + 2, wf.indexOf('\n\n', at) + 1)
    expect(block, 'The BarkUI walk step in .github/workflows/js-tests.yml, or the comment above it, is not the pinned text. If the change is on purpose, change STEP in js/packages/barkui/tests/counts.test.mjs to match, in the same change.').toBe(STEP)
    expect(Number(STEP.match(/timeout-minutes: (\d+)/)[1]) * 60).toBeGreaterThan(WALK_SECONDS)
    // Its job is `test`, the one that runs the fast tests first, and that job has no condition and nothing that lets
    // it pass, among its own keys wherever they sit.
    const job = jobOf(wf, at)
    expect(job.name, 'the walk step is not in the test job').toBe('test')
    expect(job.text.indexOf('run: pnpm exec turbo run test ${{ steps.scope.outputs.filter }}')).toBeGreaterThan(0)
    expect(job.text.indexOf('run: pnpm exec turbo run test ${{ steps.scope.outputs.filter }}')).toBeLessThan(at - job.from)
    expect(job.keys.filter((k) => ['if', 'continue-on-error'].includes(k)), 'the test job may not carry if or continue-on-error').toEqual([])
  })

  it('reads the changed files through changedSince with --since, walks when they need it, and always walks without it', () => {
    const root = mkdtempSync(join(tmpdir(), 'barkui-counts-cli-'))
    try {
      const git = (...a) => execFileSync('git', ['-C', root, '-c', 'user.name=t', '-c', 'user.email=t@t', ...a], { encoding: 'utf8' })
      const put = (f, body) => (mkdirSync(join(root, dirname(f)), { recursive: true }), writeFileSync(join(root, f), body))
      git('init', '-q', '-b', 'main')
      put('js/packages/barkui/docs/PARTS.md', 'The part folder and the check.\n'.repeat(20))
      put('js/packages/core/src/index.ts', 'export {}\n')
      git('add', '-A')
      git('commit', '-q', '-m', 'base')
      const run = (argv) => {
        let walked = 0
        const code = main(argv, { root, walkAll: () => (walked++, []), log: () => {} })
        return { code, walked }
      }
      // A change only in another package: skipped. A file of this package moved out of it: walked.
      put('js/packages/core/src/index.ts', 'export const a = 1\n')
      git('commit', '-q', '-am', 'core only')
      expect(run(['--since', 'HEAD~1'])).toEqual({ code: 0, walked: 0 })
      git('mv', 'js/packages/barkui/docs/PARTS.md', 'js/packages/core/zz-PARTS.md')
      git('commit', '-q', '-m', 'move out')
      expect(run(['--since', 'HEAD~1'])).toEqual({ code: 0, walked: 1 })
      // A ref that cannot be read walks; no --since always walks.
      expect(run(['--since', 'no-such-ref'])).toEqual({ code: 0, walked: 1 })
      expect(run([])).toEqual({ code: 0, walked: 1 })
      expect(main([], { walkAll: () => ['n02 a.test.mjs: x: y'], log: () => {} })).toBe(1)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  // Real walks of two counts, with the copies planted: each turns the walk red by name. Inside a walk's copy they
  // hold nothing (the walk sets BARKUI_IN_WALK): they read the walk, not the part count, and a walk in every copy
  // would multiply its time.
  // Only a file in a walk's own copy may skip: BARKUI_IN_WALK set by hand anywhere else is red, never a skip.
  const inCopy = /barkui-part-counts-[^/\\]+[/\\]n\d+[/\\]/.test(fileURLToPath(import.meta.url))
  const outer = !process.env.BARKUI_IN_WALK
  const skips = () => {
    if (outer) return false
    expect(inCopy, 'BARKUI_IN_WALK is set, but this file is not in a copy the walk made').toBe(true)
    return true
  }
  const tiny = (dir, body) => {
    rmSync(join(dir, 'tests'), { recursive: true, force: true })
    if (body === null) return
    mkdirSync(join(dir, 'tests'), { recursive: true })
    writeFileSync(join(dir, 'tests', 'a.test.mjs'), body)
  }
  const passing = "import { it, expect } from 'vitest'\nit('holds', () => expect(1).toBe(1))\n"

  it('fails by name when it runs fewer copies than it says', () => {
    if (skips()) return
    const found = walk(2, { plant: (dir, n) => tiny(dir, n === 1 ? passing : null) })
    expect(found).toContain('the walk ran 1 of 2 counts')
  })

  it('fails by name when a test file in a copy does not load', () => {
    if (skips()) return
    const found = walk(2, { plant: (dir, n) => tiny(dir, n === 1 ? passing : "import './gone.mjs'\n" + passing) })
    expect(found.some((f) => /^n02 a\.test\.mjs: the file did not load: /.test(f))).toBe(true)
    expect(found.filter((f) => f.startsWith('n01 '))).toEqual([])
  })
})
