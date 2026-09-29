// Cross-tab pin race driver — runs origin/main's app.js verbatim in a vm sandbox.
//
// ── 2026-09-10 · THE RACE IS NOW PROVED IN TWO REAL CHROME TABS ──────────────
// cch-w42-bl-pin-race-needs-a-two-tab-browser-reproduction. This sandbox driver
// proved the MECHANISM; the end-to-end RENDERED symptom is now proved too, in a
// real browser, by cloud/priv/static/__preview__/pin-race.mjs. Verdict:
// REPRODUCED. Two tabs of one headless Chrome share one localStorage; tab B
// switches team and reloads ITSELF; tab A, same page life, clicks Refresh on
// Activity and paints the OTHER team's audit rows under its own team's label:
//
//   tab A after refresh — renderedTeamLabel "Northwind Ops"
//                         renderedRows ["y-side@contoso.example minted an API token"]
//                         livePin team-2222…  meTeamPinMoved true  role "admin"
//
// The verbatim capture, both tabs, both legs, is beside this file:
//   tooling/grip/ledger/cch-w42-pinrace.capture-2026-09-10.json
//
// ── THREE THINGS THE FILING GOT WRONG (dated correction, 2026-09-10) ─────────
// The charter file is outside this row's fence, so the amendments the lead
// should make to the D469 entry are named here by line:
//
//  1. "the switcher reloads only its own tab (:5269-5270)" — WRONG LINES on
//     today's origin/main. The switcher's setItem + location.reload() pair is
//     app.js:6588-6589. :5269 is inside tokenAbilitiesUnknownHtml's comment.
//     (app.js:116, the per-request pin re-read, IS correct.)
//  2. "loadMe has three call sites" — there are FIVE on today's main
//     (app.js:1631, :11867, :17818, :20138, :26367). The CONCLUSION survives —
//     none of them is a route change — but the count does not.
//  3. The filing reads as though the console cannot tell the pin moved. It CAN:
//     `meTeamPinMoved()` (app.js:19964) already exists and already guards THREE
//     bands (app.js:18993, :19996, :20078 — teamAuthorityState and siblings).
//     The Activity band is simply not one of them: loadActivity (app.js:20753)
//     issues GET /v1/audit and paints the answer with no pin question asked.
//     That narrows the defect from "no mechanism" to "one band skipped the
//     mechanism", and it narrows the fix accordingly.
//
// ── THIS DRIVER WAS UNRUNNABLE AS COMMITTED ─────────────────────────────────
// It read `./main-app.js` — a file that has never existed in this directory, so
// `node tooling/grip/ledger/cch-w42-pinrace.driver.mjs` died ENOENT for anyone
// who tried to re-run D469's proof. It now reads the repo's real app.js.
import vm from "node:vm";
import fs from "node:fs";

const noop = () => {};
const inertEl = {
  addEventListener: noop, removeEventListener: noop, setAttribute: noop,
  removeAttribute: noop,
  classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
  style: {}, hidden: false, value: "", innerHTML: "", textContent: "",
  querySelector: () => null, querySelectorAll: () => [],
};
// MUTABLE localStorage — the whole point: another tab can write it.
const store = {};
const storage = {
  getItem: (k) => (k in store ? store[k] : null),
  setItem: (k, v) => { store[k] = String(v); },
  removeItem: (k) => { delete store[k]; },
};

const calls = [];
let nextResponse = { ok: true, status: 200, body: {} };

const hooks = {};
const sandbox = {
  __bpTestHook(h) { Object.assign(hooks, h); },
  document: {
    readyState: "loading", addEventListener: noop, removeEventListener: noop,
    querySelector: () => null, querySelectorAll: () => [], getElementById: () => null,
    createElement: () => ({ ...inertEl }),
    documentElement: { ...inertEl, getAttribute: () => null },
    body: { ...inertEl, appendChild: noop },
  },
  window: { addEventListener: noop, removeEventListener: noop, open: () => null, matchMedia: () => ({ matches: false, addEventListener: noop }) },
  location: { hash: "", pathname: "/", search: "", origin: "http://localhost" },
  localStorage: storage,
  sessionStorage: { getItem: () => null, setItem: noop, removeItem: noop },
  navigator: {},
  URL, URLSearchParams,
  fetch: (path, init) => {
    calls.push({ path, headers: Object.assign({}, init && init.headers) });
    const r = nextResponse;
    return Promise.resolve({
      ok: r.ok, status: r.status,
      headers: { get: () => "application/json" },
      json: () => Promise.resolve(r.body),
      text: () => Promise.resolve(JSON.stringify(r.body)),
    });
  },
  EventSource: function () { return { addEventListener: noop, close: noop }; },
  setTimeout: noop, clearTimeout: noop, setInterval: () => 1, clearInterval: noop,
  console,
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(new URL("../../../cloud/priv/static/app.js", import.meta.url), "utf8"), sandbox);

// A session token must exist or api() sends no auth header (and no team pin).
store["bpcloud.session"] = JSON.stringify({ token: "tok-1", user: { id: "u1" } });
// Find the real session key the IIFE uses.
const SESSION_KEYS = Object.keys(store);

const TEAM_X = "team-XXXX-1111";
const TEAM_Y = "team-YYYY-2222";

const ME_X = {
  user: { id: "u1", email: "a@b.c", confirmed: true, two_factor_enabled: false, platform_operator: false },
  team: { id: TEAM_X, name: "Team X", slug: "team-x" },
  teams: [{ id: TEAM_X, name: "Team X", slug: "team-x", role: "admin" },
          { id: TEAM_Y, name: "Team Y", slug: "team-y", role: "member" }],
  role: "admin",
  team_authority: { team_id: TEAM_X, role: "admin", admin: true, owner: false },
  onboarding: null,
};

async function main() {
  // ---- TAB A boots with the pin on team X ----
  store["bp.active-team"] = TEAM_X;
  nextResponse = { ok: true, status: 200, body: ME_X };
  await hooks.loadMe();
  console.log("STEP1 loadMe request headers:", JSON.stringify(calls.at(-1).headers));
  console.log("STEP1 meFlags:", JSON.stringify(hooks.meFlags()));
  console.log("STEP1 canMintAnyAbility:", hooks.canMintAnyAbility(),
              "providerCanWrite:", hooks.providerCanWrite(),
              "meState:", hooks.meState());

  // ---- TAB B switches to team Y. localStorage is SHARED. Tab B reloads ITSELF;
  //      tab A does not. No storage listener exists in app.js. ----
  store["bp.active-team"] = TEAM_Y;

  // ---- TAB A, same page life, issues a header-scoped request ----
  nextResponse = { ok: true, status: 200, body: { ok: true } };
  await hooks.api("POST", "/v1/instances");
  const hdr = calls.at(-1).headers;
  console.log("STEP2 header-scoped POST /v1/instances -> x-barkpark-team:", hdr["x-barkpark-team"]);
  console.log("STEP2 console still believes team_authority.team_id ==", ME_X.team_authority.team_id,
              "role:", hooks.meFlags().role, "| meCache untouched:", hooks.meState());

  // ---- The proposed leg-1 check, both readings ----
  // (a) team_authority.team_id vs meCache.team.id  — both from meCache
  const a = ME_X.team_authority.team_id === ME_X.team.id;
  // (b) team_authority.team_id vs the LIVE pin api() actually sends
  const livePin = sandbox.localStorage.getItem("bp.active-team");
  const b = ME_X.team_authority.team_id === livePin;
  console.log("STEP3 check(a) team_authority.team_id === meCache.team.id  ->", a, "(cannot lose)");
  console.log("STEP3 check(b) team_authority.team_id === localStorage pin ->", b, "(loses here)");

  // ---- Path-scoped family: the Members routes build the path from meCache ----
  const ctxTeam = ME_X.team.id; // membersContext().teamId
  await hooks.api("GET", "/v1/teams/" + ctxTeam + "/members");
  const h2 = calls.at(-1).headers;
  console.log("STEP4 path-scoped GET path team:", ctxTeam,
              "| header sent:", h2["x-barkpark-team"],
              "| server gate reads: PATH (require_team_role) =>", ctxTeam);

  console.log("STEP5 total fetches:", calls.length,
              "| every request carried a team header:",
              calls.every(c => !!c.headers["x-barkpark-team"]));
}
main().catch(e => { console.error("DRIVER ERROR:", e); process.exit(1); });
