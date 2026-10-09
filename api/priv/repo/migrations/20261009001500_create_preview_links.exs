defmodule Barkpark.Repo.Migrations.CreatePreviewLinks do
  @moduledoc """
  task-6812c3100d7aedbc — shareable preview links for J64's share menu.

  A `preview_links` row is a direct, revocable `/sp/<raw_token>` link to ONE
  document, draft OR published. It is a SIBLING of `share_links` (P7), not an
  extension: `Barkpark.Sharing.Links.create/1` unconditionally strips a
  `drafts.` prefix off `ref_id` (ruled `arpss-w8-bl-share-link-drafts-ref-id`),
  so that table can never name an unpublished row. This table's `doc_id` is
  stored EXACTLY as minted — a `drafts.`-prefixed id is kept, on purpose,
  because serving the draft is the whole point.

  Same hashed-at-rest shape as `share_links`: only `token_hash` (SHA256) is
  persisted, never the plaintext. `workspace_id` and `project_id` are required
  (mirrors `task-2da739b78e938be0` — an unbound row is unrevokable by scope).

  `expires_at` is `null: false` here, unlike `share_links.expires_at` — a
  draft preview is more sensitive than a published-content share, so every
  link is minted with a TTL; there is no "never expires" link to this surface.
  """
  use Ecto.Migration

  def change do
    create table(:preview_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :string, null: false
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all)
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)
      add :dataset, :string, null: false, default: "production"
      # the RAW doc_id, drafts. prefix kept as given — see moduledoc.
      add :doc_id, :string, null: false
      add :ref_type, :string, null: false
      add :label, :string
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:preview_links, [:token_hash])
    create index(:preview_links, [:workspace_id, :project_id, :dataset, :doc_id])
  end
end
