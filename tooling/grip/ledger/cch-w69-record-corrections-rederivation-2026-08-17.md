# cch wave 69 — record-corrections re-derivation recipe (2026-08-17)

Verifier packet [record-corrections]. Every claim below re-derives from these commands alone.
All charter line numbers are against `origin/main` at the time of writing; re-anchor by grep, never
quote a line number without re-running the grep.

## 1. D830 — does it carry the latest-per-name rule the baseline sentence cites? YES

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | sed -n '1200p'

Decisive clause (verbatim): `the re-run on the SAME sha reconciled at 06:56; read latest-per-name or
you report a superseded verdict`. D830 also fixes the honest shape as `THREE rendered green + one
PR-only, never "4/4"` and budgets `~30 min per slice merge`.

CAUTION: D830's own stale-verdict figure is `still 19 rows`; the wave-69 digest measured 16 with cch
owning 6. Re-count before quoting either.

## 2. D833 — does its tail order the independent second review? YES

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | sed -n '1203p'

Tail (verbatim): `HIGH-FLIP-RISK: TENANCY — independent second review before merge. #10944 is closed
as superseded naming the landing PR (also −1 on the stale-verdict population).`

## 3. The stale "still owed" sentences — THREE, not two

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \
      | grep -n 'second review\|SECOND reviewer\|independent second'

- **1203** (D833 tail, above) — directive form, satisfied in fact.
- **1244**: `independent second reviewer is warranted before merge (manual lead dispatch; this
  workflow spawns one).` — wave-68 HIGH-FLIP-RISK block for S3.
- **3433-3434** (wave-68 wave-log, S3 → #11708): `**and an independent SECOND reviewer before merge
  is still owed — manual lead dispatch.**`

All three are stale THE OTHER WAY: the review WAS delivered. `#11708` review2 comment
`2026-08-17T08:28:17Z`, merged `2026-08-17T08:30:00Z` — pre-merge by 1m43s.

    gh api repos/FRIKKern/barkpark/issues/11708/comments --jq '.[]|"\(.created_at) \(.body[0:80])"'
    gh pr view 11708 --repo FRIKKern/barkpark --json mergedAt --jq .mergedAt

NOT stale, do not touch: line **3550** (wave 67, `#11540/#11552/#11553`) — those three carry ZERO
formal reviews AND ZERO review2 comments, so that sentence is honest as written.

    for n in 11540 11552 11553; do gh api repos/FRIKKern/barkpark/pulls/$n/reviews --jq 'length'; \
      gh api repos/FRIKKern/barkpark/issues/$n/comments --paginate \
        --jq '[.[]|select(.body|test("Independent second review";"i"))]|length'; done

## 4. F1 — the variant-loop label is swallowed. CONFIRMED, and the line is 92-93, not 91-92

    git show origin/main:cloud/test/barkpark_cloud/registry_custom_host_test.exs | sed -n '92,93p'

    assert {:error, :taken} = Registry.set_custom_host(thief, host),
           "#{label}: stored url #{stored} did not hold #{host}"

`assert/2` evaluates its first argument, so the match raises `MatchError` before the message can
render. Proof (self-contained, no repo deps):

    cat > /tmp/f1_probe.exs <<'EOF'
    ExUnit.start()
    defmodule F1Probe do
      use ExUnit.Case, async: true
      test "swallowed" do
        label = "mixed case"
        assert {:error, :taken} = {:ok, :attached}, "#{label}: stored url did not hold host"
      end
    end
    EOF
    elixir /tmp/f1_probe.exs

Output: `** (MatchError) no match of right hand side value: {:ok, :attached}` — the label never
renders. The `assert/1` control in the same probe prints `left:`/`right:` correctly.

Blast radius of the class in `cloud/test` — FOUR sites:

    git grep -n -E 'assert +\{[^}]*\} *=.*\),$' origin/main -- 'cloud/test/**/*.exs'

`billing_lifecycle_test.exs:669`, `registry_custom_host_test.exs:92`,
`sites/auto_deploy_worker_test.exs:461`, `sites_deploy_test.exs:324`. Only :92 sits in a variant
loop where the label is the SOLE discriminator (all four variants share one stacktrace line), so
only :92 loses information a human needs.

## 5. The review-record gap — 10/10 wave-68 PRs carry zero formal reviews

    for n in 11694 11696 11697 11700 11706 11708 11710 11711 11716 11723; do \
      printf '%s formal=' $n; gh api repos/FRIKKern/barkpark/pulls/$n/reviews --jq 'length'; done

All ten answer `0`. Inline review comments (`/pulls/N/comments`) are also `0` on all ten.
Issue-comment second reviews exist on FIVE: 11694 (REQUEST-CHANGES + lead remedy), 11696, 11697,
11700 (+ lead remedy), 11708. So the gap is **five delivered-but-invisible reviews**; 11706, 11710,
11711, 11716, 11723 have no second review in any surface.

    for n in 11694 11696 11697 11700 11706 11708 11710 11711 11716 11723; do printf '%s ' $n; \
      gh api repos/FRIKKern/barkpark/issues/$n/comments --paginate \
        --jq '[.[]|select(.body|test("Independent second review|review2-";"i"))]|length'; done

## 6. Why a "use formal reviews" doctrine note cannot simply be issued

Repo-wide prevalence, 40 most recent merged PRs: `with_formal_reviews=0`.

    gh pr list --repo FRIKKern/barkpark --state merged --limit 40 --json number --jq '.[].number' \
      | while read n; do gh api repos/FRIKKern/barkpark/pulls/$n/reviews --jq 'length'; done | sort | uniq -c

Every PR is authored by `FRIKKern` and the only credential present is `FRIKKern`:

    gh pr view 11708 --repo FRIKKern/barkpark --json author --jq .author.login
    gh api user --jq .login

GitHub refuses `APPROVE`/`REQUEST_CHANGES` from a PR's own author, so the only formal-review event
available to this fleet is `event: COMMENT` on `POST /repos/:o/:r/pulls/:n/reviews` — which DOES
render in `/pulls/N/reviews`. That is the remedy shape; a note demanding APPROVE reviews would be
unbuildable with one identity. (The self-approval refusal is GitHub-documented and was NOT tested
here — testing it requires a write to a shared PR.)

## 7. Bonus: #11706 is MERGED, so the wave-69 sequencing law's premise moved again

    gh pr view 11706 --repo FRIKKern/barkpark --json state,mergedAt

`MERGED` at `2026-08-17T10:00:27Z`. All ten wave-68 PRs are merged; no round-2 gate on #11706
survives.
