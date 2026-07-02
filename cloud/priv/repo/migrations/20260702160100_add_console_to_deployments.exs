defmodule BarkparkCloud.Repo.Migrations.AddConsoleToDeployments do
  use Ecto.Migration

  # gh-5: LIVE build console for Deployments — the deploy-side twin of the
  # provision console (dwb-16). The off-box builder tees its create→live chain
  # (claim → fetch source → nixpacks build → docker save → activate/handoff),
  # already redacted worker-side, to a new builder endpoint; each line is
  # APPENDED to this array (append-only, capped server-side at ~300 lines,
  # oldest dropped) so the site-detail deployment row renders a live build
  # console — and a freshly-loaded page recovers mid-build console state after a
  # refresh (the array survives independent of the coarse SSE invalidation tick).
  #
  # Each element: %{"line" => "build: nixpacks build starting", "at" => "…Z"}.
  # Same cheapest-persistence choice as provision_jobs.console — one jsonb[]
  # column on the existing row, no new table, no join — surfaced on the
  # deployment JSON as :console.
  def up do
    alter table(:deployments) do
      add :console, {:array, :map}, null: false, default: []
    end
  end

  def down do
    alter table(:deployments) do
      remove :console
    end
  end
end
