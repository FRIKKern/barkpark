defmodule Barkpark.Repo.Migrations.AddDatasetBoundToApiTokens do
  use Ecto.Migration

  @moduledoc """
  task-4418b517649a58ce — additive. `api_tokens.dataset` defaults to
  `"production"` on every row and no request path ever enforced it, so the
  column cannot tell a binding the minter ASKED for from the default. An app
  token minted with `"dataset": "e2e-local"` read and wrote another dataset of
  its workspace.

  `dataset_bound` records the ask: true only when the mint request named a
  dataset. Nullable, no backfill: every existing row stays NULL and keeps
  today's cross-dataset access (lead ruling B, run8). Enforcement lives in
  `BarkparkWeb.Plugs.RequireToken.dataset_off_binding?/2`.
  """

  def change do
    alter table(:api_tokens) do
      add :dataset_bound, :boolean, null: true
    end
  end
end
