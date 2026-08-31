defmodule BarkparkWeb.AnalyticsGrantScopeReachabilityTest do
  @moduledoc """
  RESEARCH + PROOF lane for `task-b78911ac2bd91c81`.

  `Content.document_stats/2`, `Content.total_documents/2` and
  `Content.recent_activity/2` (delegated from `Barkpark.Content` into
  `Barkpark.Content.Analytics`) thread NO grant clause — they scope by
  dataset + workspace/project only and never call
  `Barkpark.Content.Scope.maybe_scope_to_grants/2`, the single owner of the
  `:grant_scoped` gate. Their sibling `Analytics.type_census/2` DOES.

  `BarkparkWeb.AnalyticsController.index/2` is the ONLY reader of the three in
  `barkpark_web`, and it already hands them the grant flag: it calls
  `ScopeHelpers.scope_opts(conn)`, which emits `grant_scoped: true` +
  `caller_context` whenever `ResolveWorkspace` admitted a grant-derived caller.
  The three functions simply ignore both keys.

  This suite settles REACHABILITY on the live HTTP surface, which is the whole
  question the task leaves open:

    * `GET /w/:ws/p/:proj/v1/data/analytics/:dataset`
      pipes `[:scoped_api, :require_token]`. `:scoped_api` runs
      `scoped_api_optional_credential` (cookie admitted unconditionally on GET)
      then `ResolveWorkspace`, whose GRANT arm requires a signed-in
      `%Accounts.User{}` non-member — i.e. a COOKIE session. `:require_token`
      then runs `Plugs.RequireToken`, which reads ONLY the
      `Authorization: Bearer` header.

  So the reachable principal is the INTERSECTION: a browser carrying BOTH a
  Studio session cookie (which supplies the grant admission) AND some valid
  bearer token that is not a member of the target workspace (which satisfies
  `:require_token`). That is exactly what the Studio ships — LiveView hands
  Web Components a `data-token` they send as a Bearer header while the cookie
  rides along.

  Tests below, in order:

    1. cookie-session-only  -> `:require_token` REJECTS (401). Pins the gate.
    2. cookie + `session["api_token"]`, still no header -> REJECTS (401).
       `OptionalSessionToken` assigns `:api_token` but never sets the header,
       and `RequireToken` re-reads the header, so the assign does not satisfy it.
    3. cookie + Bearer, grantee narrowed to ONE type -> the leak.

  RED-BEFORE: test 3 fails on `origin/main`. It is a PROOF file only — it
  changes no production code. The fix belongs to Lead 1/7 in
  `api/lib/barkpark/content/analytics.ex`: thread `maybe_scope_to_grants/2`
  into all three, exactly as `type_census/2` already does. `MutationEvent`
  carries `project_id`, `dataset`, `type` and `doc_id`, so
  `Scope.grant_ladder_condition/1` applies to `recent_activity/2` unchanged.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.AccessFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "l8_analytics_ds"
  @password "correct-horse-battery"

  # The grantee is granted READ on type "post" ONLY. "ledger" is the
  # out-of-grant type whose existence, volume and DOCUMENT NAMES must never
  # reach them.
  @granted_type "post"
  @secret_type "ledger"

  setup do
    # TARGET workspace — deliberately NOT the seeded "default" slug, so
    # `ResolveWorkspace`'s anonymous-Default allowance cannot mask the grant arm.
    ws_target = create_workspace!()
    proj_target = create_project!(ws_target)

    # The grantee's OWN workspace. Their bearer token is a member here and
    # nowhere else, so it cannot authorize the target workspace on its own.
    ws_home = create_workspace!()

    for type <- [@granted_type, @secret_type] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => type, "title" => type, "visibility" => "public", "fields" => []},
          @dataset,
          workspace_id: ws_target.id,
          project_id: proj_target.id
        )
    end

    {:ok, _} =
      create_document_in!(
        ws_target,
        proj_target,
        @granted_type,
        %{"_id" => "granted-doc", "title" => "In Grant"},
        @dataset
      )

    {:ok, _} =
      create_document_in!(
        ws_target,
        proj_target,
        @secret_type,
        %{"_id" => "acquisition-price-list", "title" => "Acquisition Price List"},
        @dataset
      )

    {:ok, ws_target: ws_target, proj_target: proj_target, ws_home: ws_home}
  end

  describe "the :require_token gate on GET /w/:ws/p/:proj/v1/data/analytics/:dataset" do
    test "a cookie-session grantee with NO Bearer header is REJECTED", ctx do
      {user, conn} = grantee_session(build_conn())
      _grant = narrow_grant!(ctx, user)

      conn = get(conn, analytics_path(ctx))

      assert conn.status == 401,
             "expected :require_token to reject a header-less cookie session, got #{conn.status}"
    end

    test "a cookie session carrying session[\"api_token\"] but no header is REJECTED", ctx do
      {_token, raw} = member_token(ctx.ws_home)
      {grantee, conn} = grantee_session(build_conn(), %{"api_token" => raw})
      _grant = narrow_grant!(ctx, grantee)

      conn = get(conn, analytics_path(ctx))

      assert conn.status == 401,
             "OptionalSessionToken's :api_token assign must not satisfy RequireToken " <>
               "(it re-reads the Authorization header), got #{conn.status}"
    end
  end

  describe "grant row-narrowing on the analytics siblings" do
    test "a grantee narrowed to ONE type reads the WHOLE workspace's analytics", ctx do
      {_token, raw} = member_token(ctx.ws_home)
      {grantee, conn} = grantee_session(build_conn())
      _grant = narrow_grant!(ctx, grantee)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> get(analytics_path(ctx))

      # Reachability, stated as an assertion: the grant arm admitted the
      # non-member USER while the Bearer header satisfied :require_token.
      assert conn.status == 200,
             "grantee + bearer did not reach the analytics controller (status #{conn.status})"

      body = json_response(conn, 200)

      # Non-vacuity: the in-grant type IS present, so a blanket empty response
      # could never make the leak assertions below pass silently.
      types = body["types"] |> Enum.map(& &1["type"]) |> Enum.sort()
      assert @granted_type in types, "grantee could not see its OWN in-grant type"

      activity_ids = body["recent_activity"] |> Enum.map(& &1["doc_id"]) |> Enum.sort()

      # All three siblings are checked TOGETHER so one run reports every leaking
      # surface, not just whichever assertion happens to fail first.
      violations =
        []
        |> maybe_violation(
          @secret_type in types,
          "document_stats — the out-of-grant TYPE #{@secret_type} appears in the " <>
            "census (types: #{inspect(types)})"
        )
        |> maybe_violation(
          body["total_documents"] != 1,
          "total_documents — expected 1 in-grant document, got " <>
            "#{body["total_documents"]} (out-of-grant rows counted)"
        )
        |> maybe_violation(
          Enum.any?(activity_ids, &String.contains?(&1, "acquisition-price-list")),
          "recent_activity — the DOCUMENT NAME of an out-of-grant document is " <>
            "returned (doc_ids: #{inspect(activity_ids)})"
        )

      assert violations == [],
             "GRANT-BOUNDARY LEAK on the analytics siblings, reached by a " <>
               "cookie-session grantee presenting any valid Bearer token:\n  - " <>
               Enum.join(Enum.reverse(violations), "\n  - ")
    end

    test "NEGATIVE ARM: a full workspace MEMBER still reads the COMPLETE payload", ctx do
      # Members carry no `:grant_scoped_read`, so `maybe_scope_to_grants/2` must
      # be a provable NO-OP on this path. This test passes BOTH before and after
      # the fix — a fix that narrows a member has over-reached, and this arm is
      # what catches it.
      {_token, raw} = member_token(ctx.ws_target)

      body =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw}")
        |> get(analytics_path(ctx))
        |> json_response(200)

      types = body["types"] |> Enum.map(& &1["type"]) |> Enum.sort()
      activity_ids = body["recent_activity"] |> Enum.map(& &1["doc_id"]) |> Enum.sort()

      assert types == Enum.sort([@granted_type, @secret_type]),
             "a MEMBER lost sight of a type (got #{inspect(types)})"

      assert body["total_documents"] == 2,
             "a MEMBER's total was narrowed (got #{body["total_documents"]})"

      assert "drafts.acquisition-price-list" in activity_ids,
             "a MEMBER lost sight of a document in recent_activity " <>
               "(doc_ids: #{inspect(activity_ids)})"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp maybe_violation(acc, true, message), do: [message | acc]
  defp maybe_violation(acc, _false, _message), do: acc

  defp analytics_path(%{ws_target: ws, proj_target: proj}),
    do: "/w/#{ws.slug}/p/#{proj.slug}/v1/data/analytics/#{@dataset}"

  # A signed-in USER who is NOT a tenancy member — the only principal
  # `ResolveWorkspace`'s grant arm will consider. Mirrors the `grantee_session/1`
  # copies in the scoped-Studio suites.
  defp grantee_session(conn, extra_session \\ %{}) do
    email = "l8-grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    {:ok, raw} = Accounts.create_user_session_token(user)

    session = Map.merge(%{"user_session" => raw}, extra_session)
    {user, Plug.Test.init_test_session(conn, session)}
  end

  # A plain read token, a MEMBER of `ws` and of nothing else. It satisfies
  # `RequireToken` (a real Bearer) without ever authorizing the target workspace.
  defp member_token(ws) do
    raw = "l8-tok-" <> Ecto.UUID.generate()

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "l8-home",
        dataset: @dataset,
        permissions: ["read"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member")
    {token, raw}
  end

  # The grant under test: READ, on the target workspace/project/dataset, but
  # narrowed to `@granted_type` alone.
  defp narrow_grant!(%{ws_target: ws, proj_target: proj}, user) do
    bind_grant!(ws, user, %{
      project_id: proj.id,
      dataset: @dataset,
      type: @granted_type,
      capabilities: ["read"]
    })
  end
end
