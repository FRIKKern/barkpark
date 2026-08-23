defmodule Barkpark.Content.RevisionBindTriggerFreshnessTest do
  @moduledoc """
  Stale-trigger tripwire (pds-bl-tickets-local-otp28-divergence).

  ## The incident this prevents from recurring as a mystery

  PDS wave 22 saw 27 Tickets tests (plus ~10 more across QueryResolveTasks,
  ContentPubsubWorkspaceLeak, TicketRateLimit, BulldocsSessionsController,
  DocumentsRetrieverBoundedPool, ContentWorkspaceWriteScope, …) fail LOCALLY
  with `(Postgrex.Error) ERROR P0001 revision snapshot does not exactly match
  its document`, raised from `Content.Broadcast.save_revision/5`, while CI was
  green on the same commit. The leading hypothesis — an OTP 27 vs 28 JSON/map
  encoding divergence — was WRONG.

  The real cause: migration
  `20260719010000_add_cycle_correction_quarantine_promotion.exs` was edited IN
  PLACE across six commits on 2026-07-19. Its `barkpark_bind_document_revision`
  trigger function started out comparing `document.doc_id = NEW.doc_id`
  (no `drafts.`-prefix normalization) and `document.dataset_id =
  NEW.dataset_id` (strict — NULL never matches), and only the final version
  gained the `drafts.` CASE plus `IS NOT DISTINCT FROM` on
  dataset/dataset_id/workspace_id/status/content. Any long-lived database that
  ran the migration from a mid-day 2026-07-19 checkout is marked fully
  migrated (`mix ecto.migrations` shows nothing pending) yet keeps the EARLY
  trigger forever — and every draft-document `save_revision` then raises
  P0001. CI never sees it because CI migrates a fresh database, so it always
  gets the final text: the local-vs-CI gap is DATABASE STATE, not toolchain.

  Run-proof (2026-08-23, Elixir 1.19.5 / OTP 28): with the final trigger,
  thread_test.exs is 19/19 green; with the 2e0ca88c7a-era trigger installed
  into the same database, it is 19 tests / 16 failures — the exact wave-22
  signature — and a 70-test matrix over the other wave-22 modules goes
  25-failures red the same way. Restore the final text and everything is
  green again, same BEAM.

  ## What this test does

  It asserts the LIVE database's trigger function carries the final
  migration's arms. On a stale database the whole mystery collapses into THIS
  one named failure with the remediation in the message, instead of dozens of
  unrelated-looking P0001s.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Repo

  @remedy """
  Your database predates the final text of migration 20260719010000 (it was \
  edited in place on 2026-07-19; a database migrated from a mid-day checkout \
  keeps the early trigger while showing zero pending migrations). Every \
  draft-document save_revision then dies with `P0001 revision snapshot does \
  not exactly match its document` — the wave-22 \"27 Tickets failures\" \
  signature. Remediation: recreate the function from the current migration \
  text — copy the `CREATE FUNCTION barkpark_bind_document_revision` block \
  from api/priv/repo/migrations/20260719010000_add_cycle_correction_quarantine_promotion.exs \
  into psql as CREATE OR REPLACE FUNCTION (or `mix ecto.reset` the dev/test \
  database). This is NOT an OTP/Elixir divergence and NOT your regression.
  """

  test "the live barkpark_bind_document_revision trigger carries the FINAL migration text" do
    %{rows: [[src]]} =
      Repo.query!("SELECT pg_get_functiondef('barkpark_bind_document_revision()'::regprocedure)")

    # The three arms the 2026-07-19 in-place edits introduced. An early-variant
    # function is missing at least one of them (the 2e0ca88c7a original lacks
    # all three; the a0357fff38 intermediate lacks the IS NOT DISTINCT arms).
    assert src =~ "left(document.doc_id, 7) = 'drafts.'", @remedy
    assert src =~ "document.dataset_id IS NOT DISTINCT FROM NEW.dataset_id", @remedy
    assert src =~ "document.content IS NOT DISTINCT FROM NEW.content", @remedy
  end
end
