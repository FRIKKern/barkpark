// The walk of every part count (tests/counts.mjs) is not one of the fast tests, so these hold what makes it run: the
// package script, CI's step, and the rule that decides when a pull request needs it.
import { execFileSync, spawnSync } from 'node:child_process'
import { cpSync, globSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { load } from 'js-yaml'
import { describe, expect, it } from 'vitest'
import config from '../vitest.config.ts'
import { main, walk, WALK_SECONDS, walkInclude, walkNeeded } from './counts.mjs'

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
const pkgDir = fileURLToPath(new URL('..', import.meta.url))

// The step as YAML reads it: the pin's own step, so the fields have one source.
const PINNED = load(STEP.replace(/^ {6}/gm, ''))[0]
const FAST = 'pnpm exec turbo run test ${{ steps.scope.outputs.filter }}'

/** What is wrong with the walk step in a js-tests.yml, read as YAML, one sentence each; empty when it holds. The step
    is found by its name across every job: there is one, in the test job, after the fast tests; the job has no if and
    no continue-on-error; the step has the pinned fields and no others, and its run text is the pinned one. */
function stepFindings(text) {
  const jobs = Object.entries(load(text).jobs ?? {})
  const at = jobs.flatMap(([job, j]) => (j.steps ?? []).flatMap((st, i) => (st?.name === PINNED.name ? [{ job, j, st, i }] : [])))
  if (at.length !== 1) return [`the walk step is in ${at.length} places in js-tests.yml; it must be in exactly one`]
  const [{ job, j, st, i }] = at
  const found = []
  if (job !== 'test') found.push(`the walk step is in the job ${job}, not in test`)
  for (const k of ['if', 'continue-on-error']) if (k in j) found.push(`the job ${job} carries ${k}, so the walk can be turned off or let pass`)
  const extra = Object.keys(st).filter((k) => !(k in PINNED))
  if (extra.length) found.push(`the walk step carries ${extra.join(', ')}, beyond ${Object.keys(PINNED).join(', ')}`)
  for (const k of Object.keys(PINNED)) if (st[k] !== PINNED[k]) found.push(`the walk step's ${k} is not the pinned one`)
  const fast = (j.steps ?? []).findIndex((x) => x?.run === FAST)
  if (fast < 0 || fast > i) found.push(`the fast tests do not run before the walk step in the job ${job}`)
  return found
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
    expect(stepFindings(wf)).toEqual([])
    // YAML drops comments, so the comment above the step is held as text: the block from the blank line above the
    // comment to the first blank line after the step is the pin, byte for byte.
    const at = wf.indexOf(`      - name: "${PINNED.name}"\n`)
    const block = wf.slice(wf.lastIndexOf('\n\n', at) + 2, wf.indexOf('\n\n', at) + 1)
    expect(block, 'The BarkUI walk step in .github/workflows/js-tests.yml, or the comment above it, is not the pinned text. If the change is on purpose, change STEP in js/packages/barkui/tests/counts.test.mjs to match, in the same change.').toBe(STEP)
    expect(PINNED['timeout-minutes'] * 60).toBeGreaterThan(WALK_SECONDS)
  })

  it('names each way the step or its job can be turned off, let pass or moved', () => {
    const wf = readFileSync(repo('.github/workflows/js-tests.yml'), 'utf8')
    const head = `      - name: "${PINNED.name}"\n`
    const once = (s, a, b) => (expect(s.split(a).length, a).toBe(2), s.replace(a, b))
    // The end of the test job: the start of the next job's header.
    const end = (s) => {
      const next = /\n  [\w-]+:\n/g
      next.lastIndex = s.indexOf('\n  test:\n') + 1
      return next.exec(s).index + 1
    }
    const after = (s, line) => s.slice(0, end(s)) + line + s.slice(end(s))
    const own = (s) => {
      const a = s.indexOf(head)
      const [from, to] = [s.lastIndexOf('\n\n', a) + 2, s.indexOf('\n\n', a) + 1]
      const rest = s.slice(0, from) + s.slice(to + 1)
      const job = `  barkui-walk:\n    if: false\n    needs: test\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v7\n\n${s.slice(from, to)}\n`
      return after(rest, job)
    }
    const plants = {
      'S1 an if on the step': [once(wf, head, `${head}        if: false\n`), 'the walk step carries if, beyond name, timeout-minutes, run'],
      'S2 continue-on-error on the step': [once(wf, head, `${head}        continue-on-error: true\n`), 'the walk step carries continue-on-error, beyond name, timeout-minutes, run'],
      'S3 a pass-anyway tail': [once(wf, 'test:counts\n          fi\n', 'test:counts\n          fi || true\n'), "the walk step's run is not the pinned one"],
      'S5 an if on the test job, before its steps': [once(wf, '\n  test:\n', '\n  test:\n    if: false\n'), 'the job test carries if, so the walk can be turned off or let pass'],
      'S6 continue-on-error on the test job, before its steps': [once(wf, '\n  test:\n', '\n  test:\n    continue-on-error: true\n'), 'the job test carries continue-on-error, so the walk can be turned off or let pass'],
      'S7 an if on the test job, after its steps': [after(wf, '    if: false\n\n'), 'the job test carries if, so the walk can be turned off or let pass'],
      'S8 continue-on-error on the test job, after its steps': [after(wf, '    continue-on-error: true\n\n'), 'the job test carries continue-on-error, so the walk can be turned off or let pass'],
      'S9 the step moved whole into a job of its own': [own(wf), 'the walk step is in the job barkui-walk, not in test'],
      'a second copy of the step': [once(wf, head, `      - name: "${PINNED.name}"\n        run: "true"\n${head}`), 'the walk step is in 2 places in js-tests.yml; it must be in exactly one'],
    }
    for (const [name, [text, red]] of Object.entries(plants)) {
      expect(text, name).not.toBe(wf)
      expect(stepFindings(text), name).toContain(red)
    }
  })

  // The command line itself, run as CI runs it, with nothing passed in: a scratch repo holds the walk's own files at
  // their place, and its commits are the changes. The scratch package has no node_modules, so a walk there stops at
  // once; the row reads only whether the command skipped. C1 and C2 plant a plain diff, with renames on, into main or
  // into the command line, and the move out of the package then skips: the row would be red on either.
  it('reads the changed files through changedSince with --since, walks when they need it, and always walks without it', () => {
    const root = mkdtempSync(join(tmpdir(), 'barkui-counts-cli-'))
    try {
      const git = (...a) => execFileSync('git', ['-C', root, '-c', 'user.name=t', '-c', 'user.email=t@t', ...a], { encoding: 'utf8' })
      const put = (f, body) => (mkdirSync(join(root, dirname(f)), { recursive: true }), writeFileSync(join(root, f), body))
      const at = join(root, 'js/packages/barkui')
      git('init', '-q', '-b', 'main')
      put('js/packages/barkui/docs/PARTS.md', 'The part folder and the check.\n'.repeat(20))
      put('js/packages/core/src/index.ts', 'export {}\n')
      git('add', '-A')
      git('commit', '-q', '-m', 'base')
      // The walk's code, as files of the scratch package that no commit holds, so the diffs never see them.
      for (const d of ['tests', 'check']) cpSync(join(pkgDir, d), join(at, d), { recursive: true })
      writeFileSync(join(at, 'package.json'), readFileSync(join(pkgDir, 'package.json')))
      const code = readFileSync(join(pkgDir, 'tests/counts.mjs'), 'utf8')
      const cli = (args, src = code) => {
        writeFileSync(join(at, 'tests/counts.mjs'), src)
        const r = spawnSync(process.execPath, [join(at, 'tests/counts.mjs'), ...args], { cwd: root, encoding: 'utf8' })
        return r.status === 0 && r.stdout.includes('counts: skipped') ? 'skipped' : r.status !== 0 && !r.stdout.includes('skipped') ? 'walked' : `unclear: ${r.status} ${r.stdout}`
      }
      // A change only in another package: skipped. A file of this package moved out of it: walked.
      put('js/packages/core/src/index.ts', 'export const a = 1\n')
      git('commit', '-q', '-am', 'core only')
      expect(cli(['--since', 'HEAD~1'])).toBe('skipped')
      git('mv', 'js/packages/barkui/docs/PARTS.md', 'js/packages/core/zz-PARTS.md')
      git('commit', '-q', '-m', 'move out')
      expect(cli(['--since', 'HEAD~1'])).toBe('walked')
      // A ref that cannot be read walks; no --since always walks.
      expect(cli(['--since', 'no-such-ref'])).toBe('walked')
      expect(cli([])).toBe('walked')
      // C1 and C2: a plain diff in main, or a command line around main, skips the move. The row above is red on both.
      const plain = "execFileSync('git', ['-C', repoRoot, 'diff', '--name-only', `${ref}...HEAD`], { encoding: 'utf8' }).split('\\n')"
      const c1 = code.replace('files = changedSince(ref)\n', `files = ${plain}\n`)
      const c2 = code.replace('process.exit(main(process.argv.slice(2)))', `{ const ref = process.argv[3]; process.exit(ref && !walkNeeded(${plain}) ? (console.log('counts: skipped'), 0) : main(process.argv.slice(2))) }`)
      for (const [name, src] of Object.entries({ C1: c1, C2: c2 })) {
        expect(src, name).not.toBe(code)
        expect(cli(['--since', 'HEAD~1'], src), name).toBe('skipped')
      }
      expect(main([], { walkAll: () => ['n02 a.test.mjs: x: y'], log: () => {} })).toBe(1)
      expect(main([], { walkAll: () => [], log: () => {} })).toBe(0)
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
  }, 60000)

  it('fails by name when a test file in a copy does not load', () => {
    if (skips()) return
    const found = walk(2, { plant: (dir, n) => tiny(dir, n === 1 ? passing : "import './gone.mjs'\n" + passing) })
    expect(found.some((f) => /^n02 a\.test\.mjs: the file did not load: /.test(f))).toBe(true)
    expect(found.filter((f) => f.startsWith('n01 '))).toEqual([])
  }, 60000)
})
