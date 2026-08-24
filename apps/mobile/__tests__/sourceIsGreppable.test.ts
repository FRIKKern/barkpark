// A source file that carries a raw NUL byte is BINARY to plain grep, and plain
// grep answers such a file with silence - not an error, not a warning, just no
// matches for symbols that are demonstrably there.
//
// MEASURED, not theorised. At c72daa6fdf `apps/mobile/src/state/cache.ts` held
// five NUL bytes (a composite-key separator, written as a literal). On that
// tree:
//
//   $ grep -c PAPER_CACHE_CAP apps/mobile/src/state/cache.ts
//   $ echo $?
//   1
//   $ git grep -c PAPER_CACHE_CAP -- apps/mobile/src/state/cache.ts
//   apps/mobile/src/state/cache.ts:4
//
// It was the only such file among the 180 tracked under apps/. `git grep` and
// anything reading bytes through git are immune - which is exactly why it
// survived: the repo own drift sweeps could see the file (tooling/doc-truth
// pinned that immunity in #13682) while every ad-hoc `grep -rn` typed at this
// tree skipped it without saying so. The invisibility is asymmetric, so no
// gate that reads THROUGH git can ever catch it. This one reads the bytes.
//
// THE RULE: express the character as the escape `\u0000` - identical at
// runtime, and the file stays text.
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

/** apps/mobile, derived from this file own location rather than cwd - jest
 * may be invoked from the repo root or from the app. */
const APP_ROOT = join(__dirname, '..')

/** The character itself, as an escape - never as a literal, or this file
 * would be the second offender its own scan reports. */
const NUL_CHAR = '\u0000'

const SCAN_DIRS = ['src', '__tests__', 'scripts']
const SKIP_DIRS = new Set(['node_modules', '.expo', 'dist', 'build'])

function walk(dir: string, out: string[]): string[] {
  for (const entry of readdirSync(dir)) {
    if (SKIP_DIRS.has(entry)) continue
    const full = join(dir, entry)
    if (statSync(full).isDirectory()) walk(full, out)
    else out.push(full)
  }
  return out
}

function sourceFiles(): string[] {
  const out: string[] = []
  for (const d of SCAN_DIRS) walk(join(APP_ROOT, d), out)
  return out
}

describe('apps/mobile source stays visible to plain grep', () => {
  // The scan is only worth anything if it actually reached the tree. A readdir
  // that silently found nothing would make the assertion below vacuously true
  // - the precise shape of failure this whole file exists to name.
  it('scans a non-trivial corpus, including the file this rule came from', () => {
    const files = sourceFiles()
    expect(files.length).toBeGreaterThan(50)
    expect(files.map((f) => relative(APP_ROOT, f))).toContain('src/state/cache.ts')
  })

  it('contains no raw NUL byte in any scanned file', () => {
    // Read as TEXT, not as bytes: a NUL byte decodes to U+0000 under UTF-8, so
    // the string test is exact - and it keeps this suite inside the three
    // functions __tests__/nodeApi.d.ts declares. Reaching for Buffer would
    // mean taking @types/node (a lockfile change, and a whole ambient Node
    // surface over APP code that must never touch it) to find a character the
    // decoded string already holds.
    const offenders = sourceFiles()
      .filter((f) => readFileSync(f, 'utf8').includes(NUL_CHAR))
      .map((f) => relative(APP_ROOT, f))
    expect(offenders).toEqual([])
  })

  // The detector itself, proven on a byte handed to it rather than on the tree
  // - a scan that could not recognise a NUL would report an empty offender
  // list forever and read exactly like a pass.
  it('the NUL detector fires on text that has one', () => {
    expect('a\u0000b'.includes(NUL_CHAR)).toBe(true)
    expect('ab'.includes(NUL_CHAR)).toBe(false)
  })
})
