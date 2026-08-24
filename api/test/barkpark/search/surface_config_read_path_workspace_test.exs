defmodule Barkpark.Search.SurfaceConfigReadPathWorkspaceTest do
  @moduledoc """
  Charter D63/D64/D65 — the scoped search READ path must resolve the surface
  config for the CALLER'S workspace, so a per-workspace admin's tuning actually
  changes that workspace's results.

  Wave 5 shipped the per-workspace WRITE key (`(workspace_id, surface, scope)`)
  but the read path still resolved config workspace-blind
  (`SurfaceConfigs.get(surface, scope)` — nil workspace). So an admin's saved
  `similarity_threshold` was attributed on write yet never reached results: the
  ONE functional regression this closes.

  Two results-level proofs, RESULTS not the settings echo (anti-vacuous —
  charter D66/D67):

    * **Per-workspace threading.** Two workspaces A/B, each owning its OWN
      `komquat` doc under the SHARED `"production"` dataset slug (identical docs,
      distinct `dataset_id`s — the retriever already narrows fail-closed
      workspace-only, so ONE shared doc would make A==B==0, the vacuous trap the
      probe hit). Query `"kumquat"` — a pg_trgm fuzzy-arm-only near-miss. A tunes
      `typo_policy.similarity_threshold` HIGH (0.9 → EXCLUDES, total 0); B stays
      default (INCLUDES, total 1). Before the thread A==B (both resolve the
      nil-global row); after, A≠B.

    * **Anonymous flat-route floor (D65).** An anonymous flat
      `GET /v1/data/search/:dataset` (no `/w/` prefix) resolves the seeded
      Default workspace's REAL id via `AssignDefaultScope` — an id that has NO
      own `SurfaceConfig` row. Its config must fall through (D64) to the
      nil-global admin-tuned row, NOT the hardcoded `default_for`. Tune the
      nil-global threshold to 0.9 and the anon fuzzy near-miss must drop
      (neutralizing the naive-thread public-search regression).
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Search.SurfaceConfigs

  @scope "production"
  # Title stored on the doc; query is a one-char fuzzy near-miss (pg_trgm
  # similarity ~0.45 — above the 0.25 default floor, below a 0.9 tuned floor).
  # Only the pg_trgm `similarity()` title arm can match "kumquat" against
  # "komquat" (tsvector/ilike do not), so the resolved threshold alone decides
  # inclusion.
  @doc_title "komquat"
  @query "kumquat"

  # A typo_policy that pins BOTH the strict and the relaxed threshold high, so
  # neither the primary arm NOR the zero-hit typo-widen recovery can re-include
  # the near-miss. min_len_1typo stays 5 so the 7-char query still arms fuzzy.
  defp exclude_policy do
    %{
      "enabled" => true,
      "min_len_1typo" => 5,
      "similarity_threshold" => 0.9,
      "similarity_threshold_relaxed" => 0.9
    }
  end

  setup do
    on_exit(fn -> SurfaceConfigs.__reset_cache_for_test__() end)
    SurfaceConfigs.__reset_cache_for_test__()
    :ok
  end

  describe "per-workspace threading (D63) — results change per workspace" do
    setup do
      # The workspace-agnostic global defaults (similarity_threshold 0.25) that
      # an untuned workspace inherits via the D64 fallthrough.
      SurfaceConfigs.seed_defaults!()

      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
      scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

      # W10 schema-visibility gate: the anonymous (no caller_context) searches
      # below are restricted to PUBLIC schema types — seed "post" as one per
      # tenant; the per-workspace config threading stays the behaviour under test.
      for scope <- [scope_a, scope_b] do
        {:ok, _} =
          Content.upsert_schema(
            %{"name" => "post", "title" => "post", "visibility" => "public"},
            @scope,
            scope
          )
      end

      # Each workspace owns its OWN identical komquat doc — so a workspace-only
      # narrowing cannot collapse both to zero (the vacuous trap).
      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => "a-komquat", "title" => @doc_title},
          @scope,
          scope_a
        )

      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => "b-komquat", "title" => @doc_title},
          @scope,
          scope_b
        )

      {:ok, ws_a: ws_a, ws_b: ws_b, scope_a: scope_a, scope_b: scope_b}
    end

    test "A's high similarity_threshold EXCLUDES the fuzzy near-miss; B (default) INCLUDES it",
         %{ws_a: ws_a, scope_a: scope_a, scope_b: scope_b} do
      # Workspace A tunes its OWN config to exclude the near-miss.
      {:ok, _} =
        SurfaceConfigs.upsert("documents", @scope, %{"typoPolicy" => exclude_policy()}, ws_a.id)

      SurfaceConfigs.__reset_cache_for_test__()

      {_a_hits, a_total, _} =
        Content.search_documents(@query, @scope, [perspective: :raw] ++ scope_a)

      {_b_hits, b_total, _} =
        Content.search_documents(@query, @scope, [perspective: :raw] ++ scope_b)

      # RESULTS differ per workspace — the config actually reached the read path.
      assert a_total == 0,
             "workspace A's tuned similarity_threshold (0.9) should EXCLUDE the fuzzy near-miss"

      assert b_total == 1,
             "workspace B (untuned → global default 0.25) should INCLUDE the fuzzy near-miss"

      assert a_total != b_total,
             "the per-workspace config must change results (fail-before: read path resolved get/2 nil → A==B==1)"
    end

    test "witness the mechanism: the blind (get/2 nil) resolution is the SAME for A and B; only the threaded get/3 diverges",
         %{ws_a: ws_a, ws_b: ws_b} do
      # A tunes its own config; B stays untuned.
      {:ok, _} =
        SurfaceConfigs.upsert("documents", @scope, %{"typoPolicy" => exclude_policy()}, ws_a.id)

      SurfaceConfigs.__reset_cache_for_test__()

      # The pre-D63 read path resolved config workspace-blind (get/2 → nil
      # workspace). That collapses A and B onto the SAME nil-global row — A's
      # tuning is invisible, hence the A==B==1 regression this wave closes.
      blind = SurfaceConfigs.get("documents", @scope, nil)["typo_policy"]["similarity_threshold"]
      assert blind == 0.25

      # The threaded (D63) resolution diverges: A sees its OWN 0.9, B falls
      # through (D64) to the nil-global 0.25 — the divergence that makes results
      # differ per workspace in the GREEN test above.
      assert SurfaceConfigs.get("documents", @scope, ws_a.id)["typo_policy"][
               "similarity_threshold"
             ] == 0.9

      assert SurfaceConfigs.get("documents", @scope, ws_b.id)["typo_policy"][
               "similarity_threshold"
             ] == 0.25
    end
  end

  describe "anonymous flat-route floor (D64/D65)" do
    test "anon flat GET resolves Default's real id and falls through to the nil-global admin-tuned row",
         %{conn: conn} do
      {ws, project} = ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id]

      # W10 schema-visibility gate: the anon HTTP search below is restricted to
      # PUBLIC schema types — seed "post" as one in the Default scope (the state
      # every live searchable type is in).
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "post", "visibility" => "public"},
          @scope,
          scope
        )

      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => "anon-komquat", "title" => @doc_title},
          @scope,
          scope
        )

      {:ok, _} = Content.publish_document("anon-komquat", "post", @scope, scope)

      # Baseline: with the nil-global at the permissive default (0.25) the anon
      # fuzzy near-miss is INCLUDED — proves the doc is genuinely matchable, so a
      # later zero is a threshold decision, not a no-match (anti-vacuous).
      SurfaceConfigs.seed_defaults!()
      SurfaceConfigs.__reset_cache_for_test__()

      baseline =
        conn
        |> get("/v1/data/search/#{@scope}", q: @query)
        |> json_response(200)

      assert baseline["count"] == 1,
             "anon fuzzy near-miss should be included under the permissive nil-global default (0.25)"

      # Now the operator tunes the NIL-GLOBAL row high. Anon resolves Default's
      # REAL workspace id (no own row) → must fall through (D64) to THIS row, not
      # the hardcoded default_for. If the fallthrough is absent, anon keeps
      # returning 1 (the 0.25 code default) and this fails.
      {:ok, _} =
        SurfaceConfigs.upsert("documents", @scope, %{"typoPolicy" => exclude_policy()}, nil)

      SurfaceConfigs.__reset_cache_for_test__()

      tuned =
        Phoenix.ConnTest.build_conn()
        |> get("/v1/data/search/#{@scope}", q: @query)
        |> json_response(200)

      assert tuned["count"] == 0,
             "anon flat search must reflect the nil-global admin-tuned threshold (0.9) via the D64 fallthrough — NOT the hardcoded default_for"
    end
  end
end
