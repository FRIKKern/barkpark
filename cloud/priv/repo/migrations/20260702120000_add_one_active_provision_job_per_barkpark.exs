defmodule BarkparkCloud.Repo.Migrations.AddOneActiveProvisionJobPerBarkpark do
  use Ecto.Migration

  # dwb-11 money-path backstop: at most ONE ACTIVE (pending|claimed) job of each
  # kind per barkpark, enforced by the database.
  #
  # WHY: the Remove path (`enqueue_deprovision_job/1`) already dedupes with an
  # app-level `active_deprovision_job?/1` check, but that is a check-THEN-insert —
  # two concurrent DELETEs both read "no active job" and both insert. Worse, the
  # RETRY path (`POST /v1/barkparks/:id/retry`) had NO dedup at all: two rapid
  # clicks both see the last job `failed`, both enqueue a fresh `pending`
  # provision, two workers claim them, and the customer is billed for TWO boxes
  # from one intent. This partial unique index closes both races atomically — the
  # SAME idiom the launch path already relies on (`barkparks_url_unique_idx`,
  # `subscriptions_one_live_per_team_idx`): let Postgres serialize the contention,
  # the loser's insert raises a unique violation the context translates to an
  # idempotent no-op.
  #
  # Scoped by `kind` so a `provision` and a `deprovision` job may coexist; the
  # WHERE clause covers only the in-flight states, so terminal
  # `succeeded`/`failed` rows never block a fresh enqueue (a legitimate retry
  # after a failure still works).
  #
  # Reversible: the down side drops the index.
  def change do
    create unique_index(:provision_jobs, [:barkpark_id, :kind],
             where: "status IN ('pending', 'claimed')",
             name: :provision_jobs_one_active_per_barkpark_kind_idx
           )
  end
end
