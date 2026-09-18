defmodule BarkparkCloud.Repo.Migrations.AddTriggerAndActorToDigestRuns do
  use Ecto.Migration

  # gr-backlog-operator-digest-send — WHOSE HAND, on the run record.
  #
  # `digest_runs` has accounted every fleet-digest run since dr-w27, and until
  # now every row had exactly one possible cause: the 06:00Z cron tick. The
  # operator send-now route (POST /v1/operator/digest/send) adds a SECOND cause,
  # and a run table that cannot tell the two apart turns "who mailed the fleet at
  # 14:07?" into a question with no answer on the only sink that survives a
  # container recreate.
  #
  # `trigger` is NOT NULL with a `"scheduled"` default so every historical row —
  # all of which WERE the cron tick — carries the true word rather than a NULL
  # that a reader would have to guess about. The backfill is the default itself.
  #
  # `actor_user_id` is NULLABLE and `nilify_all`: a scheduled run has no human,
  # and an operator's account deletion must not erase the fact that the send
  # happened (the same ruling `audit_events.actor_user_id` makes).
  #
  # NO RECIPIENT COLUMN, and that is deliberate — `DigestRun`'s moduledoc rules
  # that this cross-team record stores counts and never addresses. The operator's
  # own id is not an audience, it is the actor.
  #
  # Expand-safe: two additive columns, one with a default, on a table the old
  # slot writes with an explicit column list.
  def change do
    alter table(:digest_runs) do
      add :trigger, :string, null: false, default: "scheduled"

      add :actor_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all),
          null: true
    end

    create index(:digest_runs, [:trigger, :inserted_at])
  end
end
