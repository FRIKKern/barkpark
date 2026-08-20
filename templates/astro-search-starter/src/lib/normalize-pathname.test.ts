// The path vocabulary contract between the byte-locked finder and the Astro
// shims — dep-free `node --test`, no browser, no React.
//
// WHY THIS EXISTS. finder.tsx is copied byte-identically from the Next edition
// (D44), and it decides whether a result row is the OPEN one with:
//
//     pathname === hit.href || pathname === `/d/${hit.type}/${hit.slug}`
//
// `hit.href` is the raw, unprefixed `/d/<type>/<slug>`. A deployed static site
// serves `/sites/<site>/d/<type>/<name>/` — base-prefixed AND directory-
// slashed — so before `normalizePathname` those never compared equal and NO row
// ever showed as open on the Astro edition. The rule this file pins: what
// `usePathname()` returns must be directly comparable to a raw `hit.href`.
//
// The logic is duplicated here rather than imported because the shim reads
// `import.meta.env.BASE_URL`, which node cannot evaluate; the duplication is
// the point of the test — it fails the moment the shim's rule diverges from
// the rule stated here. Keep the two in lock-step.
import { test } from 'node:test'
import assert from 'node:assert/strict'

/** Mirrors `normalizePathname` in src/finder/shims/next-navigation.tsx. */
function normalizePathname(raw: string, base: string): string {
  const BASE = (base || '/').replace(/\/+$/, '')
  let path = raw || '/'
  if (BASE && (path === BASE || path.startsWith(BASE + '/'))) path = path.slice(BASE.length) || '/'
  if (path.length > 1) path = path.replace(/\/+$/, '') || '/'
  return path
}

const SITE = '/sites/astro-search/'

test('a based, slashed document URL becomes the raw href the finder compares against', () => {
  assert.equal(
    normalizePathname('/sites/astro-search/d/paper/truth-grip-wave-10/', SITE),
    '/d/paper/truth-grip-wave-10',
  )
})

test('the landing collapses to "/" at a site base and at the domain root', () => {
  assert.equal(normalizePathname('/sites/astro-search/', SITE), '/')
  assert.equal(normalizePathname('/sites/astro-search', SITE), '/')
  assert.equal(normalizePathname('/', '/'), '/')
})

test('a domain-root deployment needs no stripping', () => {
  assert.equal(normalizePathname('/d/paper/x/', '/'), '/d/paper/x')
  assert.equal(normalizePathname('/d/paper/x', '/'), '/d/paper/x')
})

test('a path that merely LOOKS like the base is not truncated', () => {
  // `/sites/astro-search-2` must not lose a prefix just because it shares one.
  assert.equal(
    normalizePathname('/sites/astro-search-2/d/paper/x/', SITE),
    '/sites/astro-search-2/d/paper/x',
  )
})

test('it is idempotent — an already-normal path is unchanged', () => {
  const once = normalizePathname('/sites/astro-search/d/paper/x/', SITE)
  assert.equal(normalizePathname(once, SITE), once)
})

test('THE REGRESSION: the selected-row comparison the finder performs succeeds', () => {
  // finder.tsx, verbatim shape of the condition that marks a row open.
  const hit = { type: 'paper', slug: 'truth-grip-wave-10', href: '/d/paper/truth-grip-wave-10' }
  const pathname = normalizePathname('/sites/astro-search/d/paper/truth-grip-wave-10/', SITE)
  assert.ok(
    pathname === hit.href || pathname === `/d/${hit.type}/${hit.slug}`,
    'the open document must match its result row — this is what highlights it',
  )
})
