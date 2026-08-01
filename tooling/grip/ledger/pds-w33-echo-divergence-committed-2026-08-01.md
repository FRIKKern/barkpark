# PDS wave 33 — echo divergence survives commit; two divergence classes, not one

Re-derivation recipes for the verifier finding that the task-ledger write family's
`{:ok, %{doc | content: …, rev: …}}` receipt is (a) deterministically one write
stale in `updated_at`, OUTSIDE any sandbox transaction, and (b) structurally unable
to carry `documents`' GENERATED-STORED mirror columns.

Harnesses live in the session scratchpad
(`/private/tmp/claude-501/-Volumes-SATECHI-github-barkpark/47ba8708-cd1d-47ac-93d4-7cb707cf3e3c/scratchpad/`)
and are reproduced by the commands below.

## R1 — in-sandbox baseline (wave 32 harness, re-run unchanged)

    cd /Volumes/SATECHI/github/barkpark/api && MIX_ENV=test mix test \
      $SCRATCH/echo_divergence_test.exs

Expect: CLAIM / STAMP / CLOSE each report exactly one divergent field, `:updated_at`;
`rev` and `content` byte-equal.

## R2 — COMMITTED mode (no wrapping transaction) + do_renew + move-noop

    cd /Volumes/SATECHI/github/barkpark/api && MIX_ENV=test mix test \
      $SCRATCH/echo_divergence_committed_test.exs

The module uses `use ExUnit.Case` (NOT DataCase) and
`Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)` in `setup_all`, so every write commits.
Expect: CLAIM / RENEW / STAMP / CLOSE struct-divergent `[:updated_at]` and
wire-divergent (`Params.render_doc`) `[:updated_at]`; MOVE noop arm `[]` — the one
honest arm, because it performs no write and returns the struct it read.
Each verb's echoed `updated_at` equals the PREVIOUS verb's stored value.

## R3 — cascade_unblock (close.ex ~:802) reaches the PubSub/SSE wire

    cd /Volumes/SATECHI/github/barkpark/api && MIX_ENV=test mix test \
      $SCRATCH/echo_divergence_cascade_test.exs

Subscribes to `documents:production` and closes a blocker so the dependent flips
blocked→open. Expect: broadcast `.doc.updated_at == pre-close stored value` and
`!= post-close stored value`. That arm's reconstruction never returns to the HTTP
caller — it is broadcast (`Barkpark.Content.Broadcast` copies `doc.updated_at`
into `msg.doc` verbatim).

## R4 — GENERATED STORED mirror columns are unrecoverable by reconstruction

    cd /Volumes/SATECHI/github/barkpark/api && MIX_ENV=test mix test \
      $SCRATCH/echo_divergence_generated_test.exs

Reproduces the family's exact write shape on a `post` whose `content.slug` /
`author` / `category` change. Expect `slug_text` / `author_text` / `category_text`
all `equal=false` between echo and stored while `content` and `rev` are equal.
No live TASK arm reaches this (task arms only write kind/claim/labels/criteria keys),
so this is the CLASS proof, not a live-path proof.

## R5 — trigger / deferred-constraint surface on `documents`

    git grep -rnE 'CREATE TRIGGER|EXECUTE FUNCTION|EXECUTE PROCEDURE' origin/main -- api/priv/repo/migrations
    git grep -rn 'DEFERRABLE' origin/main -- api/priv/repo/migrations

Exactly one trigger writes `documents`: `revisions_bind_document`
(`api/priv/repo/migrations/20260719010000_add_cycle_correction_quarantine_promotion.exs:322`),
AFTER INSERT ON `revisions`, setting `current_revision_id` / `released_revision_id`.
The task CAS arms insert mutation_events, not revisions, so it does not fire for them
(R2 shows `current_revision_id` nil throughout and never in the divergent set).
No `DEFERRABLE` constraint exists on `documents` — every DEFERRABLE hit is on the
`cycle_*` / `epic_*` ledger tables. So no commit-time effect was hidden by R1's
in-transaction re-read; R2 confirms this by measuring after commit.

## Root cause (single line, nine call sites)

Every arm writes `set: [content: …, rev: …, updated_at: DateTime.utc_now()]` and then
returns `%{doc | content: new_content, rev: new_rev}` — `updated_at` is deliberately
set in the UPDATE and deliberately absent from the reconstruction.
