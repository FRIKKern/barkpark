defmodule BarkparkCloud.Repo.Migrations.AddStudioCallbackUrlsToBarkparks do
  @moduledoc """
  "Sign in with Barkpark Cloud" for an external Studio: the per-instance
  allowlist of Studio callback URLs a sign-in may return to. A sign-in's
  `return_to` must equal one of these EXACTLY, so the control plane never
  redirects a ticket anywhere a team admin did not name.

  ADDITIVE ONLY: one column, empty by default (no external Studio allowed).
  """
  use Ecto.Migration

  def change do
    alter table(:barkparks) do
      add :studio_callback_urls, {:array, :string}, null: false, default: []
    end
  end
end
