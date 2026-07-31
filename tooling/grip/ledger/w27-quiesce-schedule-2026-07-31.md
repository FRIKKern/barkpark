# w27 quiesce schedule — the measured window, and the gate that replaces the clock

Measured live on guerrilla 2026-07-31T00:59Z–01:11Z by the wave-27 verifier
[quiesce-schedule]. Every number below is a re-derivation, not a quote.

## 1. The write-back tail is ONE write, ~44 s after yours

Probe: the strategist's disposable, **non-closure** row `task-dca82364a92a4f0d`
(`parent_id: null` — it is NOT in the PDS closure, so writing it cannot trip
clause 5).

| instant | event | rev |
|---|---|---|
| `01:07:28.372157Z` | my `bp task stage … done --disposition closed` landed | `a5508946` |
| `01:08:12.271620Z` | GitHub MirrorJob stamped the row back | `73cc78df`, `github.synced_rev = a5508946` |
| `01:08:12` → `01:08:58` | 20 further polls, **no second move** | stable |

**End-to-end latency = 43.90 s.** `schedule_in: 30` (drain_worker) + drain tick +
GitHub round-trip. The tail is self-terminating: the mirror's own write is
stamped `source="github"` and `Outbox.fetch/3` excludes it, so `synced_rev`
always trails `_rev` by exactly one and never re-fires.

Re-run:

    bp task stage <disposable-row> done --disposition closed --note probe --yes -o json
    # then poll /v1/data/doc/production/task/<row> every 2 s and watch _rev move twice

## 2. Corpus-wide `moved == 0` is NOT a property you can wait for

Two 60 s windows, same host, 12 minutes apart:

| window | scope | moved |
|---|---|---|
| `00:59:31Z → 01:02:11Z` | corpus (3901) | **3** — `jarl-platform-followups-epic`, `jarl-dogfood-publishing-epic`, `jarl-historiene-epic` |
| `01:09:25Z → 01:10:57Z` | corpus (3902) | 0 |

The three movers are a **foreign session's** epic rows: `parent_id: null`, and
each verified NOT in the PDS closure. A corpus-wide `moved==0` gate is therefore
hostage to unrelated fleet traffic. The corpus also GREW twice during the
measurement (3897 → 3901 → 3902).

**Clause 5 is already closure-scoped** — `census(...)` opens with
`rows = [corpus[i] for i in closure]` and the drift loop iterates `rows`. So the
gate must be scoped the same way, or it will refuse runs clause 5 would pass.

## 3. The paging hazard is real, and it has a live escape hatch

`Content.Query.apply_order/2` falls through to `desc: d.updated_at`
(query.ex:704) with `asc: d.id` as a total-order tiebreak (query.ex:133). The
tiebreak fixes TIES only — it does nothing about a row whose `updated_at`
*changes* mid-read. The census sends `limit`+`offset` and **no `order`**
(`fetch_page`: `query = "limit=%d&offset=%d"`), so it pages under the one
ordering key that concurrent writes mutate.

`_createdAt` never changes. Live-proven on guerrilla:

    ?order=_createdAt:asc   → page0 2026-07-01T23:08:01Z … page3 ends 2026-07-31T01:02:30Z   (ASCENDING — honoured)
    ?order=created_at_asc   → page0 starts 2026-07-31 and descends                            (SILENTLY IGNORED)

`parse_order/1` (query_controller.ex:705-711) requires `<field>:asc|desc`;
anything else falls through to `:updated_at_desc` **with a 200 and no warning** —
an epic-law violation in the read path, filed here for Arm B.

Under `_createdAt:asc`, a concurrent UPDATE reorders nothing and an INSERT lands
at the tail, so no already-read row can shift into or out of a read page. Two
4-page reads at `_createdAt:asc` returned 3902/3902 rows with **zero duplicates**
each.

## 4. The sweepers are not a factor today — but staging arms one

`Barkpark.Plugins.Tasks.oban_crontab/0`:

    {"* * * * *", Barkpark.Tasks.TtlSweeper},
    {"0 */6 * * *", Barkpark.Tasks.Compactor}

Candidate counts computed over the live corpus using the sweeper's OWN
predicates (`expired_candidates/1`, `engagement_candidates/1`):

| sweep | predicate | candidates now |
|---|---|---|
| lease (2700 s) | `lifecycle_status == "in_progress"` ∧ stale `claim.ts_iso` | **0** (only 1 `in_progress` row corpus-wide, claim fresh) |
| engagement (900 s) | `lifecycle_status ∈ {considering, researching}` ∧ (researching ∨ has `engagement`) ∧ stale `engagement.ts` | **0** (157 `considering`, none stale; 0 `researching`) |

`bp task stage → considering|researching` WRITES `content.engagement{ts,…}` and
therefore ARMS the 900 s engagement sweep for that row — and a `researching` row
is a candidate *even with no engagement map*, i.e. it lapses on the **next
minute tick**, not after 900 s. Wave 27's adjudications target `done` and `open`
rows and write `content.disposition_reason` (durable, no sweeper owns it), so
they arm nothing — provided no slice stages a row into a thought state.
Compactor's next tick is `06:00Z`; keep the certifying run away from it.

## 5. THE GATE (evidence, not a clock)

Run this after the LAST adjudication write of the wave. It refuses on evidence
and never on elapsed time.

```bash
#!/usr/bin/env bash
# w27-quiesce-gate.sh — refuse the certifying run until the CLOSURE is still.
set -euo pipefail
ROOT=task-2ac1f95237c4a8e5
HOST=https://guerrilla.barkpark.cloud
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
snap() { for o in 0 1000 2000 3000 4000; do
  curl -sf -H "Authorization: Bearer $TOK" \
    "$HOST/v1/data/query/production/task?limit=1000&offset=$o&order=_createdAt:asc" \
    -o "$1_$o.json" || exit 3
done; }

sleep 90            # >= 2x the measured 43.9 s write-back tail
snap A; sleep 60; snap B

python3 - "$ROOT" <<'PY' || exit 4
import json,sys
root=sys.argv[1]
def load(p):
    m={};seq=[]
    for o in (0,1000,2000,3000,4000):
        try: docs=json.load(open('%s_%d.json'%(p,o)))['result']['documents']
        except FileNotFoundError: break
        for d in docs: m[d['_id']]=d; seq.append(d['_id'])
    assert len(seq)==len(set(seq)), 'DUPLICATE row across pages -- not a snapshot'
    return m
A,B=load('A'),load('B')
kids={}
for d in B.values():
    if d.get('parent_id'): kids.setdefault(d['parent_id'],[]).append(d['_id'])
clo=set(); st=[root]
while st:
    n=st.pop()
    if n in clo: continue
    clo.add(n); st+=kids.get(n,[])
moved=[i for i in clo if i in A and A[i]['_updatedAt']!=B[i]['_updatedAt']]
churn=(set(B)&clo)^(set(A)&clo)
print('closure=%d moved=%d churn=%d'%(len(clo),len(moved),len(churn)))
if moved or churn:
    print('NOT QUIESCED:', (moved+sorted(churn))[:8]); raise SystemExit(1)
PY
echo "QUIESCED — certifying run may start"
```

Properties, each earned above: it is **closure-scoped** (§2 — foreign traffic
must not veto the run, and clause 5 does not look at it); it pages by
**`_createdAt:asc`** (§3 — the only stable key, so an in-flight write cannot
skip or double-serve a row); it asserts **zero duplicates** as a hard failure
rather than a statistic; the `sleep 90` is a *floor* on the measured 43.9 s tail,
not the verdict — the verdict is `moved==0 ∧ churn==0` over two reads 60 s apart.
A 5th page (`offset=4000`) is fetched because the corpus grew twice during a
12-minute measurement.

## 6. What Decide must know

* **The denominators moved under us.** Closure was 332 / live 186 in the digest;
  at `01:10:57Z` it reads **333 / 187**. A row was parented into the closure
  between the two runs. Clause 4(a)'s target is not a constant — the certifying
  run must re-derive it, and any pinned adjudication manifest must be re-checked
  against the closure at gate time.
* **Sequencing is now a criterion, not a hope:** last adjudication → ≥90 s →
  gate above → certifying run, with the certifying run reading `_createdAt:asc`
  too. If Arm B lands a reader change that writes nothing, it does not need to
  sit inside the fence; anything that writes a task row does.
* **Two read-path lies found while measuring**, both Arm B's shape: an unknown
  `order=` value is silently downgraded to `updated_at_desc` at HTTP 200, and the
  census's own paging inherits the one volatile sort key.
