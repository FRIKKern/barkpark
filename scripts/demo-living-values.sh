#!/usr/bin/env bash
# demo-living-values.sh — Living Values v1 §8 acceptance, live, end to end (lvw-t5).
#
# Proves the full loop from the nextgen-wiki-living-values-v1 paper §8 against a
# running Barkpark server, naming the surface for every step:
#
#   1. A canonical value doc exists; TWO published papers inline-reference it
#      via the wire §Authoring block-ops payload (D6 dual-written fallback child).
#   2. The canonical value is edited ONCE (ifRevisionID-guarded patch, with a
#      negative control) → every referencing doc renders the new value on the
#      public reader (per-page-load) and Studio (per-request).
#   3. The used-by/impact panel lists the N dependents: graph API/CLI, Studio
#      backlinks pane ("Used by (N)"), Studio blast-radius pane, and the public
#      reader's "Used by" section (paper-scoped by design — a non-paper
#      canonical has no reader page, so its reader-side impact is the
#      referencing papers' drift markers; the paper-canonical case is covered
#      by a title-valueref).
#   4. The drifted pinned literal is FLAGGED (data-valueref-state="drift"), the
#      Studio accept-baseline affordance (D4) is rendered, and the accept write
#      is applied — the flag clears and ONLY fallback + the D6 text child change.
#   5. Appendix (t8/t9 scope — re-run here for the full narrative): a paper
#      claim drives a published task (design_doc edge) → close-with-criteria
#      flips the paper's "Driven tasks" reverse view to satisfied (✓).
#
# SURFACES + FRESHNESS (wire paper §10):
#   public reader  guerrilla /papers/:slug — per-page-load resolver injection (D2): fresh next request
#   Studio         authenticated LiveView desk — per-request: fresh next request
#   web            Next.js demo — webhook tag-bust + 300s ISR net, published mutations only
#
# RECORDED SUBSTITUTIONS (do not silently pass):
#   * WEB: the deployed Vercel demo (www.barkpark.cloud) is stale (no /papers or
#     /d routes for this content) and points at api.barkpark.cloud, not this
#     server. The named web surface is web/ run LOCALLY against $BP_SERVER:
#         cd web && printf 'NEXT_PUBLIC_BARKPARK_API_URL=%s\nBARKPARK_DATASET=production\n' "$BP_SERVER" > .env.local
#         BARKPARK_TOKEN=<token> BARKPARK_WEBHOOK_SECRET=<secret> pnpm build && pnpm start -p 3111
#     (BARKPARK_TOKEN is REQUIRED server-side: valueref pre-resolve lists
#     schemas via the scoped /v1/schemas route, which 401s anonymously. A stale
#     BARKPARK_TOKEN in the parent shell OVERRIDES .env.local — Next gives
#     process env precedence.) Webhook delivery is simulated by a signed POST
#     (the server cannot reach localhost); the signature is the dispatcher's
#     real "<ts>.<body>" HMAC contract. Set WEB_HOST to enable these steps;
#     they SKIP loudly when unset.
#   * STUDIO ACCEPT CLICK: the accept button is a LiveView affordance with no
#     HTTP endpoint. The script ASSERTS the button + phx payload in the
#     authenticated Studio HTML, then applies the identical write via the
#     ifRev-guarded block-ops patch (the same apply_paper_block_ops path the
#     handler calls; only the LiveView-side drift re-check is bypassed).
#
# USAGE:
#   BP_TOKEN=<admin token> ./scripts/demo-living-values.sh
#   BP_SERVER=https://guerrilla.barkpark.cloud WEB_HOST=http://localhost:3111 \
#     WEBHOOK_SECRET=lvd-t5-demo-secret BP_TOKEN=... ./scripts/demo-living-values.sh
#
# Idempotent: docs are keyed by $PREFIX (default timestamped → every run is a
# fresh, self-contained exhibit; pin PREFIX to reuse/reset the same docs —
# create-or-replace + ingest upsert reset all state, but the appendix task can
# only be closed once per PREFIX).

set -u
BP_SERVER="${BP_SERVER:-https://guerrilla.barkpark.cloud}"
BP_TOKEN="${BP_TOKEN:-}"
PREFIX="${PREFIX:-lvd-demo-$(date +%s)}"
V1="${V1:-6 weeks}"
V2="${V2:-9 weeks}"
WEB_HOST="${WEB_HOST:-}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-lvd-t5-demo-secret}"
DATASET="production"

[ -n "$BP_TOKEN" ] || { echo "FATAL: BP_TOKEN is required (admin token)"; exit 2; }

METRIC="$PREFIX-metrics"; PAPER_A="$PREFIX-paper-a"; PAPER_B="$PREFIX-paper-b"; TASK="$PREFIX-task"
AUTH=(-H "Authorization: Bearer $BP_TOKEN")
JSON=(-H "Content-Type: application/json")
COOKIES="$(mktemp -t lvd-cookies)"
PASS=0; FAIL=0; SKIP=0

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  PASS  [%s] %s\n        evidence: %s\n' "$1" "$2" "$3"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  [%s] %s\n        got: %s\n' "$1" "$2" "$3"; }
skip() { SKIP=$((SKIP+1)); printf '  SKIP  [%s] %s\n' "$1" "$2"; }
# check <surface> <label> <needle> <haystack>
check() { case "$4" in *"$3"*) ok "$1" "$2" "$(printf '%s' "$4" | head -c 220)";; *) bad "$1" "$2" "$(printf '%s' "$4" | head -c 220)";; esac; }

reader_span() { # reader_span <slug> <target>  -> the valueref span fragment
  curl -sL "$BP_SERVER/papers/$1" | grep -o "data-valueref=\"$2\"[^>]*>[^<]*" | head -1
}
# wait_until <seconds> <cmd...> — poll until cmd exits 0 (edge projection is
# ASYNC: valueref/design_doc edges appear via the EdgeProjector shortly after
# the write; graph-dependent assertions must wait for it, never assume it).
wait_until() {
  local deadline=$(( $(date +%s) + $1 )); shift
  while ! "$@" >/dev/null 2>&1; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 2
  done
}
graph_dependents_are() { # graph_dependents_are <doc_id> <n>
  [ "$(curl -s "${AUTH[@]}" "$BP_SERVER/v1/graph/$1" | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('dependents',[])))")" = "$2" ]
}
graph_tasks_count_is() { # graph_tasks_count_is <doc_id> <n>
  [ "$(curl -s "${AUTH[@]}" "$BP_SERVER/v1/graph/$1/tasks" | python3 -c "import json,sys;print(json.load(sys.stdin).get('count',0))")" = "$2" ]
}

say "Living Values §8 demo — server=$BP_SERVER prefix=$PREFIX ($V1 -> $V2)"

# ── STEP 0: preflight ────────────────────────────────────────────────────────
R=$(curl -s "${AUTH[@]}" "$BP_SERVER/v1/capabilities" | grep -o '"auth_tier":"[a-z]*"' | head -1)
check "API" "server reachable + token accepted (admin tier)" '"auth_tier":"admin"' "$R"

# ── STEP 1: canonical value doc + TWO published papers (wire §Authoring) ─────
say "STEP 1 — canonical value + two published inline-referencing papers"
curl -s -X POST "${AUTH[@]}" "${JSON[@]}" "$BP_SERVER/v1/data/mutate/$DATASET" -d "{
  \"mutations\":[{\"createOrReplace\":{\"_type\":\"metric\",\"_id\":\"$METRIC\",
    \"title\":\"$PREFIX launch metrics\",\"launch_delay\":\"$V1\"}}]}" >/dev/null
curl -s -X POST "${AUTH[@]}" "${JSON[@]}" "$BP_SERVER/v1/data/mutate/$DATASET" \
  -d "{\"mutations\":[{\"publish\":{\"id\":\"$METRIC\",\"type\":\"metric\"}}]}" >/dev/null

# Paper A — the wire §Authoring worked payload (valueref + D6 dual-written child).
curl -s -X POST "${AUTH[@]}" "${JSON[@]}" "$BP_SERVER/v1/plugins/bulldocs/papers" -d "{
 \"slug\":\"$PAPER_A\",\"title\":\"$PREFIX launch plan (paper A)\",
 \"blocks\":[
  {\"id\":\"a-intro\",\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"value\":\"Paper A of the living-values demo. It inline-references the canonical launch metric.\"}]},
  {\"id\":\"a-valueref\",\"type\":\"paragraph\",\"content\":[
   {\"type\":\"text\",\"value\":\"Launch delay is \"},
   {\"type\":\"valueref\",\"target\":\"$METRIC\",\"field\":\"launch_delay\",\"as\":\"duration\",\"fallback\":\"$V1\",\"label\":\"launch delay\",\"children\":[{\"type\":\"text\",\"value\":\"$V1\"}]},
   {\"type\":\"text\",\"value\":\" and the rollout plan assumes it.\"}]}]}" >/dev/null
# Paper B — second dependent + a title-valueref at paper A (the paper-canonical
# case: gives paper A a reader-side "Used by" section). NOTE: the generic doc
# envelope resolves a paper's `title` to its SLUG, so the pin is the slug.
curl -s -X POST "${AUTH[@]}" "${JSON[@]}" "$BP_SERVER/v1/plugins/bulldocs/papers" -d "{
 \"slug\":\"$PAPER_B\",\"title\":\"$PREFIX capacity brief (paper B)\",
 \"blocks\":[
  {\"id\":\"b-intro\",\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"value\":\"Paper B - the second dependent of the canonical launch metric.\"}]},
  {\"id\":\"b-valueref\",\"type\":\"paragraph\",\"content\":[
   {\"type\":\"text\",\"value\":\"Our current launch delay is \"},
   {\"type\":\"valueref\",\"target\":\"$METRIC\",\"field\":\"launch_delay\",\"as\":\"duration\",\"fallback\":\"$V1\",\"label\":\"launch delay\",\"children\":[{\"type\":\"text\",\"value\":\"$V1\"}]},
   {\"type\":\"text\",\"value\":\", per the canonical launch metrics.\"}]},
  {\"id\":\"b-title-ref\",\"type\":\"paragraph\",\"content\":[
   {\"type\":\"text\",\"value\":\"It builds on \"},
   {\"type\":\"valueref\",\"target\":\"$PAPER_A\",\"field\":\"title\",\"as\":\"text\",\"fallback\":\"$PAPER_A\",\"label\":\"paper A\",\"children\":[{\"type\":\"text\",\"value\":\"$PAPER_A\"}]},
   {\"type\":\"text\",\"value\":\" (paper A).\"}]}]}" >/dev/null

check "public reader" "paper A resolves canonical ($V1)" "data-valueref-state=\"resolved\">$V1" "$(reader_span "$PAPER_A" "$METRIC")"
check "public reader" "paper B resolves canonical ($V1)" "data-valueref-state=\"resolved\">$V1" "$(reader_span "$PAPER_B" "$METRIC")"
if wait_until 60 graph_dependents_are "$METRIC" 2; then
  ok "graph API/CLI" "valueref edges projected (async EdgeProjector)" "dependents=2 within 60s"
else
  bad "graph API/CLI" "valueref edges projected (async EdgeProjector)" "still <2 dependents after 60s"
fi

# ── STEP 2: edit the canonical ONCE (guarded) → all dependents re-render ─────
say "STEP 2 — one guarded edit propagates to every referencing doc"
NEG=$(curl -s -X POST "${AUTH[@]}" "${JSON[@]}" "$BP_SERVER/v1/data/mutate/$DATASET" -d "{
  \"mutations\":[{\"patch\":{\"id\":\"$METRIC\",\"type\":\"metric\",\"set\":{\"launch_delay\":\"$V2\"},\"ifRevisionID\":\"bogus-rev\"}}]}")
check "API" "negative control: bogus ifRevisionID rejected BEFORE write" "precondition_failed" "$NEG"
REV=$(curl -s "${AUTH[@]}" "$BP_SERVER/v1/data/doc/$DATASET/metric/$METRIC" | python3 -c "import json,sys;d=json.load(sys.stdin);print((d.get('result') or d)['_rev'])")
curl -s -X POST "${AUTH[@]}" "${JSON[@]}" "$BP_SERVER/v1/data/mutate/$DATASET" -d "{
  \"mutations\":[{\"patch\":{\"id\":\"$METRIC\",\"type\":\"metric\",\"set\":{\"launch_delay\":\"$V2\"},\"ifRevisionID\":\"$REV\"}},
                 {\"publish\":{\"id\":\"$METRIC\",\"type\":\"metric\"}}]}" >/dev/null

check "public reader" "paper A re-renders new value (per-page-load, D2)" ">$V2" "$(reader_span "$PAPER_A" "$METRIC")"
check "public reader" "paper B re-renders new value (per-page-load, D2)" ">$V2" "$(reader_span "$PAPER_B" "$METRIC")"

# Studio (per-request LiveView): session via one-click login ticket (dwb-7).
TICKET=$(curl -s -X POST "${AUTH[@]}" "${JSON[@]}" "$BP_SERVER/v1/auth/login-tickets" -d '{}' | python3 -c "import json,sys;print(json.load(sys.stdin).get('ticket',''))")
curl -s -c "$COOKIES" -o /dev/null "$BP_SERVER/login/ticket/$TICKET"
STUDIO_A() { curl -s -b "$COOKIES" "$BP_SERVER/w/default/p/default/d/$DATASET/studio/open/paper/$PAPER_A"; }
S=$(STUDIO_A | grep -o "data-valueref=\"$METRIC\"[^>]*>[^<]*" | head -1)
check "Studio" "paper A re-renders new value (per-request)" ">$V2" "$S"

if [ -n "$WEB_HOST" ]; then
  W=$(curl -s "$WEB_HOST/d/paper/$PAPER_A" | grep -o "data-valueref=\"$METRIC\"[^>]*>[^<]*" | head -1)
  # Freshness contract (§10): within the 300s ISR window the cached paper BODY
  # may be stale; the valueref pre-resolve fetches are uncached (per-request),
  # so the VALUE is typically already fresh. The tag-bust below is the
  # contractual propagation path for published mutations.
  TS=$(date +%s); BODY="{\"event\":\"mutation\",\"type\":\"metric\",\"doc_id\":\"$METRIC\",\"dataset\":\"$DATASET\",\"sync_tags\":[\"doc:metric\",\"doc:paper\"],\"deliveryId\":\"$PREFIX-$TS\"}"
  SIG=$(printf '%s.%s' "$TS" "$BODY" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" -hex | sed 's/^.*= //')
  BUST=$(curl -s -X POST "$WEB_HOST/api/barkpark/webhook" "${JSON[@]}" -H "x-barkpark-timestamp: $TS" -H "x-barkpark-signature: v1=$SIG" -d "$BODY")
  check "web (local)" "signed webhook accepted + tags revalidated" '"ok":true' "$BUST"
  W2=$(curl -s "$WEB_HOST/d/paper/$PAPER_A" | grep -o "data-valueref=\"$METRIC\"[^>]*>[^<]*" | head -1)
  check "web (local)" "paper A renders new value after tag-bust (was: ${W:-none})" ">$V2" "$W2"
else
  skip "web" "WEB_HOST unset — run web/ locally against $BP_SERVER (see header) to exercise the web surface"
fi

# ── STEP 3: used-by / impact panel lists the N dependents ────────────────────
say "STEP 3 — used-by / impact panel"
G=$(curl -s "${AUTH[@]}" "$BP_SERVER/v1/graph/$METRIC" | python3 -c "
import json,sys; d=json.load(sys.stdin)
deps=sorted(x['doc_id'] for x in d.get('dependents',[]))
kinds=sorted({e['kind'] for e in d.get('edges',[])})
print(f'dependents={deps} kinds={kinds}')")
check "graph API/CLI" "canonical lists BOTH dependent papers (valueref edges)" "dependents=['$PAPER_A', '$PAPER_B']" "$G"
S=$(STUDIO_A | grep -o 'Used by ([0-9]*)' | head -1)
check "Studio" "backlinks pane shows Used by (1) on paper A (title-valueref)" "Used by (1)" "$S"
S=$(curl -s -b "$COOKIES" "$BP_SERVER/w/default/p/default/d/$DATASET/studio/graph/$METRIC" | grep -o "$PREFIX-paper-[ab]" | sort -u | tr '\n' ' ')
check "Studio" "blast-radius pane for the canonical lists both papers" "$PREFIX-paper-a $PREFIX-paper-b" "$S"
R=$(curl -sL "$BP_SERVER/papers/$PAPER_A" | python3 -c "
import re,sys; t=sys.stdin.read()
m=re.search(r'bp-paper-usedby.*?</section>',t,re.S)
print(re.sub(r'\s+',' ',re.sub('<[^>]+>',' ',m.group(0)))[:160] if m else 'ABSENT')")
check "public reader" "paper A shows the Used by section listing paper B" "$PAPER_B" "$R"

# ── STEP 4: drift flagged; accept-baseline (D4) clears it ────────────────────
say "STEP 4 — drift flag + accept-baseline"
check "public reader" "pinned literal drifted -> FLAGGED" 'data-valueref-state="drift"' "$(reader_span "$PAPER_A" "$METRIC")"
S=$(STUDIO_A | grep -o 'phx-click="valueref-accept-baseline"[^>]*' | head -1)
check "Studio" "accept-baseline affordance rendered on the drifted node" "phx-value-fallback=\"$V1\"" "$S"

BEFORE=$(curl -s "${AUTH[@]}" "$BP_SERVER/v1/data/doc/$DATASET/paper/$PAPER_A" | python3 -c "import json,sys;d=json.load(sys.stdin);print(json.dumps((d.get('result') or d).get('blocks')))")
PREV=$(curl -s -X POST "${AUTH[@]}" "${JSON[@]}" "$BP_SERVER/v1/plugins/bulldocs/papers/$PAPER_A/ops" \
  -d '{"ifRev":"999999","ops":[{"op":"patch-block","id":"a-valueref","patch":{}}]}')
check "API" "negative control: stale ifRev rejected, no ops applied" "precondition_failed" "$PREV"
PREV=$(curl -s "${AUTH[@]}" "$BP_SERVER/v1/data/doc/$DATASET/paper/$PAPER_A" | python3 -c "import json,sys;d=json.load(sys.stdin);print((d.get('result') or d).get('rev','1'))")
# The accept write (see header: replicates the Studio handler's patch-block).
A=$(curl -s -X POST "${AUTH[@]}" "${JSON[@]}" "$BP_SERVER/v1/plugins/bulldocs/papers/$PAPER_A/ops" -d "{
 \"ifRev\":\"$PREV\",\"ops\":[{\"op\":\"patch-block\",\"id\":\"a-valueref\",\"patch\":{\"content\":[
  {\"type\":\"text\",\"value\":\"Launch delay is \"},
  {\"type\":\"valueref\",\"target\":\"$METRIC\",\"field\":\"launch_delay\",\"as\":\"duration\",\"fallback\":\"$V2\",\"label\":\"launch delay\",\"children\":[{\"type\":\"text\",\"value\":\"$V2\"}]},
  {\"type\":\"text\",\"value\":\" and the rollout plan assumes it.\"}]}}]}")
check "API" "accept-baseline write applied (ifRev-guarded)" '"ok":true' "$A"
check "public reader" "flag CLEARED - resolved at the new baseline" "data-valueref-state=\"resolved\">$V2" "$(reader_span "$PAPER_A" "$METRIC")"
AFTER=$(curl -s "${AUTH[@]}" "$BP_SERVER/v1/data/doc/$DATASET/paper/$PAPER_A" | python3 -c "import json,sys;d=json.load(sys.stdin);print(json.dumps((d.get('result') or d).get('blocks')))")
DIFF=$(python3 - "$BEFORE" "$AFTER" <<'EOF'
import json,sys
a,b=json.loads(sys.argv[1]),json.loads(sys.argv[2])
diffs=[]
def walk(x,y,p):
    if type(x)!=type(y): diffs.append(p); return
    if isinstance(x,dict):
        for k in set(x)|set(y): walk(x.get(k),y.get(k),f"{p}.{k}")
    elif isinstance(x,list):
        if len(x)!=len(y): diffs.append(p); return
        for i,(u,v) in enumerate(zip(x,y)): walk(u,v,f"{p}[{i}]")
    elif x!=y: diffs.append(p)
walk(a,b,'blocks')
print(f"changed={sorted(diffs)}")
EOF
)
check "API" "ONLY fallback + D6 text child changed" "changed=['blocks[1].content[1].children[0].value', 'blocks[1].content[1].fallback']" "$DIFF"

# ── STEP 5 (appendix, t8/t9 scope): expectation demo ─────────────────────────
say "STEP 5 (appendix) — paper claim drives a task; close-with-criteria flips it"
curl -s -X POST "${AUTH[@]}" "${JSON[@]}" "$BP_SERVER/v1/data/mutate/$DATASET" -d "{
 \"mutations\":[{\"createOrReplace\":{\"_type\":\"task\",\"_id\":\"$TASK\",
  \"title\":\"$PREFIX: verify rollout capacity claim\",\"kind\":\"task\",\"lifecycle_status\":\"open\",\"priority\":3,
  \"design_doc\":\"$PAPER_A\",
  \"acceptance_criteria\":[{\"criterion\":\"Rollout capacity re-verified against the new launch delay\",\"met\":false,\"evidence\":\"\"}]}},
  {\"publish\":{\"id\":\"$TASK\",\"type\":\"task\"}}]}" >/dev/null
wait_until 60 graph_tasks_count_is "$PAPER_A" 1 || true  # design_doc edge projection is async
T=$(curl -s "${AUTH[@]}" "$BP_SERVER/v1/graph/$PAPER_A/tasks" | python3 -c "
import json,sys; d=json.load(sys.stdin)
ts=d.get('tasks',[]); t=ts[0] if ts else {}
p=t.get('criteria_progress') or {}
print(f\"count={d.get('count')} status={t.get('lifecycle_status')} met={p.get('met')}/{p.get('total')}\")")
check "graph API/CLI" "reverse view: task drives paper A, UNSATISFIED" "count=1 status=open met=0/1" "$T"
R=$(curl -sL "$BP_SERVER/papers/$PAPER_A" | python3 -c "
import re,sys;t=sys.stdin.read()
m=re.search(r'Driven tasks.*?</section>',t,re.S)
print(re.sub(r'\s+',' ',re.sub('<[^>]+>',' ',m.group(0)))[:200] if m else 'ABSENT')")
check "public reader" "Driven tasks section shows 0/1 met (unsatisfied)" "0/1 met" "$R"

curl -s -X POST "${AUTH[@]}" "${JSON[@]}" "$BP_SERVER/v1/tasks/$TASK/claim" -d "{\"worker_id\":\"$PREFIX-worker\"}" >/dev/null
C=$(curl -s -X POST "${AUTH[@]}" "${JSON[@]}" "$BP_SERVER/v1/tasks/$TASK/close" -d "{
 \"worker_id\":\"$PREFIX-worker\",\"observed_epoch\":1,
 \"criteria\":[{\"index\":0,\"met\":true,\"evidence\":\"Capacity re-verified for the $V2 delay - living-values demo run\"}]}")
check "API" "close-with-criteria: met+evidence atomic with the close CAS" '"ok":true' "$C"
T=$(curl -s "${AUTH[@]}" "$BP_SERVER/v1/graph/$PAPER_A/tasks" | python3 -c "
import json,sys; d=json.load(sys.stdin)
t=(d.get('tasks') or [{}])[0]
p=t.get('criteria_progress') or {}
print(f\"status={t.get('lifecycle_status')} met={p.get('met')}/{p.get('total')} crit0_met={t.get('criteria',[{}])[0].get('met')}\")")
check "graph API/CLI" "reverse view flipped to SATISFIED" "status=done met=1/1 crit0_met=True" "$T"
R=$(curl -sL "$BP_SERVER/papers/$PAPER_A" | python3 -c "
import re,sys;t=sys.stdin.read()
m=re.search(r'Driven tasks.*?</section>',t,re.S)
print(re.sub(r'\s+',' ',re.sub('<[^>]+>',' ',m.group(0)))[:220] if m else 'ABSENT')")
check "public reader" "Driven tasks flipped: done, 1/1 met with evidence" "1/1 met" "$R"

# ── Summary ──────────────────────────────────────────────────────────────────
say "SUMMARY: $PASS passed, $FAIL failed, $SKIP skipped  (prefix $PREFIX)"
rm -f "$COOKIES"
[ "$FAIL" -eq 0 ]
