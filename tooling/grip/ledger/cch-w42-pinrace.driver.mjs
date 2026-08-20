// Cross-tab pin race driver — runs origin/main's app.js verbatim in a vm sandbox.
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
vm.runInContext(fs.readFileSync(new URL("./main-app.js", import.meta.url), "utf8"), sandbox);

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
