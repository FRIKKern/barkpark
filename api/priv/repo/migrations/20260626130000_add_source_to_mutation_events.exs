defmodule Barkpark.Repo.Migrations.AddSourceToMutationEvents do
  use Ecto.Migration

  # Additive origin tag on every mutation event. Local-origin writes
  # (api/studio/cli/worker) are pushable; PULL-applied writes are stamped
  # "sync" so the push outbox can EXCLUDE them (echo-suppression, no ping-pong).
  # Existing rows predate the column and are indistinguishable (some are
  # PULL-applied clones), so they default to "api". First-enable ping-pong is
  # prevented NOT by this source tag but by PushCursor.bootstrap_if_absent/2
  # seeding the push cursor past all pre-enablement history (F1).
  def change do
    alter table(:mutation_events) do
      add :source, :string, null: false, default: "api"
    end
  end
end
