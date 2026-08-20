# cch-w68 — the read-degrade denominator, re-derivation recipe (2026-08-17)

Baseline: `origin/main` = `4b5d802a1d5a31030f79fa4eb8d4761eb4995db2` (== local HEAD).

## The denominator

    git show origin/main:cloud/priv/static/app.js | grep -cE 'api\(\s*"GET"'      # 61
    git show origin/main:cloud/priv/static/app.js | wc -l                          # 23791

Per-call-site enclosing function (brace-matched, the same index shape
`__unknown_census.mjs` uses — note it MISATTRIBUTES five sites where a preceding
function's brace walk overshoots; cross-check by reading the code):

    # scratch script, reproduce verbatim
    git show origin/main:cloud/priv/static/app.js > /tmp/app_main.js
    node -e '
    const fs=require("fs");const s=fs.readFileSync("/tmp/app_main.js","utf8");
    const lineOf=o=>s.slice(0,o).split("\n").length;const fns=[];
    const re=/\bfunction\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/g;let m;
    while((m=re.exec(s))){const open=s.indexOf("{",re.lastIndex);if(open<0)continue;
      let d=0,i=open,inS=null,esc=false;
      for(;i<s.length;i++){const c=s[i];
        if(inS){if(esc){esc=false;continue;}if(c==="\\"){esc=true;continue;}if(c===inS)inS=null;continue;}
        if(c==="\""||c==="\x27"||c==="`"){inS=c;continue;}
        if(c==="{")d++;else if(c==="}"){d--;if(d===0){i++;break;}}}
      fns.push({name:m[1],a:lineOf(open),b:lineOf(i)});}
    const L=s.split("\n");L.forEach((l,i)=>{if(/api\(\s*"GET"/.test(l)){
      const g=i+1;const e=fns.filter(f=>f.a<=g&&g<=f.b).sort((x,y)=>(x.b-x.a)-(y.b-y.a))[0];
      console.log(g+"\t"+(e?e.name:"?"));}});'

## The verdict per site is read, never grepped

`|| []` / `|| {}` alone cannot separate honest from dishonest: 13 sites are
honest because a `!r.ok` arm sits ABOVE the fold. Read each enclosing function:

    git show origin/main:cloud/priv/static/app.js | sed -n '<line-2>,<line+24>p'

## The census that already exists (do NOT file it as new)

    node cloud/priv/static/__unknown_census.mjs            # rc 0, "4-site pin"
    grep -n unknown_census cloud/priv/static/__app.test.mjs # 17050 — spawned BY the test file
    grep -n 'unknown_census' .github/workflows/console-harness.yml   # NO HIT

It is gated INDIRECTLY: `console-unit` runs `node --test __app.test.mjs`
(console-harness.yml:342), whose test at :17050 spawns the census and asserts
rc 0 plus its four pin lines. The four direct-`run:` censuses live in the SAME
`console-unit` job (lines 599, 651, 714, 789); `console-gate`'s `needs:` is
pinned at 6 and 6 (:1139, :1323) so a new census step needs NO needs: edit.

## Mutation recipes (both re-derived here)

ADD arm reds (rc 1):

    cp /tmp/app_main.js /tmp/mutant.js
    printf '  function verifyProbeMutantLoader() {\n    api("GET", "/v1/mutant").then(function (r) {\n      var rows = (r.ok && r.data && r.data.rows) || [];\n      if (!rows.length) { box.innerHTML = %s<div class="empty-state"><h2>No rows yet</h2></div>%s; return; }\n      box.innerHTML = rows.join("");\n    });\n  }\n' "'" "'" >> /tmp/mutant.js
    node cloud/priv/static/__unknown_census.mjs /tmp/mutant.js; echo "rc=$?"   # rc=1, ARRIVED …

DEPTH-2 blind spot passes silently (rc 0) — the loadGithub shape:

    cp /tmp/app_main.js /tmp/depth2.js
    cat >> /tmp/depth2.js <<'X'
      function depth2Card(g) { return g.connected ? "<p>on</p>" : '<div class="empty-state"><h2>Not configured</h2></div>'; }
      function depth2Render(g) { box.innerHTML = depth2Card(g || {}); }
      function depth2Loader() { api("GET", "/v1/depth2").then(function (r) { depth2Render((r.ok && r.data) || {}); }); }
    X
    node cloud/priv/static/__unknown_census.mjs /tmp/depth2.js; echo "rc=$?"   # rc=0 — SILENT

NEVER pipe the census to `tail` inside the check: the pipe eats the rc and
prints a FAIL body under `rc=0` (measured here).

## Today's baselines (quiet host, 2026-08-17)

    node --test cloud/priv/static/__app.test.mjs            # tests 1058, pass 1058, fail 0
    git show origin/main:cloud/priv/static/__app.test.mjs | grep -cE '^\s*test\('   # 1057 (line 682 is in a loop → +1 at runtime)
    git show f53167087a:cloud/priv/static/__app.test.mjs | grep -cE '^\s*test\('    # 1048 → the brief's "1049" was honest THEN, it is 9 stale now
    node cloud/priv/static/__binding_census.mjs             # 80-row pin, 40 elevated, 7 unpredicated
    node cloud/priv/static/__unknown_census.mjs             # 4-site pin
    node cloud/priv/static/__css_check.mjs                  # 875 classes, 96 tokens, 588 contrast pairs, 0 errors
    node cloud/priv/static/__me_envelope_census.mjs         # 29 key paths
    node cloud/priv/static/__agent_event_vocabulary_census.mjs  # rendered 4 / fixtured 3
    node cloud/priv/static/__preview__/smoke.mjs            # all 111 scenarios rendered
