# PDS w39 — the "routedness disagreement" class is 2, and the premise behind it is wrong

Verifier assignment `routedness-disagreement-class`, run at origin/main `974d412caec6fd7023764f43595bee714226581b`.

## Verdict

- The survey's finding (A) — "two arms of one run contradict each other" — is **REFUTED as a
  contradiction**. `[UNROUTED]` in `--sites` means **no Repo verb reached within depth 6**, not
  "absent from router.ex". The two arms measure different things and the instrument says so.
- The class asked for ("`[UNROUTED]` emitter inside an action the routed population EXCLUDES") is
  **exactly 2 members**, and **neither is findable by name-matching**.
- Quiet-host census cost: **13.3 s** (`--sites`) and **18.0 s** (full). Both well under 90 s.

## Re-derivation

```bash
cd <checkout at origin/main>
elixir scripts/pds-elixir-receipt-census.exs --sites > /tmp/sites.txt   # 13.3 s, exit 0
elixir scripts/pds-elixir-receipt-census.exs        > /tmp/full.txt     # 18.0 s, exit 0

# the 23 [UNROUTED] emitters and their 12 distinct owner defs
grep -A1 '\[UNROUTED\]' /tmp/sites.txt | grep 'fn ' | sed 's/.*fn //;s/ —.*//' | sort -u

# the committed exclusion table (182 rows; 180 in-corpus + 2 selftest fixtures)
awk 'NR>=173 && /^  \]/{exit} NR>=173' scripts/pds-elixir-receipt-census.exs | grep -c '^\s*{'
```

The naive cross-join of owner-def name against the exclusion table returns **0**. That is the trap:
both real members have owner-def name != routed action name.

## The 2 members

| # | Emitter | Owner def | Routed action | Why the join misses it |
|---|---|---|---|---|
| 1 | `site_deploy_controller.ex:81` | `defp start/2` (:75) | `SiteDeployController.trigger` (`router.ex:1988`) | owner is a **private helper 2 hops down** (`trigger -> do_trigger -> start`); the JUDGED relation is ONE hop (census.exs:3093-3096) |
| 2 | `plugins/sheets/web/ops_controller.ex:71` | `def apply_ops/2` (:61) — **depth 0** | `apply_ops`, excluded row module is `"?"` | `plugins/sheets.ex:152-155` binds controllers to **local variables**, so the AST route reader stringifies the module to `"?"` |

Member 2 is the only genuine **depth-zero** miss. Member 1 is the depth-2 case the census already
documents as a stated limit.

## Why the premise is wrong

`scripts/pds-elixir-receipt-census.exs:2322-2324` prints the legend verbatim:

```
row("write-routed  (claims a state change)", w, nil, :write)
row("read-routed   (claims a read)", r, nil, :read)
row("unrouted      (no Repo verb reached)", u, nil, :unrouted)
```

`write?`/`read?` come from a Repo-verb BFS (`:1707-1708`), never from a route set — so there is no
route lens in the `--sites` classifier that could be "stale". Membership in `receipt_functions`
(`:3140-3146`) is gated on **@register coverage**, not on routedness.

`.claude/workflows/bp-pds-charter.md:10465-10469` (PDS-D552) ruled on this collision *before*
wave 38 built the routed population, reserving ROUTED-WRITE / DISPOSED for the router population
precisely so the two words are not confused.

## Side finding — charter-ledger disagreement

PDS-D552 cites the drift rows at `census.exs:2071-2073`. They are at **:2322-2324**; :2071 is
`defp catch_all_span/2`. Same species as the digest's `:660` vs `:410-411` finding. Feeds
`pds-w38-charter-ledger-disagreement-sweep`.
