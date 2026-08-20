defmodule BarkparkCloud.Repo.Migrations.AddDeferralStructureToDeployments do
  @moduledoc """
  deploy-reliability W12 (S6): THE DEFERRAL STOPS BEING PROSE, AND THE PRODUCER
  THAT MINTS NO ROW STARTS SPEAKING.

  ## Why columns at all — the producer and the reader talk in English today

  A deferral's position in its chain exists ONLY inside an English sentence:
  `Sites.Deploy.defer/3` interpolates `" — deferred: refusal 3 of 12 in this
  site's current chain"` into `failure_reason`, and the Go CLI READS IT BACK
  WITH A REGEX (`internal/cli/cloud_site_cmd.go` `siteDeferralChainRe`). Every
  aggregate over chain depth — "how deep do capacity chains actually get before
  a box frees up" — is therefore a `LIKE`/regex over prose, and one reworded
  clause silently zeroes it.

  `deferral_depth` / `deferral_bound` / `deferral_cause` are that same fact as
  data. THE SENTENCE STAYS: Vercel keeps `readyStateReason` beside `readyState`
  for exactly this reason — the prose is the operator's, the columns are the
  aggregate's, and neither is a substitute for the other. Nothing READS the new
  columns yet (`DeployLedger.classify_deferred/2` still classifies off the
  reason string, deliberately untouched this wave); this migration and its
  writer are the producing half.

  ## The counter is for the deferral that mints NO ROW

  `Sites.AutoDeployWorker.defer_behind_running_build/2` is the control plane
  refusing the second concurrent build itself, and it writes NO deployment row —
  correctly: the active-deployment index refused to mint one, and the row in
  flight is a REAL build that must not be relabelled a deferral. So the attempt
  has nowhere to be counted, and it is invisible to every deployment-stream
  aggregate.

  Measured from Oban rather than guessed: in the twelve hours 2026-08-06
  08:00-20:00Z there were 2,256 `AutoDeployWorker` jobs against 1,052 deployment
  rows — 1,204 ATTEMPTS THAT MINTED NO ROW against 277 counted deferrals
  (4.35:1). Since 22:00Z the same ratio is 0.086:1 and zero per minute. The gap
  is DORMANT, not fixed: it is a function of publish load against build
  duration, so it returns exactly when the number matters. It is quoted as
  "attempts that minted no row" and never as "uncounted deferrals" — the
  `{:duplicate, %{status: "queued"}}` re-drive arm shares the shape and the two
  are indistinguishable in the DB.

  `coalesced_attempts` / `coalesced_last_at` hang that count on the IN-FLIGHT
  row the attempt coalesced onto. That row is the only truthful place for it:
  the attempt did not produce a build, it JOINED one.

  ## Why this ALTER is safe on the live table

  `deployments` on cloud-db-1 is ~30,633 rows / 45 MB. Every column here is
  NULLABLE, and the two with a default carry a CONSTANT default — since
  PostgreSQL 11 that is a catalog-only `ALTER`, no table rewrite and no per-row
  work, so the ACCESS EXCLUSIVE lock is held for the duration of a catalog
  update rather than a scan of 45 MB. For scale, the wave-11 index build on this
  same table (which DOES scan it) measured 40.8 ms. No index is created here:
  nothing queries these columns yet, and an index with no reader is write cost
  for nothing — the next wave adds one WITH the query that justifies it.

  The lock still queues behind any long-running statement on `deployments`, so
  apply it the way the wave-11 index was applied, not during a deploy storm.
  """

  use Ecto.Migration

  def change do
    alter table(:deployments) do
      # THE CHAIN, AS DATA. Written by `Sites.Deploy.defer/3` at the same site
      # that writes the sentence, on `deferred` rows only — NULL everywhere else
      # (including on every pre-W12 deferred row: this is not backfilled, since
      # the prose it would be parsed out of is exactly the coupling being ended).
      #
      #   * depth — this refusal's 1-based position in the site's CURRENT chain.
      #   * bound — the cause's OWN budget (12 capacity / 6 busy), never a
      #     literal: a column that hardcoded either would misstate the other.
      #   * cause — the chain's identity. Two deferrals of DIFFERENT causes are
      #     not one chain, which is why depth is meaningless without it.
      add :deferral_depth, :integer
      add :deferral_bound, :integer
      add :deferral_cause, :string

      # THE ATTEMPTS THAT MINTED NO ROW, counted against the build they
      # coalesced onto. Default 0 so a fresh row reads "no attempts coalesced"
      # rather than "unknown"; NULLABLE so the 30,633 existing rows stay
      # untouched and honestly unknown (they predate the counter — a backfilled
      # 0 would claim a measurement nobody took).
      add :coalesced_attempts, :integer, default: 0
      add :coalesced_last_at, :utc_datetime_usec
    end
  end
end
