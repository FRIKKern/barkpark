defmodule Barkpark.Repo.Migrations.CreateShareLinks do
  @moduledoc """
  P7 — ITEM sharing (Google-Docs-style per-document links).

  A `share_links` row is a direct, revocable link to ONE item — a document
  (any type, incl. `paper`) or a media file — independent of section shares.
  The link `/s/<raw_token>` is self-contained: it carries its own tenant scope
  + item ref, so resolving it never depends on a `Barkpark.Sharing` section
  share. The raw token is shown once; only its SHA256 is stored.

  An item may have several links (a View link + an Edit link), so there is no
  uniqueness on the item ref — only on `token_hash`.
  """
  use Ecto.Migration

  def change do
    create table(:share_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :string, null: false
      # tenant scope the item lives in
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all)
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)
      add :dataset, :string, null: false, default: "production"
      # the item: kind = "doc" | "media"; ref_type = doc type (NULL for media);
      # ref_id = published doc_id / slug (docs) or media file id (media)
      add :kind, :string, null: false
      add :ref_type, :string
      add :ref_id, :string, null: false
      add :access, :string, null: false, default: "read"
      add :label, :string
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:share_links, [:token_hash])
    create index(:share_links, [:workspace_id, :kind, :ref_type, :ref_id])
  end
end
