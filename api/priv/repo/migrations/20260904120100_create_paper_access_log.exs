defmodule Barkpark.Repo.Migrations.CreatePaperAccessLog do
  @moduledoc """
  Edit-on-the-link slice 4 (task-e99a8e946f80f52c) — the append-only view/edit
  trail for a paper.

  `revisions` records what CHANGED, and only when something did. It cannot
  answer "who has been reading this link", which is the question a shared
  paper actually raises. This table answers it: one row per connected reader
  mount ("view") and one per accepted block op ("edit"), carrying the same
  actor triple the revision stamp uses.

  Anonymous access is logged with `actor_kind = "anonymous"` and a NULL
  `actor_id` — counted, never identified. That is the whole privacy posture of
  the table: it never learns anything about a visitor it was not already told.

  ## Shape

  Implicit `bigserial` primary key — monotonic insert order IS the read order,
  so "newest first" needs no tiebreaker beyond it. `inserted_at` only (no
  `updated_at`): an append-only row is never updated.

  `workspace_id` is a plain `:binary_id`, deliberately NOT a foreign key. The
  log outlives the scopes it names: deleting a workspace must not cascade-erase
  the record of who read its papers, and an FK here would either block the
  delete or silently take the trail with it.

  ## Retention

  Swept by `Barkpark.Content.Workers.PaperAccessSweeper` (Oban cron, daily),
  which deletes rows older than `:paper_access_log_ttl_days` (default 90). The
  index below is what makes both the read surface
  (`GET /v1/papers/:slug/access`) and the sweep's range delete cheap.
  """
  use Ecto.Migration

  def change do
    create table(:paper_access_log) do
      add :workspace_id, :binary_id
      add :dataset, :string, null: false
      add :slug, :string, null: false
      # "view" | "edit"
      add :action, :string, null: false
      # "user" | "api_token" | "share" | "anonymous"
      add :actor_kind, :string, null: false
      add :actor_id, :string
      add :actor_label, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # The read surface's exact key: one paper, one tenant, newest first.
    create index(:paper_access_log, [:workspace_id, :slug, :inserted_at])
    # The sweeper's key: a pure age range delete across every tenant.
    create index(:paper_access_log, [:inserted_at])
  end
end
