defmodule Barkpark.Search.TypoPolicyHonouredTest do
  @moduledoc """
  `typo_policy` knobs that were STORED, ECHOED, and IGNORED.

  The surface config's `typo_policy` map is written through
  `SurfaceConfigs.upsert/4`, read back verbatim by the admin GET, and shipped
  with `"enabled" => true` / `"min_len_1typo" => 5` in BOTH defaults. Before
  this fix:

    * `enabled` had NO reader anywhere in `api/lib` — an admin could set it to
      `false`, get a 200, re-read the config and see `false` stored, and every
      pg_trgm `similarity()` arm (documents AND media) plus the `typo_widen`
      recovery pass kept firing.
    * `min_len_1typo` was read by the DOCUMENTS retriever only
      (`fuzzy_min_len/1`); the media retriever applied `similarity()` to every
      term regardless of length. Same key, same config object, sibling surface.

  Each test below pairs the mutation with its own anti-vacuous baseline: the
  SAME corpus and query under a permissive policy must MATCH, so a zero under
  the tightened policy is a decision by the knob and not a doc that was never
  matchable. Every assertion is on RESULTS, never on the config echo.

  Fail-before (RED on pre-fix code, run at build):

      enabled=false, documents ..... 1 hit (expected 0)
      enabled=false, media ......... 1 hit (expected 0)
      min_len_1typo=20, media ...... 1 hit (expected 0)
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Media.Delivery.Search, as: MediaSearch
  alias Barkpark.Search.SurfaceConfigs

  @scope "production"

  # A one-character substitution in a long token: NOT a substring of the query,
  # so no `ilike` / tsvector arm can match it — only the pg_trgm `similarity()`
  # arm decides, which is exactly the arm `typo_policy` governs.
  @stored "komquat"
  @query "kumquat"

  # Permissive: typo tolerance on, both thresholds at the shipped defaults, and
  # a min length the 7-character query clears. The near-miss MATCHES here.
  @permissive %{
    "enabled" => true,
    "min_len_1typo" => 5,
    "similarity_threshold" => 0.25,
    "similarity_threshold_relaxed" => 0.15
  }

  # The mutation: identical thresholds, typo tolerance OFF. Any difference in
  # results is attributable to `enabled` alone.
  @disabled %{@permissive | "enabled" => false}

  # The sibling mutation: typo tolerance ON, but the token-length floor raised
  # above the query's 7 characters, so no term may enter the fuzzy arm.
  @too_short %{@permissive | "min_len_1typo" => 20}

  setup do
    on_exit(fn -> SurfaceConfigs.__reset_cache_for_test__() end)
    SurfaceConfigs.seed_defaults!()
    SurfaceConfigs.__reset_cache_for_test__()

    ws = create_workspace!()
    project = create_project!(ws)
    {:ok, ws: ws, project: project, scope_opts: [workspace_id: ws.id, project_id: project.id]}
  end

  defp tune(surface, ws, policy) do
    {:ok, _echo} = SurfaceConfigs.upsert(surface, @scope, %{"typoPolicy" => policy}, ws.id)
    SurfaceConfigs.__reset_cache_for_test__()
    :ok
  end

  describe "documents surface" do
    setup %{scope_opts: scope_opts} do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "post", "visibility" => "public"},
          @scope,
          scope_opts
        )

      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => "near-miss", "title" => @stored},
          @scope,
          scope_opts
        )

      :ok
    end

    defp documents_total(scope_opts) do
      {_hits, total, _meta} =
        Content.search_documents(@query, @scope, [perspective: :raw] ++ scope_opts)

      total
    end

    test "typo_policy.enabled => false suppresses the fuzzy arm (and its typo_widen rescue)",
         %{ws: ws, scope_opts: scope_opts} do
      :ok = tune("documents", ws, @permissive)

      assert documents_total(scope_opts) == 1,
             "baseline: the near-miss must be matchable under a permissive policy, " <>
               "otherwise the zero below proves nothing"

      :ok = tune("documents", ws, @disabled)

      # Zero is load-bearing twice over: the primary fuzzy arm must not fire,
      # AND the zero-hit recovery must not widen the query back onto it. Before
      # the fix this returned 1 — the knob was never read by either.
      assert documents_total(scope_opts) == 0,
             "enabled=false must turn typo tolerance OFF — the near-miss can only " <>
               "arrive via similarity(), whether on the primary pass or typo_widen"
    end
  end

  describe "media surface" do
    setup %{ws: ws, project: project} do
      {:ok, _file} =
        create_media_file_in!(
          ws,
          project,
          %{filename: @stored, original_name: @stored},
          @scope
        )

      :ok
    end

    defp media_total(scope_opts) do
      {_files, total, _facets, _meta} =
        MediaSearch.search(@scope, [q: @query] ++ scope_opts)

      total
    end

    test "typo_policy.enabled => false suppresses the media fuzzy arm too",
         %{ws: ws, scope_opts: scope_opts} do
      :ok = tune("media", ws, @permissive)

      assert media_total(scope_opts) == 1,
             "baseline: the near-miss file must be matchable under a permissive policy"

      :ok = tune("media", ws, @disabled)

      assert media_total(scope_opts) == 0,
             "enabled=false must reach the MEDIA surface as well — before the fix " <>
               "no search path read the key at all"
    end

    test "typo_policy.min_len_1typo gates the media fuzzy arm, exactly as it does documents",
         %{ws: ws, scope_opts: scope_opts} do
      :ok = tune("media", ws, @permissive)

      assert media_total(scope_opts) == 1,
             "baseline: a 7-character query clears min_len_1typo=5 and matches"

      :ok = tune("media", ws, @too_short)

      assert media_total(scope_opts) == 0,
             "a min_len_1typo above the query length must keep the term out of the " <>
               "fuzzy arm — the documents retriever has always done this and media " <>
               "ignored the same key on the same config object"
    end
  end
end
