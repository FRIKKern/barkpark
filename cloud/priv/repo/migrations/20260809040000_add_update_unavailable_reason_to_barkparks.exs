defmodule BarkparkCloud.Repo.Migrations.AddUpdateUnavailableReasonToBarkparks do
  @moduledoc """
  cch-w58 (S1): THE ONE QUESTION PER HOUR THAT CAN LOSE STOPS BEING ASKED INTO
  A VOID.

  ## The byte that was read and discarded

  `Registry.refresh_update_status/1` decrypts each row's admin token and GETs
  `<bp.url>/v1/admin/self-update` every hour (`UpdateStatusWorker`,
  `{"17 * * * *"}`). Run-proved this wave against guerrilla AND prod
  89.167.28.206: that route answers 401 with no token, 401 with a bogus bearer,
  200 with a valid one — 328 bytes, ~70ms, read-only. A 401 is therefore a HARD
  REFUTATION: whatever answers at that address does not hold this row's
  credential.

  Before this column, the answer was collapsed by a bare `_ ->` arm into
  `update_state: "unknown"`, and the reason atom was returned to a worker that
  ignores it. Five worlds rendered as one word:

      401  the box refuses OUR credential          → identity_refused
      403  the box refuses this principal          → forbidden
      404  a PRE-FEATURE box, no such route        → no_self_update_route
      {:error, _}  no response at all              → unreachable
      anything else / an unreadable 200            → instance_error

  ## Why 404 is its own rung and not "refused"

  A pre-feature box has refused nothing — it has never heard of the route. The
  function's own @doc already said so. Folding a 404 into "refused" is exactly
  the conflation that made `verify_reachable` useless (charter D684), and a
  later slice that refuses on `identity_refused` would, with the fold, cut off
  every box that is merely old.

  ## Why NULL is load-bearing

  NULL means "no refusal on file": every row predating this column, and every
  row whose last check was a clean 200 — `persist_update_check/2` writes nil so
  a stale refusal cannot survive a recovery. There is nothing to backfill: a
  pre-sweep row is honestly un-judged until the next hourly tick writes it. A
  default of `'instance_error'` would mint a fabricated accusation on six live
  rows.

  ## Why this ALTER is safe on the live table

  `barkparks` is a control-plane table of SIX rows. The column is NULLABLE with
  NO default, so the `ALTER` is a catalog-only update — no table rewrite, no
  per-row work. No index: nothing queries this column yet, and an index with no
  reader is write cost for nothing. This slice ADDS NO REFUSAL — nothing changes
  about which addresses receive the credential; the verdict merely becomes
  readable.

  MIGRATION ORDER: the LEAD orders this one, and `cloud/**` auto-deploys on
  merge. It assumes no deploy window.
  """

  use Ecto.Migration

  def change do
    alter table(:barkparks) do
      add :update_unavailable_reason, :string
    end
  end
end
