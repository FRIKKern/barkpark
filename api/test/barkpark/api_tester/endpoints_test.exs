defmodule Barkpark.ApiTester.EndpointsTest do
  use ExUnit.Case, async: true
  alias Barkpark.ApiTester.Endpoints

  # ── Facade-split parity ──────────────────────────────────────────────
  #
  # `endpoints.ex` was decomposed from a 51-def god-module into a facade
  # over per-category sibling modules under `endpoints/`. The facade's
  # `all/1` must return the SAME ordered catalog as before the split.
  #
  # `EndpointsCatalogBaseline.catalog/0` (a compiled test-support fixture)
  # is an auto-generated snapshot of the ORIGINAL (pre-split) static
  # catalog — `Endpoints.all("production")` with the dynamic `plugin-*`
  # entries excluded (those come from the plugin Registry and are appended
  # unchanged by the facade, so they are NOT part of what the decomposition
  # moved). Same length, same order, same entry maps. The only
  # non-deterministic field is `mutate-create`'s body `_id` (uses
  # `:erlang.unique_integer/1`), normalized to "<DYNAMIC>" on both sides.

  @baseline_catalog Barkpark.ApiTester.EndpointsCatalogBaseline.catalog()

  # The catalog the facade BUILDS from its per-category modules, before the
  # dynamic plugin-contributed entries the Registry tacks on the end.
  defp static_catalog(dataset) do
    Enum.reject(Endpoints.all(dataset), &String.starts_with?(&1.id, "plugin-"))
  end

  # Replace mutate-create's unique-integer _id with a stable sentinel so
  # the catalog is comparable across calls (matches the fixture).
  defp normalize_dynamic(catalog) do
    Enum.map(catalog, fn
      %{id: "mutate-create", body_example: %{"mutations" => [%{"create" => c} = m]} = be} =
          entry ->
        %{
          entry
          | body_example: %{
              be
              | "mutations" => [%{m | "create" => Map.put(c, "_id", "<DYNAMIC>")}]
            }
        }

      entry ->
        entry
    end)
  end

  test "all/1 parity — id sequence + order are byte-identical to the pre-split catalog" do
    actual_ids = static_catalog("production") |> Enum.map(& &1.id)
    baseline_ids = Enum.map(@baseline_catalog, & &1.id)

    assert actual_ids == baseline_ids,
           "all/1 id-sequence drifted from the pre-split catalog (added/dropped/reordered)"
  end

  test "all/1 parity — every entry map equals the pre-split catalog verbatim" do
    actual = static_catalog("production") |> normalize_dynamic()

    assert length(actual) == length(@baseline_catalog)
    assert actual == @baseline_catalog, "an entry map diverged from the pre-split catalog"
  end

  test "all/1 parity holds for a different dataset (staging) — dataset interpolation preserved" do
    # The dataset arg interpolates into every entry's `dataset` path-param
    # default; swapping "production"→"staging" in the baseline must equal
    # the live static catalog for "staging", proving interpolation moved
    # verbatim into the per-category modules.
    expected =
      Enum.map(@baseline_catalog, fn entry ->
        case entry do
          %{path_params: params} when is_list(params) ->
            %{
              entry
              | path_params:
                  Enum.map(params, fn
                    %{name: "dataset"} = p -> %{p | default: "staging"}
                    p -> p
                  end)
            }

          _ ->
            entry
        end
      end)

    actual = static_catalog("staging") |> normalize_dynamic()
    assert actual == expected, "dataset interpolation drifted after the split"
  end

  test "all/1 returns endpoints for the given dataset" do
    endpoints = Endpoints.all("staging")
    assert is_list(endpoints)
    assert length(endpoints) >= 3
  end

  test "find/2 returns the query-list endpoint with a dataset-interpolated path" do
    ep = Endpoints.find("staging", "query-list")
    assert ep.kind == :endpoint
    assert ep.method == "GET"
    assert ep.path_template == "/v1/data/query/{dataset}/{type}"
    assert ep.auth == :public
    assert ep.category == "Query"
  end

  test "find/2 returns nil for unknown id" do
    assert Endpoints.find("staging", "bogus") == nil
  end

  test "query-single endpoint has path and doc_id params" do
    ep = Endpoints.find("production", "query-single")
    param_names = Enum.map(ep.path_params, & &1.name)
    assert "dataset" in param_names
    assert "type" in param_names
    assert "doc_id" in param_names
  end

  test "mutate-create is under Mutate category and has token auth" do
    ep = Endpoints.find("production", "mutate-create")
    assert ep.category == "Mutate"
    assert ep.auth == :token
    assert ep.method == "POST"
    assert is_map(ep.body_example)
  end

  test "all 8 mutation kinds are registered" do
    ids = Endpoints.all("production") |> Enum.map(& &1.id)

    for kind <-
          ~w(create createOrReplace createIfNotExists patch publish unpublish discardDraft delete) do
      assert "mutate-#{kind}" in ids, "missing mutate-#{kind}"
    end
  end

  test "mutate-patch body example carries a patch mutation with `set` fields" do
    ep = Endpoints.find("production", "mutate-patch")
    # Body is a setup-then-test batch: createOrReplace + patch.
    patch_mutation = Enum.find(ep.body_example["mutations"], &Map.has_key?(&1, "patch"))
    assert patch_mutation, "missing patch mutation in body"
    patch_body = patch_mutation["patch"]
    assert Map.has_key?(patch_body, "set")
    # ifRevisionID is intentionally absent from the default example so
    # Run all succeeds without optimistic-concurrency gotchas. The user
    # can paste a rev into the textarea to test rev_mismatch manually.
    refute Map.has_key?(patch_body, "ifRevisionID")
  end

  test "mutate-publish body example includes a publish mutation on post" do
    ep = Endpoints.find("production", "mutate-publish")
    pub = Enum.find(ep.body_example["mutations"], &Map.has_key?(&1, "publish"))
    assert pub, "missing publish mutation in body"
    assert pub["publish"]["type"] == "post"
  end

  test "listen-sse is docs-only (no playground, still :endpoint kind)" do
    ep = Endpoints.find("production", "listen-sse")
    assert ep.category == "Real-time"
    assert ep.auth == :token
    assert ep.method == "GET"
    assert ep.kind == :endpoint
    assert ep.expect == nil, "listen has no verdict predicate"
    assert ep[:runnable] == false, "listen-sse should be marked non-runnable so Run all skips it"
  end

  test "schemas-list and schemas-show both require admin auth" do
    list_ep = Endpoints.find("production", "schemas-list")
    show_ep = Endpoints.find("production", "schemas-show")
    assert list_ep.auth == :admin
    assert show_ep.auth == :admin
  end

  test "new API expansion endpoints have valid specs" do
    new_ids =
      ~w(export-dataset history-list history-show history-restore search-documents analytics-overview webhooks-list webhooks-create webhooks-delete)

    for id <- new_ids do
      endpoint = Endpoints.find("test", id)
      assert endpoint != nil, "Missing endpoint: #{id}"
      assert endpoint.id == id
      assert endpoint.kind == :endpoint
    end
  end

  test "search-documents is public, webhooks require admin" do
    search = Endpoints.find("test", "search-documents")
    assert search.auth == :public

    wh_list = Endpoints.find("test", "webhooks-list")
    assert wh_list.auth == :admin
  end

  # ── Gate-integrity invariant (wb-api-tester-unverified-badge) ─────────
  #
  # A runnable endpoint with no `expect:` and no `scenarios:` can NEVER
  # fail — runner.ex's `check/2` has nothing to inspect, so the single
  # "Run" click badges PASS (now :unverified) regardless of what the
  # server actually returned. This is the tripwire that keeps the zero-
  # expectation class from regrowing once webhooks.ex/history.ex are
  # fixed: every endpoint must carry either a real `expect:` (preferred)
  # or `runnable: false` (which removes the false-positive Run button
  # entirely, honestly, instead of badging it).
  test "no runnable endpoint ships expect: nil with zero scenarios (the zero-expectation badge class)" do
    offenders =
      Endpoints.all("production")
      |> Enum.filter(fn ep ->
        ep.kind == :endpoint and
          Map.get(ep, :runnable, true) == true and
          Map.get(ep, :expect) == nil and
          (Map.get(ep, :scenarios, []) || []) == []
      end)
      |> Enum.map(& &1.id)
      |> Enum.sort()

    assert offenders == [],
           "runnable endpoints with no expectation and no scenarios badge PASS " <>
             "without checking the response at all (give them a real `expect:` " <>
             "or flip `runnable: false`): #{inspect(offenders)}"
  end

  test "reference pages use :reference kind with a render_key" do
    envelope = Endpoints.find("production", "ref-envelope")
    errors = Endpoints.find("production", "ref-errors")
    limits = Endpoints.find("production", "ref-limits")

    for ep <- [envelope, errors, limits] do
      assert ep.kind == :reference
      assert is_atom(ep.render_key)
      assert ep.category == "Reference"
    end

    assert envelope.render_key == :envelope
    assert errors.render_key == :error_codes
    assert limits.render_key == :known_limitations
  end
end
