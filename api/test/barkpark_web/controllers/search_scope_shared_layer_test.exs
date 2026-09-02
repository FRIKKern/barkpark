defmodule BarkparkWeb.SearchScopeSharedLayerTest do
  @moduledoc """
  `GET /v1/data/search/:dataset` (`SearchController.search/2`) with the Default
  seat VACANT — the arm that leaked in the 2026-08-20 census.

  ## Why this suite exists

  `empty_scope_shared_layer_test.exs` (PR #12899) deliberately EXCLUDED search,
  because two readings disagreed:

    * **A (reading the code)** — "SearchController never routes the document
      read through `scope_opts/1`; it takes the workspace from
      `params["workspace_id"]` verbatim via `maybe_put_opt/3`, so it leaks
      whether or not the Default seat is occupied."
    * **B (the census)** — it leaked ONLY when the seat was vacant, which is
      the signature of a read that DOES respond to the resolved tenant.

  **B was right; A read the wrong function.** `maybe_put_opt/3` belongs to
  `search_local/2`, the loopback-gated fast path (`/v1/data/local/search/:ds`,
  behind `Plugs.RequireLoopback`). The public `search/2` has always built its
  tenancy the shared way — `] ++ scope_opts(conn)` — and never reads
  `params["workspace_id"]` at all. So search WAS the empty-scope class, and
  #12899's `:shared_only` sentinel closed it at the `ScopeHelpers` seam three
  hours after the row was filed — untested, because the suite excluded it on A's
  reasoning. This file is that missing test.

  ## What each test buys

    * **The instrument self-test comes first.** The census returned a confident
      0-of-10 while BLIND. An anonymous search is narrowed twice over — the W10
      schema-visibility gate admits only PUBLIC types, and the perspective clamp
      admits only PUBLISHED rows — so a probe that planted a private or draft
      document would record "no leak" from a surface it could not see at all.
      `the probe is not blind` plants a row the surface MUST return and proves
      the bytes carry it, before any absence below is worth quoting.
    * **The seat is forced vacant, then proved so.** With a Default seeded,
      `AssignDefaultScope` stamps it, the read filters to the Default's rows and
      workspace A's marker is absent for a reason that has nothing to do with
      the sentinel — the arm goes vacuous and passes on the pre-fix code too.
      `refute Tenancy.get_default_workspace()` is that non-vacuity guard.
    * **Assertions are on the BYTES**, never the status. This surface answers
      200 leaking and 200 not; only the marker discriminates.
  """
  # `async: false` on purpose. Vacating the seat means writing the one
  # `workspaces` row every other suite reads, so this must not run beside them.
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.{Content, Repo, Tenancy}
  alias Barkpark.Tenancy.Workspace

  # One dataset STRING shared by both tenants — isolation must come from
  # `workspace_id`, never from the dataset leaf.
  @ds "search-scope-shared-layer"

  @foreign_marker "ZzarquonForeignMarker"
  @shared_marker "ZzarquonSharedMarker"

  setup do
    # The seat must be VACANT for this to be the census's arm — and it is NOT
    # vacant by default anywhere. Migration `20260527110200_backfill_default_tenancy`
    # seeds a workspace at slug "default" into EVERY database, test included, so
    # the state the census caught the leak in only arises on a DB that predates
    # that backfill or whose Default was deleted. It has to be forced here.
    #
    # Forced by RENAMING the slug, not by deleting the row. `get_default_workspace/0`
    # is a `Repo.get_by(Workspace, slug: "default")` lookup, so a renamed row is
    # an absent seat for every reader — and the write is one UPDATE against one
    # row. The first draft used `Repo.delete!` and deadlocked (Postgres 40P01):
    # deleting cascades FK checks across projects/documents/… in an order other
    # suites take differently, which is a lock CYCLE, not just contention.
    # Rolled back with the sandbox transaction either way.
    {1, _} =
      from(w in Workspace, where: w.slug == "default")
      |> Repo.update_all(set: [slug: "default-vacated-#{System.unique_integer([:positive])}"])

    refute Tenancy.get_default_workspace(),
           "the Default seat is OCCUPIED — every absence assertion below would " <>
             "pass by tenant-equality instead of by the sentinel, i.e. vacuously"

    # W10 schema-visibility gate: an anonymous search sees PUBLIC types only.
    # Seeded unscoped, so the schema row itself is shared-layer and visible.
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "post", "visibility" => "public"},
        @ds
      )

    # The foreign row: owned by workspace A, which the anonymous caller is not a
    # member of and never named.
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)

    {:ok, _} =
      create_document_in!(
        ws_a,
        proj_a,
        "post",
        %{"doc_id" => "foreign-doc", "title" => "#{@foreign_marker} Doc"},
        @ds
      )

    {:ok, _} =
      Content.publish_document("foreign-doc", "post", @ds,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    # The shared-layer row (workspace_id IS NULL): what an unresolved caller is
    # SUPPOSED to receive. Doubles as the instrument's self-test subject.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "shared-doc", "title" => "#{@shared_marker} Doc"},
        @ds,
        []
      )

    {:ok, _} = Content.publish_document("shared-doc", "post", @ds, [])

    %{ws_a: ws_a}
  end

  # ── crit 2: instrument self-test — run and read this one FIRST ──────────────

  test "the probe is not blind: the shared-layer row the surface MUST return arrives",
       %{conn: conn} do
    resp = get(conn, "/v1/data/search/#{@ds}", q: String.downcase(@shared_marker))

    assert resp.status == 200
    body = resp.resp_body

    assert body =~ @shared_marker,
           "the probe cannot see a row it is entitled to — every 'no leak' " <>
             "result from this instrument would be blindness, not isolation"

    assert "shared-doc" in doc_ids(body)
  end

  # ── the leak arm: seat vacant, anonymous caller, foreign row ────────────────

  test "anonymous + Default seat VACANT → workspace A's row does NOT come back",
       %{conn: conn} do
    resp = get(conn, "/v1/data/search/#{@ds}", q: String.downcase(@foreign_marker))

    assert resp.status == 200
    body = resp.resp_body

    refute body =~ @foreign_marker,
           "GET /v1/data/search/#{@ds} returned another tenant's document to a " <>
             "caller that resolved NO workspace — the empty-scope class, back " <>
             "open on the search read path"

    refute "foreign-doc" in doc_ids(body)
  end

  # ── crit 3: caller-supplied scope is a SEPARATE arm ─────────────────────────

  test "?workspace_id=<A> is NOT honoured: naming a workspace you are not in buys nothing",
       %{conn: conn, ws_a: ws_a} do
    resp =
      get(conn, "/v1/data/search/#{@ds}",
        q: String.downcase(@foreign_marker),
        workspace_id: ws_a.id
      )

    assert resp.status == 200
    body = resp.resp_body

    refute body =~ @foreign_marker,
           "the caller named a workspace it is not a member of and RECEIVED its " <>
             "rows — `search/2` must keep taking its tenancy from " <>
             "`scope_opts(conn)` alone, never from the query string"

    refute "foreign-doc" in doc_ids(body)
  end

  # The resolved rows, so an absence is provable on structure and not only on a
  # substring that some future response shaping might stop echoing.
  defp doc_ids(body) do
    body
    |> Jason.decode!()
    |> Map.get("documents", [])
    |> Enum.map(&(&1["_id"] || &1["id"]))
  end
end
