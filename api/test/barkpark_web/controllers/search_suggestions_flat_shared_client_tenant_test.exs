defmodule BarkparkWeb.SearchSuggestionsFlatSharedClientTenantTest do
  @moduledoc """
  HTTP reachability of the shared-client-header collision on the FLAT
  suggestions route (task `sugg-recent-shared-client-flat-residual`).

  THE ROUTE. `get("/search/:dataset/suggestions", SearchController,
  :search_suggestions)` inside `scope "/v1/data"`, `pipe_through([:api,
  :api_grant_read])` — `BarkparkWeb.Router`.

  THE CHAIN, driven end-to-end here rather than at the module layer:

    1. `Plugs.DeriveWorkspaceFromToken` runs first on `:api` and NO-OPS for a
       caller with no verified bearer, so `Plugs.AssignDefaultScope` stamps the
       seeded Default workspace onto EVERY anonymous flat-route request.
    2. `BarkparkWeb.SearchIntel.actor_key/1` has no `:api_token` to namespace
       under, so it takes its third arm: `"client:" <> workspace_segment(conn)
       <> ":" <> client`. The workspace segment is the SERVER-resolved
       `:current_workspace` — which step 1 just made a CONSTANT.
    3. `Barkpark.Search.Intelligence.recent_queries/6` therefore reads a bucket
       keyed on {surface, scope, actor_key, workspace_id} whose every component
       is identical for two different customers' anonymous visitors that share
       one hardcoded `x-bp-search-client` value. `scope_ws/2` cannot separate
       them because there is nothing to separate ON.

  WHAT THIS IS: a CHARACTERIZATION test. `flat route: a shared client id unions
  two customers' recent queries` asserts the LEAK AS IT SHIPS TODAY, on purpose,
  and runs in the default lane — the repo's own rule (`test/test_helper.exs`) is
  that a test parked behind a tag no CI step includes cannot fail, so this is not
  parked. When the residual is closed, that ONE test inverts to `refute` and this
  moduledoc gets rewritten; every other test in this file is a plain regression
  lock that must keep passing through the fix.

  WHAT IT IS NOT: a claim that the header is guessable. The shipped UI mints a
  per-session `crypto.randomUUID()`, so real callers never collide. The exposure
  requires a widget vendor to hardcode ONE non-random client id across two
  customers — a footgun, and a reachable one.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Search.Event

  @dataset "production"

  # A widget vendor's HARDCODED client id, embedded verbatim by both customers.
  # This is the misuse under test — not the shipped per-session UUID.
  @shared_client "acme-widget-v1"

  # Tenant A's end user typed this into tenant A's site search box. It must
  # never be readable by tenant B.
  @tenant_a_query "alpha merger memo"
  @tenant_b_query "beta pricing sheet"

  setup do
    ensure_default_scope!()

    # TWO GENUINELY DISTINCT TENANTS — separate Workspace rows, separate
    # Projects, and (below) separate workspace-bound tokens.
    ws_a = create_workspace!("sugg-flat-tenant-a-#{uniq()}")
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!("sugg-flat-tenant-b-#{uniq()}")
    proj_b = create_project!(ws_b)

    raw_token_a = "sugg-flat-token-a-#{uniq()}"
    raw_token_b = "sugg-flat-token-b-#{uniq()}"

    {:ok, _} = Auth.create_token(raw_token_a, "tenant-a", @dataset, ["read"], ws_a.id)
    {:ok, _} = Auth.create_token(raw_token_b, "tenant-b", @dataset, ["read"], ws_b.id)

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @dataset
    )

    # Corpus lives in the Default bucket, which is what an anonymous flat-route
    # read resolves to — so the recorded searches actually return hits and the
    # recorder is not skipped for an unrelated reason.
    Content.create_document(
      "post",
      %{"doc_id" => "drafts.flat-collide-1", "title" => "alpha merger memo"},
      @dataset
    )

    Content.publish_document("flat-collide-1", "post", @dataset)

    Content.create_document(
      "post",
      %{"doc_id" => "drafts.flat-collide-2", "title" => "beta pricing sheet"},
      @dataset
    )

    Content.publish_document("flat-collide-2", "post", @dataset)

    Repo.delete_all(from(e in Event, where: e.surface == "documents"))

    %{
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      proj_b: proj_b,
      raw_token_a: raw_token_a,
      raw_token_b: raw_token_b
    }
  end

  defp uniq, do: Integer.to_string(System.unique_integer([:positive]))

  # A fresh anonymous browser. `scoped_conn/0` (never a bare `build_conn/0`) so
  # the rate limiter buckets per test process — a 429 here would arrive dressed
  # as "no recents leaked" and silently vacuum the whole file.
  defp visitor(client_id) do
    scoped_conn()
    |> put_req_header("x-bp-search-client", client_id)
  end

  # Drive a real search through the FLAT route, committing the event.
  defp record_search!(conn, query) do
    conn
    |> put_req_header("x-bp-search-record", "1")
    |> get(~p"/v1/data/search/#{@dataset}?q=#{query}")
    |> refute_rate_limited!()
    |> json_response(200)
  end

  defp recents!(conn) do
    body =
      conn
      |> get(~p"/v1/data/search/#{@dataset}/suggestions")
      |> refute_rate_limited!()
      |> json_response(200)

    Enum.map(body["result"]["recent"], & &1["query"])
  end

  # ── The fixture must reach the code ────────────────────────────────────────

  test "SANITY: an anonymous flat-route search with a client header is recorded and read back" do
    assert %{"searchEventId" => id} = record_search!(visitor(@shared_client), @tenant_a_query)

    assert is_binary(id),
           "the anonymous flat-route recorder did not write an event — every leak " <>
             "assertion below would be vacuously green"

    assert @tenant_a_query in recents!(visitor(@shared_client))
  end

  # ── THE RESIDUAL, at the HTTP layer ────────────────────────────────────────

  test "flat route: a shared client id unions two customers' recent queries" do
    # Tenant A's visitor searches through A's embedded widget.
    record_search!(visitor(@shared_client), @tenant_a_query)

    # Tenant B's visitor — a different customer, a different browser, the SAME
    # vendor-hardcoded client id — searches B's own site, then opens B's
    # suggestions dropdown on the same flat route.
    record_search!(visitor(@shared_client), @tenant_b_query)

    b_recents = recents!(visitor(@shared_client))

    assert @tenant_b_query in b_recents,
           "B cannot even see its OWN query — the fixture never reached the read"

    assert @tenant_a_query in b_recents,
           """
           CHARACTERIZATION DRIFTED. Tenant B no longer sees tenant A's query on
           the flat route with a shared client id — which means the residual has
           been CLOSED. That is good news: invert this assertion to `refute`,
           rewrite this module's @moduledoc, and stamp
           sugg-recent-shared-client-flat-residual.

           got: #{inspect(b_recents)}
           """
  end

  # ── Non-vacuity: the read really does filter on actor_key ─────────────────

  test "flat route: a DIFFERENT client id does not see the other customer's queries" do
    record_search!(visitor(@shared_client), @tenant_a_query)

    other = recents!(visitor("other-vendor-widget-v9"))

    refute @tenant_a_query in other,
           "the recent read is not filtering on actor_key at all — the collision " <>
             "test above proves nothing"
  end

  test "flat route: a tokenless caller with NO client header gets no recents" do
    record_search!(visitor(@shared_client), @tenant_a_query)

    # actor_key == "anon", which `recent_queries/6` answers with [] by contract.
    assert recents!(scoped_conn()) == []
  end

  # ── The same two tenants, WITH a tenant signal, do NOT collide ────────────

  test "flat route: workspace-bound tokens keep two tenants apart despite the shared client id",
       %{raw_token_a: raw_token_a, raw_token_b: raw_token_b} do
    # Same route, same shared client id — the only difference is that each
    # caller now proves an identity, so `actor_key/1` takes its token arm.
    visitor(@shared_client)
    |> put_req_header("authorization", "Bearer " <> raw_token_a)
    |> record_search!(@tenant_a_query)

    b_recents =
      visitor(@shared_client)
      |> put_req_header("authorization", "Bearer " <> raw_token_b)
      |> recents!()

    refute @tenant_a_query in b_recents,
           "REGRESSION: the token-first ordering in SearchIntel.actor_key/1 no " <>
             "longer namespaces the client header under the bearer"
  end

  # ── Why the widget cannot just use the tenant-safe route ──────────────────

  test "the scoped mirror is closed to anonymous callers, so the flat route is the only option",
       %{ws_a: ws_a, proj_a: proj_a} do
    conn =
      visitor(@shared_client)
      |> get(~p"/w/#{ws_a.slug}/p/#{proj_a.slug}/v1/data/search/#{@dataset}/suggestions")
      |> refute_rate_limited!()

    assert conn.status == 403

    # Assert the DISCRIMINATING field: two different gates on this surface
    # return 403 with the same `forbidden` code, so the status alone is a weak
    # assertion. `Plugs.ResolveWorkspace` refuses on MEMBERSHIP.
    body = json_response(conn, 403)

    assert body["error"]["reason"] == "forbidden_membership",
           "expected the ResolveWorkspace membership refusal, got: #{inspect(body["error"])}"
  end
end
