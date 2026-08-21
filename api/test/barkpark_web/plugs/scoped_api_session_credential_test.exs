defmodule BarkparkWeb.Plugs.ScopedApiSessionCredentialTest do
  @moduledoc """
  Gyldendal field report #15 — the Studio media library 403, and the error copy
  that mis-filed it as a permission bug.

  THE CHAIN, as it stood on main. A Studio operator who signed in with an
  ACCOUNT (`session["user_session"]`) carries no `session["api_token"]` — no
  account/SSO login writes that key — so `LiveAuth.:fetch_api_token` renders
  `<bp-asset-explorer data-token="">`. The explorer then calls the scoped media
  index with no credential at all, and `:scoped_api` was the last
  media-adjacent pipeline without `:fetch_session` + `OptionalSessionToken`: its
  `ResolveWorkspace` could not see the browser's session, the `%User{}` arm was
  structurally unreachable, and the membership gate 403'd a real member.
  `:scoped_media_mutate` had carried the cookie-aware shape for media WRITES
  since it shipped; media READS never got it.

  What is pinned here:

    * an account-session MEMBER reads `GET /w/:ws/p/:proj/v1/media/:dataset`,
    * a non-member with the same session shape is still refused (session
      admission resolves a principal, it never grants membership),
    * anonymous is still refused — the fail-closed default is unchanged,
    * the refusal states a MEMBERSHIP reason and keeps its 403 status, and
    * the CSRF posture on the pipeline's non-GET routes: the cookie is a
      credential unconditionally on GET/HEAD (side-effect-free), and on a
      state-changing method only behind the `x-requested-with` header that
      `RequireBearerOrSessionToken` already demands of its own cookie branch.

  MUTATION-PROOF, run, with the output recorded here so the merge carries it.

  Revert ONLY router.ex's `plug(:scoped_api_optional_credential)` back to
  `plug(BarkparkWeb.Plugs.OptionalToken)` → 6 tests, 2 failures:

      1) test ... a member with an account session reads the scoped media index
         ** (RuntimeError) expected response with status 200, got: 403
      2) test ... the same POST WITH x-requested-with is authenticated as the member
         code: refute resp.status == 403
         left: 403

  Revert ONLY the error-copy half instead (`resolve_workspace.ex` back to
  `{:error, :forbidden}`) → 6 tests, 1 failure, and it is a DIFFERENT test:

      1) test ... 403 body says membership and keeps its status
         code:  assert error["reason"] == "not_a_member"
         left:  nil
         right: "not_a_member"

  So the pipeline fix and the copy fix are proven independently: neither
  revert can carry the other's assertions.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @ds "test"

  setup do
    ws = create_workspace!()
    project = create_project!(ws)
    {:ok, _file} = create_media_file_in!(ws, project, %{original_name: "in-scope.png"}, @ds)
    {:ok, ws: ws, project: project}
  end

  defp media_path(ws, project), do: "/w/#{ws.slug}/p/#{project.slug}/v1/media/#{@ds}"

  defp interaction_path(ws, project),
    do: "/w/#{ws.slug}/p/#{project.slug}/v1/data/search/#{@ds}/interaction"

  # An ACCOUNT session — `user_session` only, exactly what /login/account and
  # the SSO callback write. Deliberately NOT `api_token`: the whole point of the
  # finding is that no account login ever writes that key.
  defp account_session(conn, memberships) do
    email = "gfr15-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    Enum.each(memberships, fn {ws, role} ->
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    end)

    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  describe "the browser session is a credential on the scoped read" do
    test "a member with an account session reads the scoped media index", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      {_user, conn} = account_session(conn, [{ws, "member"}])

      body =
        conn
        |> get(media_path(ws, project))
        |> json_response(200)

      names = Enum.map(body["result"]["assets"], & &1["originalName"])
      assert "in-scope.png" in names
    end

    test "the same session shape WITHOUT a membership is still refused", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      other = create_workspace!()
      {user, conn} = account_session(conn, [{other, "admin"}])

      refute TenancyAuth.member?(user, ws.id)
      assert conn |> get(media_path(ws, project)) |> json_response(403)
    end

    test "anonymous is still refused — the fail-closed default is unchanged", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      assert conn |> get(media_path(ws, project)) |> json_response(403)
    end
  end

  describe "the membership refusal names membership, not a permission tier" do
    test "403 body says membership and keeps its status", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      raw = conn |> get(media_path(ws, project))
      assert raw.status == 403

      %{"error" => error} = json_response(raw, 403)

      # The stable machine key is unchanged — clients keying on `code` are not
      # broken by making the prose honest.
      assert error["code"] == "forbidden"
      assert error["reason"] == "not_a_member"

      # The lie: this gate never consulted a permission tier.
      refute error["message"] =~ "permission"
      assert error["message"] =~ "member"
      assert error["hint"] =~ "MEMBERSHIP"
      refute error["hint"] =~ "write/admin permission"
    end
  end

  describe "CSRF posture on the pipeline's state-changing routes" do
    test "a cookie-only POST WITHOUT x-requested-with is not authenticated", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      {_user, conn} = account_session(conn, [{ws, "member"}])

      # No custom header → the session is never read → the request is exactly
      # as anonymous as a forged cross-site form submit, and dies at the
      # membership gate.
      assert conn
             |> post(interaction_path(ws, project), %{"query" => "q", "action" => "click"})
             |> json_response(403)
    end

    test "the same POST WITH x-requested-with is authenticated as the member", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      {_user, conn} = account_session(conn, [{ws, "member"}])

      resp =
        conn
        |> put_req_header("x-requested-with", "XMLHttpRequest")
        |> post(interaction_path(ws, project), %{"query" => "q", "action" => "click"})

      # The assertion is about the PIPELINE, not the recorder: whatever the
      # controller decides, the membership gate must no longer be what answers.
      refute resp.status == 403
    end
  end
end
