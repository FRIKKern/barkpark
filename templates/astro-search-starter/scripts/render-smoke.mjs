#!/usr/bin/env node
// render-smoke.mjs — does the finder island actually RENDER, and keep rendering
// while somebody types?
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS (task-3b60cf7c4fc6bd04)
// ─────────────────────────────────────────────────────────────────────────────
//  The Astro flagship had two gates over its finder and NEITHER could open it:
//
//    scripts/parity-check.mjs   compares query RESULT SETS off the HTTP route.
//                               It never loads a page. A client render crash is
//                               invisible to it — the route still answers 200
//                               with the right ids while the island is a blank
//                               rail.
//    astro-search-finder-test   `node --test` over React-free contract specs
//    .yml                       (seed shape, prefix lookup). Its own header says
//                               "Dep-free: no npm ci, no browser."
//
//  That is exactly how the blank-on-keystroke bug (task-9e95a835863d6363, a
//  TypeError in the prefix index) shipped GREEN: the query results were perfect
//  and the page went empty the moment a visitor typed. Both existing gates were
//  correct AND blind, at the same time, about the same commit.
//
//  This harness is the eye. It builds the site, serves it, opens it in headless
//  chromium, types, and asserts what a human would see.
//
// ─────────────────────────────────────────────────────────────────────────────
//  THE FOUR BEATS
// ─────────────────────────────────────────────────────────────────────────────
//    LAND    the island hydrates: >=1 [data-nav-result] row, no
//            [data-search-error] banner.
//    ONE     a ONE-character query ("b"). The historic defect fired on the FIRST
//            keystroke, in the prefix index the one-char case is the only reader
//            of, so a smoke that starts at three characters would have watched
//            it ship. After the transition: >=1 row, still no banner.
//    MULTI   a MULTI-character query ("bark"), typed on top of it — the debounced
//            HTTP path, a second transition over an already-rendered list.
//            After it: >=1 row, still no banner.
//    CLEAN   ZERO uncaught pageerrors and ZERO console errors across all three.
//            This is the beat the FinderErrorBoundary makes necessary: it
//            catches a throw and paints an on-brand fallback, so a page that
//            crashed does not look crashed. React reports the caught error to
//            console.error, and the rows go away — this beat and the row
//            assertions above catch the same defect from two sides.
//
//  A beat is PASS or FAIL. There is no PENDING: every beat's prerequisite is the
//  beat above it, and a prerequisite failure aborts — reporting "could not be
//  proven" as anything but a failure is how a gate goes quietly vacuous.
//
// ─────────────────────────────────────────────────────────────────────────────
//  SAME-ORIGIN, WITH A STUB (the choice this harness makes, and why)
// ─────────────────────────────────────────────────────────────────────────────
//  The island rewrites its Next-era `/api/find` calls to
//  `<ORIGIN>/v1/data/search/:dataset`, where ORIGIN is BAKED AT BUILD from
//  BARKPARK_API_URL. So "same-origin" is not a proxy trick here — it is achieved
//  by building against the very origin that will also serve `dist/`. One
//  loopback server answers both. See scripts/smoke-stub-api.mjs for why the API
//  half is canned rather than proxied to a live instance (short version: this
//  gate must say ONE thing, about the diff, every time; parity-check.mjs is the
//  instrument that owns the live-contract claim, and it still does).
//
// ─────────────────────────────────────────────────────────────────────────────
//  RUN
// ─────────────────────────────────────────────────────────────────────────────
//    node scripts/render-smoke.mjs                  # build, serve, smoke
//    node scripts/render-smoke.mjs --no-build       # reuse an existing dist/
//    node scripts/render-smoke.mjs --port 4319
//    BP_PLAYWRIGHT=/path/to/node_modules/playwright node scripts/render-smoke.mjs
//
//  EXIT CODES
//    0  every beat passed
//    1  a beat FAILED — the finder is broken (this is the finding)
//    2  CANNOT MEASURE — no playwright, no chromium, the build failed, the port
//       was taken. Deliberately NOT 1: an environment that cannot run the gate
//       must never be reported as a defect in somebody's diff, and must never be
//       reported as a pass either.
import { spawn } from 'node:child_process'
import { createRequire } from 'node:module'
import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createStubServer, listen } from './smoke-stub-api.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const TEMPLATE = resolve(HERE, '..')
const REPO = resolve(TEMPLATE, '..', '..')

const ONE_CHAR = 'b'
const MULTI_CHAR = 'bark'
const NAV_TIMEOUT = 30_000
// The stub is on loopback with a canned corpus, so a keystroke's round trip is
// milliseconds. This budget is not for slowness — it is how long the harness
// waits before concluding the request WAS NEVER SENT, which is what a crashed
// island looks like from outside.
const QUERY_TIMEOUT = 10_000
const SETTLE_MS = 400

function parseArgs(argv) {
  const a = { port: 4319, build: true }
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--port': a.port = Number(argv[++i]); break
      case '--no-build': a.build = false; break
      case '-h': case '--help': a.help = true; break
      default:
        console.error(`render-smoke: unknown argument ${argv[i]}`)
        process.exit(64)
    }
  }
  return a
}

function die(code, msg) {
  console.error(`\nrender-smoke: ${msg}`)
  process.exit(code)
}

/**
 * Find playwright without adding it to this template's package.json.
 *
 * Deliberate: templates/astro-search-starter/package.json IS the file a user
 * copies to start a site, and a browser-automation devDependency in it would
 * ship a 100MB download to every person who scaffolds a search site in order to
 * gate a defect in OUR repo. So the dependency lives where the runner puts it,
 * and this resolves it over four routes, in order of explicitness.
 */
function loadPlaywright() {
  const req = createRequire(import.meta.url)
  const candidates = [
    process.env.BP_PLAYWRIGHT,
    // The repo's own js monorepo already installs playwright (js-tests.yml
    // caches its chromium) — reuse it locally rather than making a developer
    // install a second copy.
    join(REPO, 'js', 'node_modules', 'playwright'),
  ].filter(Boolean)
  for (const c of candidates) {
    try {
      return req(c)
    } catch {
      /* next route */
    }
  }
  try {
    return req('playwright')
  } catch {
    /* last route: a global install (what CI does) */
  }
  try {
    const root = process.env.NPM_CONFIG_PREFIX
      ? join(process.env.NPM_CONFIG_PREFIX, 'lib', 'node_modules')
      : null
    if (root) return req(join(root, 'playwright'))
  } catch {
    /* fall through to the honest refusal below */
  }
  return null
}

function run(cmd, args, opts) {
  return new Promise((res) => {
    const p = spawn(cmd, args, { stdio: 'inherit', ...opts })
    p.on('close', (code) => res(code ?? 1))
    p.on('error', () => res(127))
  })
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  if (args.help) {
    console.log('node scripts/render-smoke.mjs [--port N] [--no-build]')
    return 0
  }

  const playwright = loadPlaywright()
  if (!playwright) {
    die(
      2,
      'CANNOT MEASURE — playwright is not resolvable.\n' +
        '  Set BP_PLAYWRIGHT=<dir>/node_modules/playwright, or install it globally\n' +
        '  (npm i -g playwright && npx playwright install chromium).',
    )
  }

  const distDir = join(TEMPLATE, 'dist')
  const origin = `http://127.0.0.1:${args.port}`
  const unknown = new Set()
  const server = createStubServer({ distDir, onUnknown: (r) => unknown.add(r) })
  try {
    await listen(server, args.port)
  } catch (e) {
    die(2, `CANNOT MEASURE — port ${args.port} is not bindable (${e.code || e.message}).`)
  }
  console.log(`render-smoke: stub API + static host on ${origin}`)

  const buildEnv = {
    ...process.env,
    // THE same-origin knob. Everything the island fetches at runtime is derived
    // from this at build time.
    BARKPARK_API_URL: origin,
    BARKPARK_DATASET: 'smoke',
    BARKPARK_DOC_TYPE: 'entry',
    BARKPARK_WORKSPACE: 'default',
    BARKPARK_PROJECT: 'default',
    // No token: the live-search WebSocket stays dark on purpose. The socket is
    // journey-smoke.mjs's beat (it asserts it AT THE TRANSPORT against a real
    // deploy); here it would only add a second, flakier way to reach the same
    // rows, and the HTTP path is the one every anonymous visitor rides.
    BARKPARK_TOKEN: '',
    BARKPARK_SITE_BASE: '',
    BARKPARK_BUILD_ID: 'render-smoke',
    BARKPARK_CONTENT_REV: 'render-smoke',
  }

  if (args.build) {
    if (!existsSync(join(TEMPLATE, 'node_modules', 'astro'))) {
      server.close()
      die(2, 'CANNOT MEASURE — templates/astro-search-starter/node_modules is absent; run `npm ci` there first.')
    }
    console.log('render-smoke: astro build (against the stub) …')
    const code = await run('npx', ['--no-install', 'astro', 'build'], {
      cwd: TEMPLATE,
      env: buildEnv,
    })
    if (code !== 0) {
      server.close()
      die(2, `CANNOT MEASURE — astro build exited ${code}.`)
    }
  } else if (!existsSync(join(distDir, 'index.html'))) {
    server.close()
    die(2, 'CANNOT MEASURE — --no-build was given but dist/index.html does not exist.')
  }

  // ── the browser ───────────────────────────────────────────────────────────
  let browser
  try {
    browser = await playwright.chromium.launch({ headless: true })
  } catch (e) {
    server.close()
    die(2, `CANNOT MEASURE — chromium would not launch (${e.message.split('\n')[0]}).\n  Try: npx playwright install chromium`)
  }
  // 1280x900 is above the finder's `md` breakpoint, so this is the FULL desktop
  // composition — rail plus the portalled corpus graph. The graph is not
  // asserted here (journey-smoke owns it), but it MOUNTS, so a throw inside it
  // still reaches the CLEAN beat rather than hiding behind a narrow viewport.
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } })
  const page = await ctx.newPage()

  const errors = []
  const ignored = []
  /** A resource 404 for a favicon is chrome, not the finder. It is the ONE
   * allowance, it is named, and it is PRINTED — an allowance you cannot see is
   * the same thing as no assertion. */
  const isIgnorable = (text) => /favicon\.ico/.test(text)
  const note = (kind, text) => {
    const line = `${kind}: ${text}`
    if (isIgnorable(line)) ignored.push(line)
    else errors.push(line)
  }
  page.on('pageerror', (e) => note('pageerror', e.stack || e.message))
  page.on('console', (m) => {
    if (m.type() === 'error') note('console.error', m.text())
  })
  page.on('requestfailed', (r) => {
    const f = r.failure()
    note('requestfailed', `${r.url()} (${f ? f.errorText : 'unknown'})`)
  })

  const beats = []
  const record = (name, ok, detail) => {
    beats.push({ name, ok, detail })
    console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`)
    return ok
  }

  const rows = () => page.locator('[data-nav-result]')
  const banner = () => page.locator('[data-search-error]')

  async function state() {
    return { rows: await rows().count(), banner: await banner().count() }
  }

  /** Type into the finder and WAIT FOR THE TRANSPORT, not for a timer. The
   * island's fetch interceptor turns the finder's `/api/find` call into a real
   * network request to the stub, so the response for THIS query is an
   * observable event — waiting on it instead of sleeping is what keeps the gate
   * from flaking on a slow runner. */
  async function type(q) {
    const wait = page
      .waitForResponse(
        (r) => {
          try {
            const u = new URL(r.url())
            return u.pathname.startsWith('/v1/data/search/') && u.searchParams.get('q') === q
          } catch {
            return false
          }
        },
        { timeout: QUERY_TIMEOUT },
      )
      .then(() => true)
      // A MISSING request is a FINDING, not a harness fault, and it must be
      // reported by the beat that asked for it rather than as a crash in the
      // driver. When the island throws on the first keystroke it never issues
      // the query at all — swallowing the timeout here is what lets the ONE
      // beat below say `transport=no rows=0` instead of the whole run dying
      // with a Playwright stack trace that names no beat.
      .catch(() => false)
    try {
      await page.fill('#finder-search', q)
    } catch {
      return { transport: false, typed: false }
    }
    const transport = await wait
    // The response landed; React still has to commit. A short settle is honest
    // here — there is no DOM event for "the list you are about to draw".
    await page.waitForTimeout(SETTLE_MS)
    return { transport, typed: true }
  }

  let failed = false
  try {
    console.log(`render-smoke: opening ${origin}/`)
    await page.goto(`${origin}/`, { waitUntil: 'load', timeout: NAV_TIMEOUT })
    // client:only — nothing is server-rendered, so the first row IS hydration.
    try {
      await rows().first().waitFor({ state: 'attached', timeout: NAV_TIMEOUT })
    } catch {
      /* the LAND beat below reports it */
    }
    let s = await state()
    failed = !record('LAND   island hydrates with results', s.rows > 0 && s.banner === 0, `rows=${s.rows} errorBanner=${s.banner}`) || failed

    for (const [beat, q] of [['ONE  ', ONE_CHAR], ['MULTI', MULTI_CHAR]]) {
      const label = `${beat}  ${q.length === 1 ? 'one' : 'multi'}-character query "${q}" keeps rows`
      if (failed) {
        record(label, false, 'aborted: an earlier beat failed')
        continue
      }
      const t = await type(q)
      s = await state()
      const ok = t.typed && t.transport && s.rows > 0 && s.banner === 0
      failed =
        !record(
          label,
          ok,
          `typed=${t.typed ? 'yes' : 'no'} transport=${t.transport ? 'yes' : 'NO REQUEST'} rows=${s.rows} errorBanner=${s.banner}`,
        ) || failed
    }
  } catch (e) {
    record('DRIVE  the browser could drive the page', false, e.message.split('\n')[0])
    failed = true
  }

  failed = !record('CLEAN  zero page/console errors', errors.length === 0, `${errors.length} error(s)`) || failed

  await browser.close()
  server.close()

  if (ignored.length) {
    console.log(`\nignored (named allowance — favicon only): ${ignored.length}`)
    for (const l of ignored) console.log(`  · ${l}`)
  }
  if (errors.length) {
    console.log('\nerrors:')
    for (const l of errors) console.log(`  · ${l}`)
  }
  if (unknown.size) {
    console.log('\nstub answered these /v1 paths generically (extend smoke-stub-api.mjs if one matters):')
    for (const l of unknown) console.log(`  · ${l}`)
  }

  const passed = beats.filter((b) => b.ok).length
  console.log(`\nrender-smoke: ${passed}/${beats.length} beats passed`)
  return failed ? 1 : 0
}

main().then(
  (code) => process.exit(code),
  (e) => {
    console.error(e)
    process.exit(2)
  },
)
