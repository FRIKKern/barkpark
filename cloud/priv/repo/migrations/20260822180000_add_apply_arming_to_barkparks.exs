defmodule BarkparkCloud.Repo.Migrations.AddApplyArmingToBarkparks do
  @moduledoc """
  THE ARMING PROBE LANDED ON THE BOX AND NOTHING READ IT.

  ## The byte that arrives every hour and is discarded at the match

  `GET /v1/admin/self-update` gained a top-level `apply_enabled` key (#12995),
  reporting the box's `Runner.enabled?/0` — the RUNNING BEAM's boot-frozen
  value, which is the exact input the one-click apply POST's 503 is decided
  from. `Registry.refresh_update_status/1` already GETs that route hourly with
  the stored admin token and already decodes the body, but matched

      {:ok, %{"check" => %{} = check}} -> persist_update_check(bp, check)

  and `apply_enabled` is a SIBLING of `"check"`, so it was dropped at the match.
  No new request, no new credential, no new schedule: only somewhere to put it.

  ## Why the fleet has never had this roster

  Before `apply_enabled`, the ONLY way to learn a box was unarmed was to POST —
  and that POST's 503 `feature_not_configured` is what `AutoupdateRolloutWorker`
  answers with `Registry.pause_autoupdate/1`, a pause NO code path clears (the
  sole writer of `autoupdate_paused: false` is the admin-and-audited
  PATCH /v1/barkparks/:id/autoupdate). Asking the question permanently paused
  the box that answered it, so the question was never asked, and the standing
  retro-arm item is still worded as a GUESS ("every box provisioned before
  2026-08-14 14:32") instead of a list. This column is what turns that
  timestamp heuristic into a measured roster.

  ## THREE WORLDS, AND NULL IS THE THIRD — NOT A SYNONYM FOR FALSE

      'armed'    200, and the body says apply_enabled: true
      'unarmed'  200, and the body says apply_enabled: false   <- ACTIONABLE
      NULL       no apply_enabled key at all (a PRE-#12995 box), or never asked

  A pre-#12995 box that is genuinely armed carries no such key. Defaulting the
  absent key to `false` would render it IDENTICAL to a measured unarmed box and
  put correctly-armed boxes on the retro-arm worklist — destroying the only
  reason the roster exists. This is the same discipline `update_unavailable_reason`
  already keeps for a 404 (`no_self_update_route` is its own rung, not "refused"),
  and the same reason NULL is load-bearing there.

  So: NULLABLE, NO DEFAULT, and nothing to backfill. A row predating this column
  is honestly un-measured until the next hourly tick reads a body for it. A
  default of `'unarmed'` would mint a fabricated accusation against every live
  box at once.

  ## Why the clock is a SECOND column and not the existing one

  `update_checked_at` is stamped on six of the nine unknown rungs — i.e. on
  checks that never read a body at all. `apply_arming_checked_at` is stamped
  ONLY when a 200 body was actually decoded and the arming question was actually
  answered (cch-w65's rule: the clock records a check that was ACTUALLY MADE).
  It is what separates "measured unknown an hour ago" (checked_at set, arming
  NULL — a pre-feature box) from "never measured" (both NULL), and it is why a
  failed check may leave a previously measured `armed`/`unarmed` STANDING rather
  than erasing it: a box that stops answering does not become un-measured, and
  wiping the column on every outage would empty the roster exactly when an
  operator reaches for it.

  ## Why this ALTER is safe on the live table

  `barkparks` is a small control-plane table — the last census of prod counted
  EIGHT rows (charter D789, 2026-08-09; not re-measured here, and this slice does
  not depend on the number). Both columns are NULLABLE
  with NO default, so the `ALTER` is a catalog-only update — no table rewrite, no
  per-row work. No index: the only reader is a full roll-up over the whole table
  (`GET /v1/operator/fleet` maps `Registry.all_barkparks/0`), and an index with
  no selective reader is write cost for nothing.

  THIS SLICE ADDS NO REFUSAL AND SENDS NOTHING NEW. Nothing POSTs to a box,
  nothing clears an `autoupdate_paused`, nothing arms anything. The state merely
  becomes readable; acting on the roster is a separate, human-gated movement.

  MIGRATION ORDER: the LEAD orders this one, and `cloud/**` auto-deploys on
  merge. It assumes no deploy window.
  """

  use Ecto.Migration

  def change do
    alter table(:barkparks) do
      add :apply_arming, :string
      add :apply_arming_checked_at, :utc_datetime_usec
    end
  end
end
