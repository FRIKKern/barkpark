defmodule Barkpark.Repo.Migrations.CreateScheduledPublishes do
  @moduledoc """
  A publish of a document's draft at a future time (task-8e88b5539acafdae).

  The row records WHO scheduled it (`principal_type` + `principal_id`, plus the
  user a token acts for), because the publish runs as that person (owner
  decision 2026-10-10) and is refused if they can no longer write by then.
  `status` moves `scheduled` -> `published | cancelled | refused | failed`;
  `reason` says why for the last three.
  """
  use Ecto.Migration

  def change do
    create table(:scheduled_publishes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all)
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)
      add :dataset, :string, null: false
      add :type, :string, null: false
      # The PUBLISHED id; the draft published is `drafts.<doc_id>`.
      add :doc_id, :string, null: false
      add :publish_at, :utc_datetime_usec, null: false
      # Optional pin: publish only if the draft is still at this rev.
      add :draft_rev, :string
      add :principal_type, :string, null: false
      add :principal_id, :binary_id, null: false
      add :acting_user_id, :binary_id
      add :status, :string, null: false, default: "scheduled"
      add :reason, :string
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scheduled_publishes, [:workspace_id, :dataset, :doc_id])
    create index(:scheduled_publishes, [:status, :publish_at])

    # At most ONE pending schedule per document: the Studio footer shows "the"
    # schedule, and a second one would publish the same draft twice.
    create unique_index(:scheduled_publishes, [:workspace_id, :dataset, :type, :doc_id],
             where: "status = 'scheduled'",
             name: :scheduled_publishes_one_pending_per_doc
           )
  end
end
