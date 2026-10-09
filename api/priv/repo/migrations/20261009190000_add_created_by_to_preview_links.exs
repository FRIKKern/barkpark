defmodule Barkpark.Repo.Migrations.AddCreatedByToPreviewLinks do
  use Ecto.Migration

  @moduledoc """
  task-0548f06277c4712e — additive, nullable, no backfill. A preview link's
  creator was never recorded, so `DELETE /v1/shares/preview-links/:id` and
  `GET /v1/shares/preview-links` could only ever be admin-only: there was no
  way to tell "my own link" from "someone else's" short of workspace
  membership. `created_by` is `"api_token:<id>"` or `"user:<id>"` (the same
  principal-ref shape `Tenancy.Members.invited_by` already uses), stamped at
  mint time. Every existing row stays NULL — an admin still sees and manages
  it, as today; it simply cannot be claimed as any one member's own.
  """

  def change do
    alter table(:preview_links) do
      add :created_by, :string, null: true
    end
  end
end
