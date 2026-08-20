<!-- doc-tier: cold | canonical-for: felix-w25-backlog-row-verdicts | budget: 2000tok -->
# Felix W25 — backlog-row verdicts (non-Sobelow), re-derived against origin/main 2026-08-17

Verifier: backlog-row-verdicts lane. Every verdict below is a per-row disposition against
`origin/main` with the paying/refuting evidence and its re-run command. These feed the
same honest-ledger batch-close as the Sobelow rows.

## (a) D7 phantom-media — VERDICT: PAID (commit-evidence upgrade)

Row: delete_workspace resurrected media_file rows pointing at purged blobs.
PAID by **#2955 / 38c68c81fd** "fix(media): defer phantom-media delete effects until
workspace-delete commits". Both string probes collapse to this single commit — the
tenancy.ex delete path is now DB-writes-only inside the tx, side effects DEFERRED to commit.

Re-run:

    git log origin/main -S 'DB-writes-only' --oneline -- api/lib/barkpark/tenancy.ex
    git log origin/main -S 'DEFERS' --oneline -- api/lib/barkpark/tenancy.ex

Both print exactly: `38c68c81fd fix(media): defer phantom-media delete effects until workspace-delete commits (#2955)`.
Upgrades the prior doc-evidence to commit-evidence.

## (b) task-felix-w13-bounded-read-watch — VERDICT: STILL-LIVE (watch-item, not-ripe). Direction's "staleness_live no longer exists" is REFUTED.

Lifecycle `considering` (watch-item, ruled not-ripe W13). The row watches TWO unbounded
`Document |> where |> Repo.all` reads with no LIMIT:
1. `plugins/onixedit/web/staleness_live.ex` **load_books/0** — DELIBERATE flat-posture admin
   ONIX-drift console; bounding it fails CLOSED (barkpark-s6t1). connected?-gated (#2402).
2. `tasks/board.ex` **load_task_docs/1** — whole task corpus; admin-only, connected?-gated.
   WEAK ripeness (the board.ex:210 unbounded read the fresh delta-audit slices).

Both symbols EXIST on main and are STILL UNBOUNDED. staleness_live.ex exists (blob 345ebbd);
load_books at :237, `Repo.all()` at :241 with no `limit(`. board.ex load_task_docs at :210,
`Repo.all()` at :212. The direction's "staleness_live no longer exists" garbles this WATCH row
(which names load_books/0 as an INTENTIONAL read, not a defect) with the SEPARATE fresh finding
targeting the SAME FILE's OnixEdit raw `Repo.update` at staleness_live.ex:109 — a different symbol,
different class. The file is very much on main.

Re-run:

    git ls-tree origin/main -- api/lib/barkpark/plugins/onixedit/web/staleness_live.ex
    git grep -n 'def load_books\|Repo.all\|limit(' origin/main -- api/lib/barkpark/plugins/onixedit/web/staleness_live.ex
    git grep -n 'load_task_docs\|Repo.all\|limit(' origin/main -- api/lib/barkpark/tasks/board.ex
    bp task get task-felix-w13-bounded-read-watch

## (c) task-felix-w21-bl-readiness-sobelow-inline — VERDICT: INDEPENDENTLY LIVE (NOT superseded by w23/w24 inline migrations)

Row: migrate codex readiness.ex:42 `System.cmd` off the line-anchored `.sobelow-skips`
fingerprint onto a durable inline `# sobelow_skip ["CI.System"]` comment; delete the stale skip line.

On main readiness.ex:42 STILL carries a bare `System.cmd(path, ["--version"], stderr_to_stdout: false)`
with NO inline sobelow_skip comment. The skip is STILL in the line-anchored `.sobelow-skips:28`
(fingerprint `6CC3DE8` — the SAME fingerprint the task named at :71; the line merely shifted 71→28).
The w23/w24 inline-annotation migrations (122 inline skips) did NOT sweep this site — it is the sole
holdout of the 7 bounded interop sites. Row premise holds; independently live, not superseded.

Re-run:

    git grep -n 'sobelow_skip\|System.cmd' origin/main -- api/lib/barkpark/studio_chat/runtime/codex/readiness.ex
    git grep -n 'readiness' origin/main -- api/.sobelow-skips

## (d) two W22 unknowns

### (d1) task-felix-w22-bl-codex-completion-deadbranch — VERDICT: STILL-LIVE (dead branch present)

chat_live.ex `handle_info({:studio_chat_runtime_event, %Event{kind: :turn_completed}}, socket)`
(~:1244-1247) carries:

    case socket.assigns.streaming do
      text when is_binary(text) and text != "" -> append_message(socket, :assistant, text)
      _ -> socket
    end

`streaming` is only ever assigned `nil` (:235 etc.) or `advance_streaming/2`'s result, which delegates
to `StreamTail.advance/3`. StreamTail state is a BARE MAP ("The state is a BARE MAP, never a struct" —
stream_tail.ex moduledoc :18). So `streaming` is never a binary → the `is_binary` clause CANNOT match →
DEAD BRANCH confirmed. Codex live-completion appends nothing from the socket accumulator; durable Recorder
path (its own runtime_text) is unaffected. Codex dark in prod (0/38) → latent severity.

Re-run:

    git show origin/main:api/lib/barkpark_web/live/studio/chat_live.ex | sed -n '1240,1250p'
    git show origin/main:api/lib/barkpark/studio_chat/stream_tail.ex | sed -n '14,20p'

### (d2) task-felix-w22-bl-webhook-body-rightsize — VERDICT: STILL-LIVE (bounded-but-oversized; row's fix-shape premise holds)

The github webhook path DOES carry a body cap: the global `Plug.Parsers` `length: 100_000_000`
in endpoint.ex:155 (bounded; `{:more}` → 413 before any controller). So NOT unbounded.
BUT wrong-sized for this path: ~101MB buffers UNAUTHENTICATED (parse_body runs in the Endpoint before
the router's `GithubWebhookSignature` HMAC), GitHub's real max delivery is 25MB, and
`pipeline :github_webhook` (router.ex:701-704) is `[:accepts json, GithubWebhookSignature]` ONLY —
NO RateLimit plug, while ~10 other pipelines carry `plug(BarkparkWeb.Plugs.RateLimit)`. Both halves of
the row's premise (oversized pre-HMAC cap + missing rate limit) hold on main.

Re-run:

    git show origin/main:api/lib/barkpark_web/endpoint.ex | sed -n '147,161p'
    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '701,704p'

## (e) task-felix-w20-fk-census-tripwire — VERDICT: DELIVERABLE LANDED / effectively PAID (task still marked open)

Row deliverable was ONE new file `cloud/test/barkpark_cloud/fk_census_test.exs`. That file EXISTS on
main (blob eeeb232), added by **#5920 / 851e06703c** "test(felix-w20): FK-abort scar-class tripwire for
cloud/ (mutation-proven)". Close-wording confirmed: it **rides the cloud test suite** — a cloud test file
run by cloud.yml's existing `mix test` job — NOT a dedicated yml step. `.github/` and `cloud/` carry no
`fk_census`-named workflow step; the only references are cross-mentions in sibling test files
(site_cascade_census_test.exs, router_sites_test.exs). The bp task is still `open` despite the deliverable
landing → ledger verdict PAID, task should close.

Re-run:

    git ls-tree origin/main -- cloud/test/barkpark_cloud/fk_census_test.exs
    git log origin/main --oneline -- cloud/test/barkpark_cloud/fk_census_test.exs | head -1
    git grep -n 'fk_census' origin/main -- cloud/ .github/
