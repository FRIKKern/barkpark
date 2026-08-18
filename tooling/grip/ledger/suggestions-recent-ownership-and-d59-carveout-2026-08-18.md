<!-- doc-tier: cold | canonical-for: NONE (ledger re-derivation row) | budget: 900tok -->
# suggestions.recent leak — ownership + D59 carve-out re-derivation (2026-08-18, verifier V4)

Re-derivation recipes for the ownership verdict and the D59 per-actor carve-out.
Written by the wave3 V4 verifier; committed by Decide, not by the verifier.

## Ownership — the finding is a child of bp-cloud-build-epic, NOT api-read-path-security-sweep

    bp task get task-bb39315359cfc33d -o json | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["doc"]["parent_id"], d["doc"]["content"]["brief"]["blocks"][0].get("text"),"gh#",d["doc"].get("github",{}).get("issue"))'
    # => bp-cloud-build-epic ... gh#12216   (main_tag tenancy, priority 3, lifecycle open)

The wish routed this to api-read-path-security-sweep / bp-security-remainder-charter.md. That routing is UNSUPPORTED:

    git show origin/main:.claude/workflows/bp-security-remainder-charter.md | grep -niE 'suggest|recent_quer'
    # => (empty) — ZERO mentions in that charter

    git show origin/main:.claude/workflows/bp-cloud-build-charter.md | grep -nE 'D82'
    # => D82: "two tenant findings are NOT owned elsewhere -> SPIN a fresh follow-up build wave
    #    under THIS epic, do NOT close-as-dup ... Both findings are open children of bp-cloud-build-epic (0/3)."

VERDICT: door files under bp-cloud-build-epic; its decision belongs in bp-cloud-build-charter.md as the
continuation of the D58-D82 search-tenancy read-path line (direct predecessors D59, D65). If the wave keeps
running under api-read-path-security-sweep (per wave-paper name), Decide MUST record the cross-epic adoption
and cite D82 as the authority — the finding remains a bp-cloud-build child.

## D59 carve-out — the framing PARTIALLY holds; one digest premise is FALSE on origin/main

    git show origin/main:api/lib/barkpark/search/intelligence.ex | sed -n '140,153p'
    # suggestions/5 computes workspace_id, passes it to popular_queries (:151) and nohits_queries (:152)
    # but NOT to recent_queries (:150 — surface, scope, actor_key, prefix, limit only)
    git show origin/main:api/lib/barkpark/search/intelligence.ex | grep -nE 'scope_ws\('
    # popular_queries: 773,803 ; nohits_queries: 859,878,913,934 ; recent_queries: NONE

So popular/nohits are ALREADY workspace-scoped via scope_ws — they are NOT "global-legacy aggregates D59 blessed."
The digest's carve-out sentence ("unlike the popular/nohits aggregates D59 accepted as global-legacy") is WRONG;
Decide must not stamp it. Correct language below.

## Exact carve-out language Decide should stamp (new decision extending D59/D65)

D59 blessed the FLAT/ANONYMOUS SurfaceConfigs (admin tuning) read as global-legacy because config is
instance-wide data safe to share. That blessing does NOT extend to recent_queries: recent is PER-ACTOR
personal data ("your recent searches"). Two clamps, only the second is novel:

- Clamp 1 (workspace_id thread + |> scope_ws): pure CONSISTENCY, not a D59 exception — recent's own two
  siblings in the same suggestions/5 dispatch (popular_queries, nohits_queries) already scope_ws; recent
  alone drops workspace_id. Byte-mirror of the proven pattern.
- Clamp 2 (anon fail-close = return []): the genuinely-new decision. recent is keyed by actor_key, which
  collapses every header-less caller to the shared "anon" string (search_intel.ex:7; session_key nil). A
  caller with no stable identity cannot be shown "your recent searches" without leaking a stranger's, and
  D65 proved the flat route stamps Default's REAL id (not nil), so scope_ws alone cannot disambiguate anon
  actors sharing Default + "anon" (or a colliding x-bp-search-client header). Hence [] for the anon sentinel.
