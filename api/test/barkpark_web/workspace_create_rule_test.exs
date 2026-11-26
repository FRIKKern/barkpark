defmodule BarkparkWeb.WorkspaceCreateRuleTest do
  @moduledoc """
  task-f4fde845d0c33bcf: one rule for who may create a workspace
  (`Tenancy.Auth.may_create_workspace?/2`), asked by REST
  `POST /api/workspaces` and by the Studio chrome's `create-workspace`
  fallback (Media, the desk), as Studio's `Caps` asks it: a write seat in the
  workspace the caller acts from. On main REST asked only the token's
  permissions (the mount write gate), never a seat, and so did the chrome.
  A workspace-less signup token still creates its first workspace with `write`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Repo, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @ds "production"

  setup do
    ws = create_workspace!("wcr-#{System.unique_integer([:positive])}")
    {:ok, proj} = Tenancy.create_project_with_dataset(ws, %{name: "wcr-p"})
    %{ws: ws, proj: proj}
  end

  defp token!(ws, perms) do
    raw = "wcr-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "wcr", @ds, perms, ws && ws.id)
    {raw, token}
  end

  defp user!(seats) do
    email = "wcr-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    for {ws, role} <- seats,
        do: {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")

    user
  end

  defp own!(token, user),
    do: token |> Ecto.Changeset.change(owner_user_id: user.id) |> Repo.update!()

  defp unseat!(principal, ws), do: Repo.delete!(TenancyAuth.membership(principal, ws.id))

  defp name, do: "wcr-new-#{System.unique_integer([:positive])}"
  defp exists?(name), do: Enum.any?(Tenancy.list_workspaces(), &(&1.name == name))

  defp post_ws(conn, raw, name),
    do:
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> post("/api/workspaces", %{"name" => name})

  describe "REST POST /api/workspaces" do
    # Green on main too: the `:require_token` mount write gate already refuses
    # a read token on this route (task-a85afbbc0c4b1be3,
    # require_token_write_gate_test.exs). Kept so the rule and the gate agree.
    test "control: a read-only token seated in its home workspace is refused 403", %{
      conn: conn,
      ws: ws
    } do
      {raw, _} = token!(ws, ["read"])
      n = name()

      assert post_ws(conn, raw, n).status == 403
      refute exists?(n)
    end

    test "a write token whose home seat was removed is refused 403", %{conn: conn, ws: ws} do
      {raw, token} = token!(ws, ["read", "write"])
      unseat!(token, ws)
      n = name()

      assert post_ws(conn, raw, n).status == 403
      refute exists?(n)
    end

    test "a user-owned write token whose owner lost the seat is refused 403", %{
      conn: conn,
      ws: ws
    } do
      user = user!([{ws, "member"}])
      {raw, token} = token!(ws, ["read", "write"])
      own!(token, user)
      unseat!(user, ws)
      n = name()

      assert post_ws(conn, raw, n).status == 403
      refute exists?(n)
    end

    test "control: a seated write token, and its seated owner, create (201)", %{
      conn: conn,
      ws: ws
    } do
      {raw, _} = token!(ws, ["read", "write"])
      n = name()
      assert post_ws(conn, raw, n).status == 201
      assert exists?(n)

      {raw, token} = token!(ws, ["read", "write"])
      own!(token, user!([{ws, "member"}]))
      n = name()
      assert post_ws(build_conn(), raw, n).status == 201
      assert exists?(n)
    end

    test "control: a workspace-less signup token with write creates its first workspace", %{
      conn: conn
    } do
      {raw, token} = token!(nil, ["read", "write"])
      own!(token, user!([]))
      n = name()

      assert post_ws(conn, raw, n).status == 201
      assert exists?(n)

      {raw, token} = token!(nil, ["read"])
      own!(token, user!([]))
      assert post_ws(build_conn(), raw, name()).status == 403
    end
  end

  describe "the chrome's create-workspace fallback (Media)" do
    defp media(conn, session, ws, proj) do
      {:ok, view, _html} =
        conn
        |> Plug.Test.init_test_session(session)
        |> live("/w/#{ws.slug}/p/#{proj.slug}/d/#{@ds}/studio/media")

      view
    end

    test "a write token whose seat is removed mid-session creates nothing", c do
      {raw, token} = token!(c.ws, ["read", "write"])
      view = media(c.conn, %{"api_token" => raw}, c.ws, c.proj)
      unseat!(token, c.ws)
      n = name()

      html = render_submit(view, "create-workspace", %{"name" => n})

      assert html =~ "You need write access in this workspace to create a workspace"
      refute exists?(n)
    end

    test "a user-owned token whose owner loses the seat mid-session creates nothing", c do
      user = user!([{c.ws, "member"}])
      {raw, token} = token!(c.ws, ["read", "write"])
      own!(token, user)
      view = media(c.conn, %{"api_token" => raw}, c.ws, c.proj)
      unseat!(user, c.ws)
      n = name()

      _ = render_submit(view, "create-workspace", %{"name" => n})
      refute exists?(n)
    end

    test "an account whose seat is removed, or whose role is unknown, creates nothing", c do
      for change <- [:unseat, :unknown_role] do
        user = user!([{c.ws, "member"}])
        {:ok, raw} = Accounts.create_user_session_token(user)
        view = media(build_conn(), %{"user_session" => raw}, c.ws, c.proj)

        case change do
          :unseat ->
            unseat!(user, c.ws)

          :unknown_role ->
            TenancyAuth.membership(user, c.ws.id)
            |> Ecto.Changeset.change(role: "no-such-role")
            |> Repo.update!()
        end

        n = name()
        html = render_submit(view, "create-workspace", %{"name" => n})

        assert html =~ "You need write access in this workspace to create a workspace",
               "#{change}"

        refute exists?(n), "#{change}"
      end
    end

    test "control: a seated write token and a seated account create", c do
      {raw, _} = token!(c.ws, ["read", "write"])
      n = name()

      assert {:error, {:live_redirect, _}} =
               render_submit(
                 media(c.conn, %{"api_token" => raw}, c.ws, c.proj),
                 "create-workspace",
                 %{"name" => n}
               )

      assert exists?(n)

      {:ok, raw} = Accounts.create_user_session_token(user!([{c.ws, "member"}]))
      n = name()
      view = media(build_conn(), %{"user_session" => raw}, c.ws, c.proj)

      assert {:error, {:live_redirect, _}} =
               render_submit(view, "create-workspace", %{"name" => n})

      assert exists?(n)
    end
  end
end
