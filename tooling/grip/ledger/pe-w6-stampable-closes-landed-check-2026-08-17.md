# pe-w6 stampable-closes — landed-check re-derivation (2026-08-17)

Verifier prep for the lead's close list. Three rows are stampable; each recipe below re-derives its close-ready evidence.

## Row 1 — pe-w4-bpml-fix-11814-fixtures (c3: landed-check must RUN, not "merged alone")

SSH-free half (PASSES — paste as c3 evidence):

    curl -s 'https://guerrilla.barkpark.cloud/papers/hobby-hardening-http-edge/source?format=bpml'
    # → {"error":{"code":"bpml_unprintable",...,"message":"BPML printer: block type \"toc\" is outside the BPML kernel vocabulary (kind: block)"}}
    curl -s -o /dev/null -w '%{http_code}' 'https://guerrilla.barkpark.cloud/papers/hobby-hardening-http-edge/source?format=bpml'   # → 422
    curl -s -o /dev/null -w '%{http_code}' https://guerrilla.barkpark.cloud/api/schemas                                            # → 200

The 422 envelope carrying the "(kind: block)" prose wording is the behavioral proof guerrilla serves post-#11814 code (#11814 MERGED 2026-08-17T15:39:32Z).

SSH-required half (STILL the human's — guerrilla has NO /health git_sha route, per D25/D32):
`.instance-deploy-last == <#11814 merge sha>` + active-slot `.slots/<active>.sha == same` + `systemctl is-active barkpark`. Resolve active slot from the Caddy upstream port (GREEN :4001 per D32); the D17-era rehydrate recipe is a live hazard, do not follow.

## Row 2 — pe-w1-bundle-table-scroll-chrome-gap (via #11759)

    gh pr view 11759 --json state,mergedAt   # → MERGED 2026-08-17T11:09:34Z
    gh issue view 11602 --json state,closedAt # → OPEN, closedAt null

FINDING: the fix merged (#11759, "parity gate covers every evidence-band breakout class … table allowlist retired") but issue #11602 ("Standalone editor bundle lacks the reader's .bp-table scroll chrome") is STILL OPEN. Lead should close #11602 referencing #11759 when stamping this row.

## Row 3 — paper-excellence-wave-3-log (#11788 + charter D16–D24)

    gh pr view 11788 --json state,mergedAt                                          # → MERGED 2026-08-17T13:10:23Z
    git show origin/main:.claude/workflows/bp-paper-excellence-charter.md | grep -nE '^\- \*\*D(1[6-9]|2[0-4]) '   # → 9 lines, D16 through D24 present

origin/main HEAD at check: f523465856dc0d31782da233f1c31f2b1cdb5468. Charter D16–D24 are on origin/main; #11788 landed them. Row is stampable clean.
