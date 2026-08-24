defmodule Barkpark.Search.SurfaceConfigRaceTest do
  @moduledoc """
  Protective test for the concurrent first-config PUT race (P2 correctness).

  Migration `20260527100000_create_search_surface_config` puts a UNIQUE index
  `search_surface_config_surface_scope_idx` on (surface, scope). Before the fix,
  `SurfaceConfig.changeset/2` mapped NO `unique_constraint` and the upsert insert
  branch carried NO `on_conflict`. So for a (surface, scope) with no row yet, two
  concurrent PUTs both had `get_by` return nil, both took the insert branch, and
  the losing racer's `Repo.insert/1` raised an uncaught `Ecto.ConstraintError` →
  HTTP 500 instead of a clean upsert/422.

  Two guards, both RED before the fix:

    1. The insert branch now upserts (`on_conflict` + `conflict_target`) — the
       loser cleanly `{:ok, _}`s instead of raising.
    2. Defense in depth: the changeset maps the unique index, so any plain
       `Repo.insert/2` on a duplicate returns `{:error, %Ecto.Changeset{}}`
       (rendered 422) instead of a raw `Ecto.ConstraintError` (a 500).
  """
  use Barkpark.DataCase, async: true

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Search.{SurfaceConfig, SurfaceConfigs}

  setup do
    on_exit(fn -> SurfaceConfigs.__reset_cache_for_test__() end)
    :ok
  end

  defp count(surface, scope) do
    Repo.aggregate(
      from(c in SurfaceConfig, where: c.surface == ^surface and c.scope == ^scope),
      :count
    )
  end

  test "losing racer's first-config insert upserts instead of raising Ecto.ConstraintError (500)" do
    surface = "documents"
    scope = "race-ds-#{System.unique_integer([:positive])}"

    # Winner creates the first row for this brand-new (surface, scope).
    assert {:ok, _} = SurfaceConfigs.upsert(surface, scope, %{"zeroHitStrategy" => "typo_widen"})
    assert count(surface, scope) == 1

    # Loser already passed get_by (saw nil) and now runs the real insert branch.
    # BEFORE fix: plain Repo.insert, no on_conflict → Ecto.ConstraintError (500).
    # AFTER fix:  ON CONFLICT (surface, scope) DO UPDATE → clean {:ok, _}.
    merged = %{
      searchable_fields: [%{"path" => "title", "weight" => 10}],
      typo_policy: %{},
      zero_hit_strategy: "drop_tokens",
      highlight_fields: ["title"]
    }

    assert {:ok, _row} = SurfaceConfigs.__insert_config_for_test__(surface, scope, merged)

    # Idempotent: still exactly one row for the pair, not a duplicate or a crash.
    assert count(surface, scope) == 1
  end

  test "changeset maps the unique index so a non-upsert insert is a clean {:error, changeset}" do
    surface = "media"
    scope = "race-ds-#{System.unique_integer([:positive])}"

    assert {:ok, _} = SurfaceConfigs.upsert(surface, scope, %{})

    # A plain Repo.insert (no on_conflict) on a duplicate (surface, scope).
    # BEFORE fix: unmapped constraint → Repo.insert RAISES Ecto.ConstraintError.
    # AFTER fix:  unique_constraint maps it → {:error, %Ecto.Changeset{}}.
    cs = SurfaceConfig.changeset(%SurfaceConfig{surface: surface, scope: scope}, %{})

    assert {:error, %Ecto.Changeset{} = err} = Repo.insert(cs)
    refute err.valid?
    assert Keyword.has_key?(err.errors, :surface)
    assert count(surface, scope) == 1
  end
end
