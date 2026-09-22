#!/usr/bin/env node
// graph-smoke.mjs — is the desktop corpus graph actually RENDERED, and is a
// phone actually sent NOTHING of it? Asked of the BUILT site, in a real browser.
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS (task-eb8cd26d8d8d171c, criterion 0)
// ─────────────────────────────────────────────────────────────────────────────
//  The Astro edition got this eye first
//  (templates/astro-search-starter/scripts/render-smoke.mjs, PR #18872). This
//  edition — the Next flagship the deploy engine actually ships — had none. Its
//  only browser coverage was the live journey harness, whose phone arm keys on
//  `#bp-graph-slot`: a selector the Astro edition has and THIS one does not,
//  because Next mounts <GraphView> directly. So on Next the structural half
//  passed VACUOUSLY — "the pane is not mounted" was trivially true of a page
//  that has no such pane at ANY width — while the desktop control failed a
//  graph that worked. A beat that cannot fail is not a beat.
//
//  Both editions' canvas host now carries `data-bp-graph-mount` (present iff
//  the graph subtree rendered), so the same claim can be asked of both in the
//  same words, off each edition's own build.
//
// ─────────────────────────────────────────────────────────────────────────────
//  THE BEATS
// ─────────────────────────────────────────────────────────────────────────────
//    LAND    the built site answers and the finder rail hydrates: >=1
//            [data-nav-result] row. This is the beat that fails when the BUILD
//            is broken rather than the graph — without it every graph claim
//            below could be satisfied by a blank page, which is the "green with
//            no subject" failure this harness exists to avoid.
//    GDESK   1440x900 CONTROL — `/bp-graph.js` IS fetched AND
//            `[data-bp-graph-mount]` IS in the DOM. Without this control the
//            two phone claims below are satisfied perfectly by a graph that is
//            broken at every width, or deleted outright.
//    GWIDTH  CONTROL — the two arms really were different viewports. A harness
//            that silently ran both contexts at one width would report the
//            phone claims about a desktop page (or vice versa) and never say so.
//    GPHONE  390x844 — ZERO requests matching /bp-graph\.js|graph\.json/.
//            HIDDEN IS NOT UNDELIVERED: `app/(finder)/page.tsx` wraps the pane
//            in `hidden md:block` AND in <DesktopOnly>, and only the second one
//            is load-bearing — `display:none` stops PAINT, not a mount effect
//            appending <script src="/bp-graph.js">. Drop <DesktopOnly> and the
//            CSS still hides the pane while ~131 KB of renderer ships to a
//            phone that can never see it. That is the regression this beat owns.
//    GMOUNT  390x844 — no `[data-bp-graph-mount]` in the DOM. The transport
//            claim and the DOM claim catch the same defect from two sides: a
//            future cached/inlined renderer would defeat GPHONE alone.
//    CLEAN   ZERO uncaught pageerrors and ZERO console errors across both arms.
//            A React error boundary paints an on-brand fallback, so a crashed
//            page does not look crashed; console.error is where it says so.
//
//  A beat is PASS or FAIL. There is no PENDING: LAND is every other beat's
//  prerequisite and a LAND failure aborts them as FAIL — reporting "could not be
//  proven" as anything but a failure is how a gate goes quietly vacuous.
//
// ─────────────────────────────────────────────────────────────────────────────
//  THE ARMS THAT PROVE IT MEASURES (run before shipping; re-run when in doubt)
// ─────────────────────────────────────────────────────────────────────────────
//    remove the desktop graph   — delete the <GraphLanding> subtree from
//                                 app/(finder)/page.tsx, or make <DesktopOnly>
//                                 render null unconditionally
//                                 → GDESK FAILS (no /bp-graph.js, no mount)
//    remove the phone gate      — drop <DesktopOnly> so the pane mounts at every
//                                 width
//                                 → GPHONE and GMOUNT FAIL (renderer delivered
//                                   to a 390px viewport that cannot show it)
//  Both arms were run against this harness; neither can be satisfied by a page
//  the browser never loaded, because LAND asserts the page loaded first.
//
// ─────────────────────────────────────────────────────────────────────────────
//  TWO ORIGINS, ON PURPOSE
// ─────────────────────────────────────────────────────────────────────────────
//  `scripts/smoke-stub-api.mjs` answers `/v1/...` on one loopback port; the
//  BUILT standalone server (`.next/standalone/server.js`, the very artifact
//  `deploy/site-deploy-node.sh` boots per slot) answers the site on another.
//  That split is what makes the delivery claim readable: `/bp-graph.js` is a
//  request to the SITE, so its presence or absence is a fact about the built
//  output, not about the fixture.
//
// ─────────────────────────────────────────────────────────────────────────────
//  RUN
// ─────────────────────────────────────────────────────────────────────────────
//    node scripts/graph-smoke.mjs                 # build, serve, smoke
//    node scripts/graph-smoke.mjs --no-build      # reuse an existing .next/
//    node scripts/graph-smoke.mjs --port 4421 --api-port 4420
//    BP_PLAYWRIGHT=/path/to/node_modules/playwright node scripts/graph-smoke.mjs
//
//  EXIT CODES
//    0  every beat passed
//    1  a beat FAILED — this is the finding
//    2  CANNOT MEASURE — no playwright, no chromium, the build failed, a port
//       was taken. Deliberately NOT 1: an environment that cannot run the gate
//       must never be reported as a defect in somebody's diff, and must never be
//       reported as a pass either.
import { spawn } from 'node:child_process'
import { createServer } from 'node:net'
import { createRequire } from 'node:module'
import { cp, rm } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createStubServer, listen } from './smoke-stub-api.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const TEMPLATE = resolve(HERE, '..')
const REPO = resolve(TEMPLATE, '..', '..')

const NAV_TIMEOUT = 30_000
const SERVER_BOOT_TIMEOUT = 60_000
/** The renderer is served from loopback, so this budget is not for slowness —
 * it is how long the harness waits before concluding the request WAS NEVER
 * SENT, which is what a missing desktop graph looks like from outside. */
const GRAPH_SETTLE_CAP = 8_000

/** The wire signature of graph delivery. `bp-graph.js` is the renderer this
 * template ships in `public/`; `graph.json` is the Astro edition's baked corpus
 * asset — matched here too so the two editions' phone claim is spelled the same
 * way and a future corpus-asset split on this edition cannot slip through. */
const GRAPH_ASSET = /bp-graph\.js|graph\.json/
/** Selector-AGNOSTIC: `[data-bp-graph-mount]` is in the DOM iff the graph
 * subtree rendered. Both flagship editions' canvas host carries it, so this
 * beat is about THE GRAPH and not about one template's markup. */
const GRAPH_MOUNT = '[data-bp-graph-mount]'

const DESKTOP = { width: 1440, height: 900 }
const PHONE = { width: 390, height: 844 }

function parseArgs(argv) {
  const a = { port: 4421, apiPort: 4420, build: true }
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--port': a.port = Number(argv[++i]); break
      case '--api-port': a.apiPort = Number(argv[++i]); break
      case '--no-build': a.build = false; break
      case '-h': case '--help': a.help = true; break
      default:
        console.error(`graph-smoke: unknown argument ${argv[i]}`)
        process.exit(64)
    }
  }
  return a
}

function die(code, msg) {
  console.error(`\ngraph-smoke: ${msg}`)
  process.exit(code)
}

/**
 * Find playwright without adding it to this template's package.json.
 *
 * Deliberate, and the same choice the Astro edition makes:
 * templates/search-starter/package.json IS the file a user copies to start a
 * site, and a browser-automation devDependency in it would ship a ~100MB
 * download to everyone who scaffolds a search site in order to gate a defect in
 * OUR repo. So the dependency lives where the runner puts it, resolved here
 * over four routes in order of explicitness.
 */
function loadPlaywright() {
  const req = createRequire(import.meta.url)
  const candidates = [
    process.env.BP_PLAYWRIGHT,
    // The repo's own js monorepo already installs playwright (js-tests.yml
    // caches its chromium) — reuse it rather than installing a second copy.
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

/**
 * Refuse to run if the site port is ALREADY SERVING.
 *
 * THIS GUARD IS THE HARNESS'S OWN SCAR, and it is not hypothetical: the first
 * baseline run of this file printed 6/6 while `Failed to start server:
 * EADDRINUSE` scrolled past in the same output. A leftover server from an
 * earlier manual run answered `waitForHttp`, chromium drove THAT page, and
 * every beat passed having measured a build nobody had just made. A green whose
 * subject is a stale process is worse than a red.
 *
 * So the port is proven FREE before the build, and the failure is a
 * CANNOT MEASURE (2), never a pass and never a finding in somebody's diff.
 */
function portIsFree(port, host = '127.0.0.1') {
  return new Promise((res) => {
    const probe = createServer()
    probe.once('error', () => res(false))
    probe.once('listening', () => probe.close(() => res(true)))
    probe.listen(port, host)
  })
}

/** Poll the site until it answers, or give up. A fixed sleep here is how a
 * harness reports a boot failure as a page-content failure. */
async function waitForHttp(url, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(3_000) })
      if (res.status < 500) return true
    } catch {
      /* not up yet */
    }
    if (Date.now() > deadline) return false
    await new Promise((r) => setTimeout(r, 300))
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  if (args.help) {
    console.log('node scripts/graph-smoke.mjs [--port N] [--api-port N] [--no-build]')
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

  const apiOrigin = `http://127.0.0.1:${args.apiPort}`
  const siteOrigin = `http://127.0.0.1:${args.port}`
  if (!(await portIsFree(args.port))) {
    die(
      2,
      `CANNOT MEASURE — site port ${args.port} is already serving.\n` +
        '  Something else would answer the browser and every beat below would be\n' +
        `  about ITS page, not this build. Free the port (or pass --port N).`,
    )
  }

  const unknown = new Set()
  const stub = createStubServer({ onUnknown: (r) => unknown.add(r) })
  try {
    await listen(stub, args.apiPort)
  } catch (e) {
    die(2, `CANNOT MEASURE — API port ${args.apiPort} is not bindable (${e.code || e.message}).`)
  }
  console.log(`graph-smoke: stub API on ${apiOrigin}`)

  const buildEnv = {
    ...process.env,
    BARKPARK_API_URL: apiOrigin,
    BARKPARK_DATASET: 'smoke',
    BARKPARK_WORKSPACE: 'default',
    BARKPARK_PROJECT: 'default',
    // No token: the live-search WebSocket stays dark on purpose. It would only
    // add a second, flakier way to reach the same rows, and the HTTP route is
    // the one every anonymous visitor rides.
    BARKPARK_TOKEN: '',
    // Domain root, not a sub-path: basePath '' is the shape the graph beats
    // below assume when they match `/bp-graph.js` on the wire.
    BARKPARK_SITE_BASE: '',
    BARKPARK_BUILD_ID: 'graph-smoke',
    BARKPARK_CONTENT_REV: 'graph-smoke',
  }

  const standalone = join(TEMPLATE, '.next', 'standalone')
  let site
  const shutdown = () => {
    if (site && !site.killed) site.kill('SIGTERM')
    stub.close()
  }

  if (args.build) {
    if (!existsSync(join(TEMPLATE, 'node_modules', 'next'))) {
      shutdown()
      die(2, 'CANNOT MEASURE — templates/search-starter/node_modules is absent; run `npm ci` there first.')
    }
    console.log('graph-smoke: next build (against the stub) …')
    const code = await run('npx', ['--no-install', 'next', 'build'], {
      cwd: TEMPLATE,
      env: buildEnv,
    })
    if (code !== 0) {
      shutdown()
      die(2, `CANNOT MEASURE — next build exited ${code}.`)
    }
  } else if (!existsSync(join(standalone, 'server.js'))) {
    shutdown()
    die(2, 'CANNOT MEASURE — --no-build was given but .next/standalone/server.js does not exist.')
  }

  // `output: 'standalone'` traces the server and its node_modules, and copies
  // NEITHER the client chunks nor `public/`. The deploy engine stages them the
  // same way; without this the page boots and every asset — the renderer
  // included — 404s, which would make the phone claims pass for the wrong
  // reason. Removed first so a stale copy can never answer for a fresh build.
  for (const [from, to] of [
    [join(TEMPLATE, '.next', 'static'), join(standalone, '.next', 'static')],
    [join(TEMPLATE, 'public'), join(standalone, 'public')],
  ]) {
    await rm(to, { recursive: true, force: true })
    await cp(from, to, { recursive: true })
  }

  console.log(`graph-smoke: booting the BUILT standalone server on ${siteOrigin}`)
  site = spawn('node', [join(standalone, 'server.js')], {
    cwd: standalone,
    stdio: ['ignore', 'inherit', 'inherit'],
    env: { ...buildEnv, PORT: String(args.port), HOSTNAME: '127.0.0.1' },
  })
  site.on('error', () => {})
  if (!(await waitForHttp(`${siteOrigin}/`, SERVER_BOOT_TIMEOUT))) {
    shutdown()
    die(2, `CANNOT MEASURE — the built server never answered on ${siteOrigin}.`)
  }

  let browser
  try {
    browser = await playwright.chromium.launch({ headless: true })
  } catch (e) {
    shutdown()
    die(
      2,
      `CANNOT MEASURE — chromium would not launch (${e.message.split('\n')[0]}).\n` +
        '  Try: npx playwright install chromium',
    )
  }

  const beats = []
  const record = (name, ok, detail) => {
    beats.push({ name, ok, detail })
    console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`)
    return ok
  }

  const errors = []
  const ignored = []
  /** A favicon 404 is chrome, not the finder. It is the ONE allowance, it is
   * named, and it is PRINTED — an allowance you cannot see is the same thing as
   * no assertion. */
  const isIgnorable = (text) => /favicon\.ico/.test(text)
  const note = (kind, text) => {
    const line = `${kind}: ${text}`
    if (isIgnorable(line)) ignored.push(line)
    else errors.push(line)
  }

  /** A fresh context per arm: separate cache, separate network log. Reusing one
   * context would let the desktop arm's cached renderer answer the phone arm
   * from memory, and the phone beat would pass having proven nothing. */
  async function openArm(viewport) {
    const ctx = await browser.newContext({ viewport })
    const pg = await ctx.newPage()
    const hits = []
    pg.on('request', (r) => {
      if (GRAPH_ASSET.test(r.url())) hits.push(r.url())
    })
    pg.on('pageerror', (e) => note('pageerror', e.stack || e.message))
    pg.on('console', (m) => {
      if (m.type() === 'error') note('console.error', m.text())
    })
    pg.on('requestfailed', (r) => {
      const f = r.failure()
      note('requestfailed', `${r.url()} (${f ? f.errorText : 'unknown'})`)
    })
    return { ctx, pg, hits }
  }

  let failed = false
  let desk
  let phone
  try {
    desk = await openArm(DESKTOP)
    phone = await openArm(PHONE)

    await desk.pg.goto(`${siteOrigin}/`, { waitUntil: 'load', timeout: NAV_TIMEOUT })
    await phone.pg.goto(`${siteOrigin}/`, { waitUntil: 'load', timeout: NAV_TIMEOUT })

    // ── LAND ────────────────────────────────────────────────────────────────
    // The rail is the proof the BUILT page loaded and hydrated at all. Every
    // graph beat below is a statement about a page; this is the beat that says
    // there was one.
    try {
      await desk.pg.locator('[data-nav-result]').first().waitFor({ state: 'attached', timeout: NAV_TIMEOUT })
    } catch {
      /* the beat below reports it */
    }
    const rows = await desk.pg.locator('[data-nav-result]').count()
    failed = !record('LAND   the built site hydrates with finder results', rows > 0, `rows=${rows}`) || failed

    if (failed) {
      for (const n of ['GDESK  desktop CONTROL: the renderer is fetched and the pane mounts',
        'GWIDTH CONTROL: the two arms were different viewports',
        'GPHONE phone: ZERO graph assets on the wire',
        'GMOUNT phone: the graph subtree never rendered']) {
        record(n, false, 'aborted: LAND failed')
      }
    } else {
      // ── GDESK ─────────────────────────────────────────────────────────────
      // Poll rather than sleep: the mount is a client effect and the script tag
      // it appends is a real network event, so the earliest honest answer is
      // the moment BOTH appear. The cap is the budget the phone arm then waits
      // out IN FULL below, which is what makes its zero a measured zero.
      const deadline = Date.now() + GRAPH_SETTLE_CAP
      let deskMounted = 0
      for (;;) {
        deskMounted = await desk.pg.locator(GRAPH_MOUNT).count()
        if (desk.hits.length > 0 && deskMounted > 0) break
        if (Date.now() > deadline) break
        await desk.pg.waitForTimeout(200)
      }
      failed =
        !record(
          'GDESK  desktop CONTROL: the renderer is fetched and the pane mounts',
          desk.hits.length > 0 && deskMounted > 0,
          `graphRequests=${desk.hits.length} ${GRAPH_MOUNT}=${deskMounted}` +
            (desk.hits.length === 0 ? ' — nothing matching /bp-graph.js|graph.json/ was requested' : ''),
        ) || failed

      // ── GWIDTH ────────────────────────────────────────────────────────────
      const dw = await desk.pg.evaluate(() => window.innerWidth)
      const pw = await phone.pg.evaluate(() => window.innerWidth)
      failed =
        !record(
          'GWIDTH CONTROL: the two arms were different viewports',
          dw >= 768 && pw < 768,
          `desktop=${dw}px phone=${pw}px (md breakpoint 768)`,
        ) || failed

      // The phone arm waits out the FULL budget the desktop arm just validated,
      // plus a margin. A zero measured over a shorter window than the one a
      // real mount needed would be a zero about the clock, not about the page.
      await phone.pg.waitForTimeout(GRAPH_SETTLE_CAP + 1_200)

      // ── GPHONE ────────────────────────────────────────────────────────────
      failed =
        !record(
          'GPHONE phone: ZERO graph assets on the wire',
          phone.hits.length === 0,
          phone.hits.length === 0
            ? 'no /bp-graph.js|graph.json request'
            : `DELIVERED: ${phone.hits.join(', ')}`,
        ) || failed

      // ── GMOUNT ────────────────────────────────────────────────────────────
      const phoneMounted = await phone.pg.locator(GRAPH_MOUNT).count()
      failed =
        !record(
          'GMOUNT phone: the graph subtree never rendered',
          phoneMounted === 0,
          `${GRAPH_MOUNT} count=${phoneMounted}` +
            (phoneMounted > 0 ? ' — the pane MOUNTED inside a hidden box' : ''),
        ) || failed
    }
  } catch (e) {
    record('DRIVE  the browser could drive the built site', false, e.message.split('\n')[0])
    failed = true
  }

  failed = !record('CLEAN  zero page/console errors', errors.length === 0, `${errors.length} error(s)`) || failed

  await browser.close()
  shutdown()

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
  console.log(`\ngraph-smoke: ${passed}/${beats.length} beats passed`)
  return failed ? 1 : 0
}

main().then(
  (code) => process.exit(code),
  (e) => {
    console.error(e)
    process.exit(2)
  },
)
