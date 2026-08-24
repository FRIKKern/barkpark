defmodule Barkpark.Search.MediaSurfaceConfigReadPathTest do
  @moduledoc """
  Anti-vacuous-green proof (charter D59/D63/D66): per-workspace media
  search-config tuning must reach media RESULTS, not just the settings echo.

  W5 shipped `(workspace_id, surface, scope)` per-workspace attribution on
  `SurfaceConfigs` and threaded it into the admin WRITE + the docs read path,
  but `Barkpark.Media.Delivery.Search` still called `SurfaceConfigs.get/2`
  (workspace-BLIND) at two sites — the `search/2` entry (primary count+page
  query) and `maybe_filter_text/3`'s `:pipeline_config` default-arg trap that
  `compute_facets` re-fetches per facet field. So a per-workspace admin's media
  typo tuning was persisted and attributed but never changed what the fuzzy
  gate admitted. This test proves the fix by asserting media RESULTS differ per
  workspace on a SHARED dataset slug — never the config echo.

  Fail-before RED (proven at build): revert either 3-arg `SurfaceConfigs.get`
  in media/delivery/search.ex back to 2-arg and A==B (both read the nil-workspace
  global default) — the assertions below flip.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Media.Delivery.Search
  alias Barkpark.Search.SurfaceConfigs

  # Both workspaces share this dataset SLUG — isolation must come from
  # workspace_id, not the dataset leaf.
  @dataset "test"

  # A one-character substitution ("const-E-llation" → "const-O-llation") in a
  # long word: NOT a substring of the query (so the `ilike` arms never match —
  # only the pg_trgm `similarity()` gate decides), yet trigram-similar well
  # above the 0.25 default. The knob under test is
  # typo_policy.similarity_threshold — the fuzzy gate — the ONLY live media
  # config knob (searchable_fields + apply_sort are hardcoded/dead).
  @query "constellation"
  @near_miss "constollation"

  # A tightened policy whose strict AND relaxed thresholds both exclude the
  # near-miss. The relaxed one is load-bearing: on a zero-hit strict pass the
  # media recovery pipeline retries with `similarity_threshold_relaxed`
  # (typo_widen arm) — leave it at the 0.15 default and A would re-admit the
  # near-miss through recovery, masking the fix.
  @tightened %{
    "enabled" => true,
    "min_len_1typo" => 5,
    "similarity_threshold" => 0.95,
    "similarity_threshold_relaxed" => 0.95
  }

  test "per-workspace media similarity_threshold changes media RESULTS on a shared dataset slug" do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    # media_files are workspace-scoped: seed an IDENTICAL near-miss-titled row
    # under EACH workspace (same slug, each its own scope). One shared row would
    # make A==B==0 (no file — NOT threshold), the vacuous-green trap.
    {:ok, _file_a} =
      create_media_file_in!(
        ws_a,
        proj_a,
        %{filename: @near_miss, original_name: @near_miss},
        @dataset
      )

    {:ok, _file_b} =
      create_media_file_in!(
        ws_b,
        proj_b,
        %{filename: @near_miss, original_name: @near_miss},
        @dataset
      )

    # Workspace A tightens its OWN media typo policy to EXCLUDE the near-miss.
    # Workspace B never customises → reads the code default (0.25) that INCLUDES
    # it. Attribution is per (workspace_id, surface, scope).
    {:ok, _echo} =
      SurfaceConfigs.upsert("media", @dataset, %{typo_policy: @tightened}, ws_a.id)

    total = fn ws, proj ->
      {_files, total, _facets, _meta} =
        Search.search(@dataset, q: @query, workspace_id: ws.id, project_id: proj.id)

      total
    end

    # RESULTS — never the settings echo. A's tightened threshold excludes the
    # fuzzy near-miss; B's default admits it. Different per workspace ⇒ the read
    # path resolved config per workspace (the regression W5 left, closed here).
    assert total.(ws_a, proj_a) == 0,
           "workspace A's tightened similarity_threshold (0.95) must EXCLUDE the fuzzy " <>
             "near-miss from media RESULTS — its per-workspace config didn't reach the read"

    assert total.(ws_b, proj_b) == 1,
           "workspace B (default threshold 0.25) must INCLUDE the fuzzy near-miss in media " <>
             "RESULTS — a shared global config would have been overwritten by A's tuning"
  end
end
