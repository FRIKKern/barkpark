defmodule Barkpark.Repo.Migrations.AddSettingsToWorkspaces do
  use Ecto.Migration

  @moduledoc """
  Theme-system wave 4 (ts-w4e) — the first per-workspace SETTINGS bag.

  Until now a workspace was slug/name/org only; the one theme switch that
  existed (dark/light) was client-only `localStorage`, never persisted
  server-side. The theme system needs a DURABLE, server-resolved theme
  identity per workspace so the reader / Studio / email all stamp the SAME
  theme with no client round-trip and no flash-of-wrong-theme.

  `settings` is a jsonb bag (default `{}`) so this one migration carries every
  future per-workspace preference, not just `theme`. NOT-NULL default `{}` so
  every existing row reads as "no settings" → `Barkpark.Tenancy.workspace_theme/1`
  falls back to the baked-in default (`evergreen`) → the surface renders exactly
  as it did before this column existed.
  """

  def change do
    alter table(:workspaces) do
      add :settings, :map, null: false, default: %{}
    end
  end
end
