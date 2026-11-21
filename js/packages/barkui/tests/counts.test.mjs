// The walk of every part count (tests/counts.mjs) is not one of the fast tests, so these hold what makes it run: the
// package script, CI's step, and the rule that decides when a pull request needs it.
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { WALK_SECONDS, walkNeeded } from './counts.mjs'

const repo = (p) => new URL(`../../../../${p}`, import.meta.url)

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

  it('is one package script, which CI runs after the fast tests, on main always and on a pull request since its base', () => {
    expect(JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).scripts['test:counts']).toBe('node tests/counts.mjs')
    const wf = readFileSync(repo('.github/workflows/js-tests.yml'), 'utf8')
    const step = wf.slice(wf.indexOf('- name: "BarkUI: the fast tests hold at every part count"'))
    expect(step.length < wf.length).toBe(true)
    const body = step.slice(0, step.indexOf('\n      - name:', 1) > 0 ? step.indexOf('\n      - name:', 1) : undefined)
    expect(body).toMatch(/timeout-minutes: \d+/)
    expect(Number(body.match(/timeout-minutes: (\d+)/)[1]) * 60).toBeGreaterThan(WALK_SECONDS)
    expect(body).toContain('pnpm --filter @barkpark/barkui run test:counts --since "origin/${{ github.base_ref }}"')
    expect(body).toMatch(/else\n\s+pnpm --filter @barkpark\/barkui run test:counts\n/)
    expect(wf.indexOf('run: pnpm exec turbo run test ${{ steps.scope.outputs.filter }}')).toBeLessThan(wf.indexOf(body))
  })
})
