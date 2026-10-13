defmodule BarkparkWeb.Integration.AccountSessionDataMutateTest do
  @moduledoc """
  task-27006bc488ad1570 — a seated member logged in at `/v1/auth/login`
  (no admin, no Bearer token of their own) can read AND mutate the scoped
  data API with that login alone.

  Mirrors `AccountSessionMediaWriteTest` (gfr-w1-account-session-bearer-gap)
  exactly, for the docs-mutate pipeline instead of media: `:scoped_mutate`
  used to run plain `OptionalToken` (bearer-only), so `ResolveWorkspace` 403'd
  `not_a_member` for a real member whose browser carried only the
  `user_session` cookie. `RequireWritePermission` already had an ACCOUNT arm
  (`account_write?/1`) built for this exact gap — it was simply unreachable
  here because nothing upstream ever populated `:current_user` on this
  pipeline. The fix swaps `OptionalToken` for `OptionalSessionToken` +
  `RequireBearerOrSessionToken`, the same pair `:scoped_media_mutate` already
  uses, CSRF-gated identically (`x-requested-with`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Content, Tenancy}

  @ds "production"

  setup %{conn: conn} do
    ws = create_workspace!("acct-mutate-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "acct-mutate-p-#{System.unique_integer([:positive])}")

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @ds,
        workspace_id: ws.id,
        project_id: proj.id
      )

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp account_session!(conn, ws, role) do
    email = "acct-mutate-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  # Same discriminator as scoped_role_gate_test.exs's `scoped_mutate/2`: an
  # invalid payload (no `_type`) so a write-ALLOWED caller reaches validation
  # (422) and a write-DENIED caller is gated (403) before it ever does.
  defp scoped_mutate(conn, ws, proj, opts \\ []) do
    conn =
      if Keyword.get(opts, :csrf, true),
        do: put_req_header(conn, "x-requested-with", "bp-studio"),
        else: conn

    body = %{"mutations" => [%{"create" => %{"_id" => "no-type-1", "title" => "x"}}]}

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/w/#{ws.slug}/p/#{proj.slug}/v1/data/mutate/#{@ds}", Jason.encode!(body))
  end

  describe "an account-session member, holding NO bearer" do
    test "reaches validation on a scoped mutate (403-vs-not-403: NOT 403)", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {_u, conn} = account_session!(conn, ws, "member")
      resp = scoped_mutate(conn, ws, proj)

      refute resp.status == 403,
             "an account member was refused the scoped mutate: #{resp.status} #{resp.resp_body}"

      assert resp.status == 422
    end

    test "reads the scoped query route too (the GET half already worked)", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {_u, conn} = account_session!(conn, ws, "member")
      resp = get(conn, "/w/#{ws.slug}/p/#{proj.slug}/v1/data/query/#{@ds}/post")

      assert resp.status == 200, "an account member was refused the scoped read: #{resp.status}"
    end

    test "is REFUSED without the x-requested-with header — the cookie branch is CSRF-gated", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {_u, conn} = account_session!(conn, ws, "member")
      resp = scoped_mutate(conn, ws, proj, csrf: false)

      assert resp.status == 403
      err = Jason.decode!(resp.resp_body)["error"]
      assert err["code"] == "csrf_required"
    end

    test "a NON-member with a valid account session is still refused", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      other = create_workspace!("acct-mutate-other-#{System.unique_integer([:positive])}")
      {_u, conn} = account_session!(conn, other, "admin")
      resp = scoped_mutate(conn, ws, proj)

      assert resp.status == 403
    end
  end
end
