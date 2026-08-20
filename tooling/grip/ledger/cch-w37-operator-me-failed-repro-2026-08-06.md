# cch-w37 · the stuck "Checking operator access…" REPRODUCES — re-derivation recipe

Measured 2026-08-06 against `origin/main` = `bf97452bb38488d04cfbb596c2528a3f34ad5baf`
(the local primary checkout was 503 commits BEHIND at the time — every read below is
`git show origin/main:` or a clone pinned at that sha, never the worktree).

## What is claimed

`#operator` deep-linked, session authed, `GET /v1/me` answers 500/502 →
`#operator-body` sits on `<div class="loading">Checking operator access&hellip;</div>`
FOREVER. No retry, no fault sentence, no bounce, no toast. Byte-identical to cold boot.
`meState()` is already `"failed"` and `meFailureCopy()` already returns the right
sentence — nothing reads them.

Anchors on that sha:
- `cloud/priv/static/app.js:8032` `loadOperator()`; `:8035-8038` the `!meCache` arm.
- `cloud/priv/static/app.js:13936-13943` loadMe's failure arm — its own comment says
  "the operator loader is deliberately NOT re-entered here" (cch-w36-s3 carve-out).
- `cloud/priv/static/app.js:13850-13862` `meState()` / `meFailureCopy()`.
- `cloud/priv/static/__app.test.mjs:2471-2476` — a SOURCE-TEXT pin (D411 fence 3) that
  requires the `!meCache` arm to be exactly spinner-then-`return;`. A fix must move it.
- `cloud/priv/static/__preview__/scenarios.mjs:4161` — `/v1/me` is hardcoded 200-or-401.

## Re-derive (one paste, ~40 s)

```sh
W=$(mktemp -d); git clone -q --shared --no-checkout <repo> $W
cd $W && git checkout -q --detach bf97452bb38488d04cfbb596c2528a3f34ad5baf
cd $W/cloud/priv/static/__preview__
sed -n '1,340p' smoke.mjs > drive.mjs      # makeDom + imports, verbatim
cat >> drive.mjs <<'EOF'
async function flush(){for(let i=0;i<40;i++){await Promise.resolve();await new Promise(r=>setImmediate(r));}}
function boot(name, meOverride){
  const {registry, document} = makeDom();
  const store=new Map(), ss=new Map();
  const localStorage={getItem:k=>store.has(k)?store.get(k):null,setItem:(k,v)=>store.set(k,String(v)),removeItem:k=>store.delete(k)};
  const sessionStorage={getItem:k=>ss.has(k)?ss.get(k):null,setItem:(k,v)=>ss.set(k,String(v)),removeItem:k=>ss.delete(k)};
  const scen=SCENARIOS[name];
  if(scen.authed) store.set("bpcloud.session",JSON.stringify({token:"preview",team_id:"preview-team"}));
  const location={hash:scen.deepLink||"#overview",pathname:"/",search:"",origin:"http://localhost",href:"http://localhost/"};
  const fixtureState={}, calls=[];
  function fetchStub(url,init){const method=(init&&init.method)||"GET";const p=String(url);calls.push({method,path:p.split("?")[0]});
    const res = (p.split("?")[0]==="/v1/me"&&meOverride)?meOverride:(route(name,method,p,fixtureState)||{status:404,body:{error:"not_found"}});
    return Promise.resolve({ok:res.status>=200&&res.status<300,status:res.status,
      headers:{get:h=>String(h).toLowerCase()==="content-type"?"application/json":null},
      json:()=>Promise.resolve(res.body),text:()=>Promise.resolve(JSON.stringify(res.body))});}
  const sandbox={document,window:{addEventListener(){},removeEventListener(){},open(){return null},matchMedia(){return{matches:false,addEventListener(){}}}},
    location,history:{replaceState(){},pushState(){}},localStorage,sessionStorage,navigator:{},fetch:fetchStub,
    EventSource:function(){return{addEventListener(){},removeEventListener(){},close(){}}},
    setTimeout:()=>0,clearTimeout(){},setInterval:()=>1,clearInterval(){},console,URLSearchParams,URL};
  sandbox.window.location=location; sandbox.globalThis=sandbox;
  const cap={hooks:null}; sandbox.__bpTestHook=h=>{cap.hooks=h};
  vm.createContext(sandbox); vm.runInContext(APP_JS,sandbox,{filename:"app.js"});
  return {registry,hooks:cap.hooks,calls,location};
}
for (const [label,scen,ov] of [
  ["CONTROL A operator /v1/me 200","operator-console",null],
  ["CASE B operator /v1/me 500","operator-console",{status:500,body:{error:"internal"}}],
  ["CASE C operator /v1/me 502","operator-console",{status:502,body:{error:"bad_gateway"}}],
  ["CONTROL D non-operator 200","operator-denied",null],
  ["CASE E operator /v1/me 401","operator-console",{status:401,body:{error:"unauthorized"}}],
]) {
  const b=boot(scen,ov); await flush();
  const el=b.registry.get("operator-body"); const html=el?String(el.innerHTML||""):"<<absent>>";
  console.log("\n###",label,"\n  hash:",b.location.hash,"\n  meState:",b.hooks.meState(),
    "\n  meFlags:",JSON.stringify(b.hooks.meFlags()),
    "\n  body:",html.slice(0,120),"\n  spinner:",/Checking operator access/.test(html),
    "\n  /v1/me calls:",b.calls.filter(c=>c.path==="/v1/me").length,
    " operator-route calls:",b.calls.filter(c=>c.path.indexOf("/v1/operator")===0).length);
}
EOF
node drive.mjs
```

Expected (measured):
- A → `meState loaded`, body = the four operator cards, 4 operator-route reads.
- B/C → `meState failed`, fault retained, body = `Checking operator access…`,
  hash still `#operator`, **0** operator-route reads, **1** `/v1/me` call, no toast.
- D → bounced to `#overview`, body empty, D411 toast in `#toast-stack`.
- E → 401 logs the person OUT (`api()` `app.js:139-142` clearSession+render);
  401 is therefore NOT the defect band — it is the only failure the fixtures can express.

## Terminality (static, from the same sha)

`loadOperator` has exactly two callers: `app.js:4835` (`applyRoute`) and `:13916`
(loadMe's SUCCESS arm). `loadMe()` has exactly two callers: `:12616` (invitation
accept) and `:18945` (inside `render()`). Every `render()` call site — `:141, :1329,
:4490, :4571, :4603, :12595, :19295` — is a sign-out / sign-in / password-reset /
invite-switch. So hash navigation away and back re-enters `loadOperator` with
`meCache` still null and repaints the same spinner: the state is TERMINAL for the
session, curable only by page reload or re-authentication.

## Fixture gap (why a guard written today cannot lose in smoke)

`grep -n 'me: null' scenarios.mjs` → 2090, 2099, 2790, 2797, 2806 — ALL five are
`loggedout*` scenarios (`authed:false`). `route()` at `:4161` can only answer
`/v1/me` 200 or 401, and 401 signs the user out. Therefore `meState()=="failed"`
is unreachable from every committed fixture.

Minimum honest scenario to add:
1. `scenarios.mjs` route(), immediately ABOVE `:4161`:
   `if (p === "/v1/me" && d.meFault) return d.meFault;`
2. new key `"operator-me-unreadable"`: `authed:true`, `deepLink:"#operator"`,
   `data: { me: operatorMe("Acme Inc"), meFault: {status:500, body:{error:"internal"}},
   barkparks:[liveInstance], subscription: activeSub, sites:[], audit:[] }`
   (keep `me` present so nothing else in the fixture starves; only the wire fails).
3. `smoke.mjs` EXPECTATIONS entry — smoke's census guard is two-way (`smoke.mjs:3119`,
   "every scenario needs an expectation, both ways") and exits 1 without it.
4. `breakpoint-sweep.mjs` residue entry or a cell — else exit 2 `UNLISTED scenario`
   (`breakpoint-sweep.mjs:1182`).
5. `breakpoint-sweep.test.mjs:547` census literals 103 → 104 (and the residue count).

Note the gap is NOT the harness: smoke's `bootScenario` DOM shim already renders and
retains `#operator-body` (proved above). The single blocker is the hardcoded `/v1/me`
line. A node-level guard in `__app.test.mjs` cannot substitute as-is: that sandbox's
`document.getElementById` returns `null` (`__app.test.mjs` sandbox block), so
`loadOperator`'s `if (!body) return;` fires, and `loadOperator` is not exported.

## Gate state on main at that sha (clean clone, not the stale worktree)

    node --check app.js                       → ok
    node --test __app.test.mjs                → 914/914 pass
    node __preview__/smoke.mjs                → all 103 scenarios rendered
    node __preview__/breakpoint-sweep.mjs     → rc 0
    node --test __preview__/breakpoint-sweep.test.mjs → 51/51 pass
    node __preview__/__css_check.mjs          → rc 0
    node --test __preview__/seal-predicate.test.mjs   → 75/75 pass

The surveyed "68/75 seal-predicate failures" is an ARTIFACT of running the suite from a
`git archive` extraction: with no `.git`/`.github` at `--repo`, the predicate exits 2
(INFRA FAULT, `UNREADABLE-REPO-ROOT`) where the tests assert 1. In a real checkout it is
75/75. Main's console gate is GREEN.
