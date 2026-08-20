<!-- doc-tier: cold | canonical-for: felix-w31-sobelow-lineshift-classify-rederive | budget: 800tok -->

# felix-w27-bl-sobelow-baseline-lineshift — classify re-derivation (wave 31)

VERDICT: GENUINE-UNBUILT residue, CI/human-gated. NOT closeable-by-evidence, NOT stale-open.
#11427 (4ca033f502) is a merged ancestor of origin/main but does NOT satisfy the row's 3 criteria,
and its 3-row fix has ALREADY re-drifted on current main.

## Re-derive the merged-PR evidence
    git show 4ca033f502 --stat
    # -> api/.sobelow-skips | 6 +++---  (exactly 3 CSRF rows moved: 604->622, 521->539, 545->563)
    git merge-base --is-ancestor 4ca033f502 origin/main && echo ANCESTOR
    # -> ANCESTOR (#11427 is in origin/main)

## Re-derive the row's 3 criteria (all met=0/3, lifecycle open)
    bp task get felix-w27-bl-sobelow-baseline-lineshift -o json | python3 -c "import json,sys;d=json.load(sys.stdin);doc=d.get('doc') or d;print(doc.get('lifecycle_status'),doc.get('criteria_progress'));[print(c.get('met'),c.get('criterion','')[:90]) for c in (doc.get('content') or {}).get('acceptance_criteria',[])]"
    # C1: all 6 router.ex CSRF exemptions re-anchored to CURRENT pipeline lines, fresh scan ZERO findings
    # C2: coordination with PR #6057 recorded (its human waiver gate resolved or provably untouched)
    # C3: MERGE-GATED (lead closes): reconcile PR merged; next api PR's Sobelow check green

## Re-derive the DRIFT-RECURRED refutation (why C1 fails on current main)
    git show origin/main:api/.sobelow-skips | grep -n Config.CSRF
    # skip anchors: 622/274/539/117/215/563
    git show origin/main:api/lib/barkpark_web/router.ex | grep -n "pipeline :session_token_root do\|pipeline :user_auth do\|pipeline :media_mutate do"
    # actual pipeline decls: 553/577/646  <- do NOT match skip anchors 622/539/563
    # => #11427's 3-row snapshot fix has re-drifted; a fresh no-op scan re-emits findings.

## Charter ruling (origin/main, D194 line 2803)
    git show origin/main:.claude/workflows/bp-felix-pristine-charter.md | sed -n '2803,2822p'
    # "THE LINESHIFT ROW IS NOT SUBSUMED" — #6057 anchors 117/215/274/513/537/596 = its OWN 6-for-6
    # stale tree; current-main decls 131/229/288/553/577/646 which NO open artifact carries.
    # Row STAYS OPEN, fenced by open #6057; D167 (zero builders in sobelow vein) HOLDS.

## Gating classification
    #6057 is OPEN (human security-waiver gate) — charter line 2335 "HUMAN-GATED — leave open".
    Row lives in the D167 zero-builders sobelow vein (hard commitment) => NOT offline-buildable.
    Resolution = a reconcile PR merges (re-anchor all 6 to current lines) + #6057 gate resolved +
    next api PR Sobelow green. All CI/human-gated. Do NOT close by evidence in wave 31.
