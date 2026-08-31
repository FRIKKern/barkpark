defmodule BarkparkWeb.Integration.AnalyticsGrantNarrowingTest do
  @moduledoc """
  task-59d79b4058a7a434 — `GET /w/:ws/p/:proj/v1/data/analytics/:dataset` must
  honour the caller's grant ladder on ALL THREE of its aggregates.

  `Analytics.type_census/2` was hardened under task-c6d2e34c64100678. Its three
  siblings in the same module — `document_stats/2`, `total_documents/2` and
  `recent_activity/2` — were not, and `AnalyticsController.index/2` calls
  exactly those three. The filing row believed the gap was LATENT, reasoning
  that `:require_token` demands a Bearer while `ResolveWorkspace`'s grant arm
  admits only a signed-in non-member USER. It is not latent: those two
  predicates are not mutually exclusive, and this suite is the proof.

  A grantee presents BOTH credentials, and both are legitimately hers:

    * her OWN api token, minted into her OWN workspace — satisfies
      `RequireToken`, and confers nothing in the victim workspace, so
      `ResolveWorkspace`'s membership arm still reads non-member;
    * her login session cookie — `:scoped_api` resolves it on GET
      (`scoped_api_optional_credential/2` → `OptionalSessionToken`, which
      assigns `:current_user` REGARDLESS of the bearer), so the grant arm's
      `not member? and not is_nil(user)` holds and `:grant_scoped_read` is set.

  `ScopeHelpers.scope_opts/1` then threads `grant_scoped: true` plus the
  grant-bearing `caller_context` into the controller's opts — and all three
  aggregates dropped them on the floor. Because `maybe_scope_to_grants/2`
  DEFAULTS the flag to false, the absent call meant "do not narrow", not
  "narrow to nothing": a grantee scoped to ONE type read back the name and
  count of every type in the project, the grand total, and — through
  `recent_activity` — the doc_ids and types of documents her grant does not
  cover. Existence and volume across a grant boundary.

  The MEMBER arm is the over-reach guard: grants only ADD access, so a member
  carries no flag and must see a byte-identical response. A clamp that hides a
  member's own types is a worse bug than the leak it closes.

  Every request below goes over HTTP through the real endpoint + router, so
  `:scoped_api` and `:require_token` run exactly as in production.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.AccessFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Tenancy}

  @ds "production"
  @password "correct-horse-battery"

  # The type the grant COVERS, and the type it does NOT. Same workspace, same
  # project, same dataset — the ONLY thing separating the second from the caller
  # is the grant's `type` rung, so nothing but grant narrowing can hide it.
  @in_grant_type "grantedMemo"
  @out_of_grant_type "ledgerSecret"

  setup %{conn: conn} do
    ensure_default_scope!()

    ws_b = create_workspace!("analytics-victim-#{System.unique_integer([:positive])}")
    proj_b = create_project!(ws_b, "analytics-vp-#{System.unique_integer([:positive])}")

    {:ok, _} = create_document_in!(ws_b, proj_b, @in_grant_type, %{"title" => "in"}, @ds)
    {:ok, _} = create_document_in!(ws_b, proj_b, @out_of_grant_type, %{"title" => "out"}, @ds)

    # Alice: an ordinary signed-in user who is NOT a member of workspace B, with
    # her own workspace and a read token minted into it. This is the ordinary
    # state of any Barkpark user; neither credential says anything about B.
    email = "analytics-grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, alice} = Accounts.register_user(%{email: email, password: @password})
    {:ok, alice_session} = Accounts.create_user_session_token(alice)

    ws_a = create_workspace!("analytics-alice-#{System.unique_integer([:positive])}")
    {:ok, _} = Tenancy.Auth.create_membership(ws_a.id, alice.id, "admin", "user")
    alice_raw = "alice-analytics-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(alice_raw, "alice-app", @ds, ["read"], ws_a.id)

    {:ok,
     conn: conn,
     ws_b: ws_b,
     proj_b: proj_b,
     alice: alice,
     alice_session: alice_session,
     alice_raw: alice_raw}
  end

  defp analytics_path(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/v1/data/analytics/#{@ds}"

  defp alice_conn(conn, %{alice_session: session, alice_raw: raw}) do
    conn
    |> Plug.Test.init_test_session(%{"user_session" => session})
    |> put_req_header("authorization", "Bearer " <> raw)
  end

  defp member_conn(conn, ws) do
    raw = "analytics-member-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "analytics-member", @ds, ["read"], ws.id)
    put_req_header(conn, "authorization", "Bearer " <> raw)
  end

  defp types_in(body), do: body["types"] |> Enum.map(& &1["type"]) |> Enum.sort()

  describe "GRANTEE — a non-member holding a type-scoped read grant on B" do
    setup ctx do
      grant =
        bind_grant!(ctx.ws_b, ctx.alice, %{
          project_id: ctx.proj_b.id,
          dataset: @ds,
          type: @in_grant_type,
          capabilities: ["read"]
        })

      {:ok, grant: grant}
    end

    test "reaches the analytics door at all — the reachability precondition", ctx do
      conn = ctx.conn |> alice_conn(ctx) |> get(analytics_path(ctx.ws_b, ctx.proj_b))

      assert conn.status == 200,
             "PRECONDITION FAILED: the grant-derived caller did not reach " <>
               "AnalyticsController over HTTP (#{conn.status} #{conn.resp_body}). " <>
               "Every assertion below would then be vacuous."
    end

    test "document_stats does not name a type outside the grant ladder", ctx do
      conn = ctx.conn |> alice_conn(ctx) |> get(analytics_path(ctx.ws_b, ctx.proj_b))
      body = json_response(conn, 200)

      assert @in_grant_type in types_in(body),
             "the grant's OWN type must still be counted — narrowing must not " <>
               "blank the grantee's analytics"

      refute @out_of_grant_type in types_in(body),
             "LEAK: document_stats named a document type outside the caller's " <>
               "grant, with its published/draft counts"
    end

    test "total_documents does not count rows outside the grant ladder", ctx do
      conn = ctx.conn |> alice_conn(ctx) |> get(analytics_path(ctx.ws_b, ctx.proj_b))
      body = json_response(conn, 200)

      assert body["total_documents"] == 1,
             "LEAK: total_documents disclosed the VOLUME of the project " <>
               "(expected 1, the grantee's own row; got #{body["total_documents"]})"
    end

    test "recent_activity does not surface mutations outside the grant ladder", ctx do
      conn = ctx.conn |> alice_conn(ctx) |> get(analytics_path(ctx.ws_b, ctx.proj_b))
      body = json_response(conn, 200)

      leaked = Enum.filter(body["recent_activity"], &(&1["type"] == @out_of_grant_type))

      assert leaked == [],
             "LEAK: recent_activity surfaced the doc_ids of documents outside " <>
               "the caller's grant: #{inspect(Enum.map(leaked, & &1["doc_id"]))}"
    end
  end

  describe "MEMBER — the aggregates are untouched (grants only ADD access)" do
    test "a full member of B still sees EVERY type, the true total, and all activity",
         ctx do
      conn = ctx.conn |> member_conn(ctx.ws_b) |> get(analytics_path(ctx.ws_b, ctx.proj_b))
      body = json_response(conn, 200)

      # This arm is also the COLLIDING-FIXTURE proof: the out-of-grant row really
      # is visible on this route, so the grantee refutes above are refuting
      # something that genuinely exists rather than passing on an empty response.
      assert @in_grant_type in types_in(body)

      assert @out_of_grant_type in types_in(body),
             "OVER-REACH: the clamp hid a type from a legitimate member"

      assert body["total_documents"] == 2

      assert Enum.any?(body["recent_activity"], &(&1["type"] == @out_of_grant_type)),
             "OVER-REACH: the clamp hid a member's own mutation events"
    end
  end
end
