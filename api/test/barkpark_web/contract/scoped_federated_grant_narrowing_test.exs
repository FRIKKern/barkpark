defmodule BarkparkWeb.Contract.ScopedFederatedGrantNarrowingTest do
  @moduledoc """
  ag-deny-matrix — the SCOPED FEDERATED cell, the one that was only code-traced.

  `GET /w/:ws/p/:proj/v1/search/:dataset` (`FederatedSearchController.search/2`
  mounted inside the `:scoped_api` block, router.ex) is the grant-narrowing
  sibling of the flat federated route. Its flat twin is covered by
  `federated_grant_deny_test.exs`, which records the OPPOSITE contract: the bare
  `:api` route folds no grant at all, so a grant can never WIDEN federated
  discovery. Nothing covered this route — `:scoped_api` runs
  `Plugs.ResolveWorkspace`, whose grant arm assigns `:caller_context` +
  `:grant_scoped_read`, `ScopeHelpers.scope_opts/1` turns that into
  `grant_scoped: true`, and `Content.Scope.maybe_scope_to_grants/2` (the single
  owner of the gate) narrows the search read. Until now that chain was traced in
  comments and never exercised end-to-end over HTTP on THIS door.

  The three arms, each non-vacuous by construction — the in-grant and
  out-of-grant documents differ ONLY by the grant's `type` rung (same workspace,
  same project, same dataset, same query term), so nothing but grant narrowing
  can separate them:

    1. DENY — a grant-admitted NON-MEMBER user sees the grant-covered document
       and NOT the uncovered one in the same workspace. Both are asserted, so a
       blanked response cannot pass.
    2. POSITIVE CONTROL — a member token sees BOTH. This proves the out-of-grant
       document is genuinely reachable on this route, so arm 1's `refute` refutes
       something that exists.
    3. NO OVER-REACH — grants only ADD access. A member's federated response is
       identical before and after a grant covering only ONE type is bound to
       that same member. Compared on the full JSON body minus the two fields that
       are nondeterministic by design (`ms`, the elapsed milliseconds, and
       `searchEventId`, a fresh row id per search) — every field that carries a
       visibility decision is compared byte for byte.

  The grantee drive is the one `export_revision_grant_narrowing_test.exs`
  established: she presents her own api token (minted into her OWN workspace —
  satisfies token resolution, confers nothing here) AND her login session cookie
  (`:scoped_api` resolves a cookie on GET, so `ResolveWorkspace`'s
  `not member? and not is_nil(user)` grant arm is reachable).

  `async: false`: the fixtures write shared `schema_definitions` rows and the
  suite shares its test database with every other agent.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.AccessFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Content, Tenancy}

  @ds "production"
  @password "correct-horse-battery"
  @term "scopedfedgrantterm"

  # Separated ONLY by the grant's `type` rung.
  @in_grant_type "sfgnGrantedPost"
  @out_of_grant_type "sfgnLedgerSecret"

  @in_grant_title "#{@term} in-grant post"
  @out_of_grant_title "#{@term} out-of-grant ledger secret"

  setup %{conn: conn} do
    ws = create_workspace!("sfgn-ws-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "sfgn-proj-#{System.unique_integer([:positive])}")

    for type <- [@in_grant_type, @out_of_grant_type] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => type, "title" => type, "visibility" => "public", "fields" => []},
          @ds
        )
    end

    seed = fn type, doc_id, title ->
      {:ok, _} =
        create_document_in!(ws, proj, type, %{"_id" => doc_id, "title" => title}, @ds)

      # publish is tenancy-scoped — a bare publish looks in Default and 404s.
      {:ok, _} =
        Content.publish_document(doc_id, type, @ds, workspace_id: ws.id, project_id: proj.id)
    end

    seed.(@in_grant_type, "sfgn-in-#{System.unique_integer([:positive])}", @in_grant_title)

    seed.(
      @out_of_grant_type,
      "sfgn-out-#{System.unique_integer([:positive])}",
      @out_of_grant_title
    )

    # Alice: a signed-in user who is NOT a member of `ws`, with her own
    # workspace and a read token minted into it. Neither credential says
    # anything about `ws`.
    email = "sfgn-grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, alice} = Accounts.register_user(%{email: email, password: @password})
    {:ok, alice_session} = Accounts.create_user_session_token(alice)

    ws_a = create_workspace!("sfgn-alice-#{System.unique_integer([:positive])}")
    {:ok, _} = Tenancy.Auth.create_membership(ws_a.id, alice.id, "admin", "user")
    alice_raw = "sfgn-alice-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(alice_raw, "sfgn-alice-app", @ds, ["read"], ws_a.id)

    {:ok,
     conn: conn,
     ws: ws,
     proj: proj,
     alice: alice,
     alice_session: alice_session,
     alice_raw: alice_raw}
  end

  defp search_path(ws, proj),
    do: "/w/#{ws.slug}/p/#{proj.slug}/v1/search/#{@ds}?q=#{@term}&surfaces=documents"

  defp alice_conn(conn, %{alice_session: session, alice_raw: raw}) do
    conn
    |> Plug.Test.init_test_session(%{"user_session" => session})
    |> put_req_header("authorization", "Bearer " <> raw)
  end

  defp member_token!(ws) do
    raw = "sfgn-member-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "sfgn-member", @ds, ["read"], ws.id)
    raw
  end

  defp titles(body),
    do: body |> get_in(["results", "documents", "hits"]) |> Enum.map(& &1["title"])

  # Everything except the two fields that vary per request by design.
  defp comparable(body), do: Map.drop(body, ["ms", "searchEventId"])

  describe "GRANTEE — a non-member holding a type-scoped read grant" do
    setup ctx do
      bind_grant!(ctx.ws, ctx.alice, %{
        project_id: ctx.proj.id,
        dataset: @ds,
        type: @in_grant_type,
        capabilities: ["read"]
      })

      :ok
    end

    test "reaches the scoped federated door at all — the reachability precondition", ctx do
      conn = ctx.conn |> alice_conn(ctx) |> get(search_path(ctx.ws, ctx.proj))

      assert conn.status == 200,
             "PRECONDITION FAILED: the grant-derived caller did not reach " <>
               "FederatedSearchController over HTTP (#{conn.status} #{conn.resp_body}). " <>
               "Every assertion below would then be vacuous."
    end

    test "the response is narrowed to the grant ladder — covered in, uncovered out", ctx do
      body =
        ctx.conn |> alice_conn(ctx) |> get(search_path(ctx.ws, ctx.proj)) |> json_response(200)

      seen = titles(body)

      assert @in_grant_title in seen,
             "OVER-REACH: narrowing hid the grantee's OWN document " <>
               "(titles seen: #{inspect(seen)})"

      refute @out_of_grant_title in seen,
             "LEAK: scoped federated search returned #{inspect(@out_of_grant_title)}, a " <>
               "document outside the caller's grant ladder in the same workspace " <>
               "(titles seen: #{inspect(seen)})"
    end
  end

  describe "MEMBER — the positive control and the no-over-reach guard" do
    test "a member token sees BOTH documents — the out-of-grant row is reachable here", ctx do
      body =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> member_token!(ctx.ws))
        |> get(search_path(ctx.ws, ctx.proj))
        |> json_response(200)

      seen = titles(body)

      assert @in_grant_title in seen

      assert @out_of_grant_title in seen,
             "the DENY arm above would be vacuous: the out-of-grant document is " <>
               "not reachable on this route even for a member (titles: #{inspect(seen)})"
    end

    test "a member's response is unchanged by a grant that covers only one type", ctx do
      # The SAME principal is a member AND (below) a grantee. Membership decides
      # first in `ResolveWorkspace`, so no `:grant_scoped_read` is ever set for
      # her and the read must not narrow — grants only ADD access.
      {:ok, _} = Tenancy.Auth.create_membership(ctx.ws.id, ctx.alice.id, "admin", "user")

      request = fn ->
        build_conn()
        |> alice_conn(ctx)
        |> get(search_path(ctx.ws, ctx.proj))
        |> json_response(200)
        |> comparable()
      end

      before = request.()

      assert @in_grant_title in titles(before) and @out_of_grant_title in titles(before),
             "PRECONDITION FAILED: the member baseline is not both documents " <>
               "(titles: #{inspect(titles(before))}) — the comparison below would be vacuous"

      bind_grant!(ctx.ws, ctx.alice, %{
        project_id: ctx.proj.id,
        dataset: @ds,
        type: @in_grant_type,
        capabilities: ["read"]
      })

      assert request.() == before,
             "a grant NARROWED a member's federated response — grants only ADD access"
    end
  end
end
