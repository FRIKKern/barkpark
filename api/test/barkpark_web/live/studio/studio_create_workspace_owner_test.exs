defmodule BarkparkWeb.Studio.StudioCreateWorkspaceOwnerTest do
  @moduledoc """
  task-d40804433c63ffa4: on a Studio socket carrying both a token and an
  account, `Caps` passes `create-workspace` when either seat writes, and the
  new workspace's owner is the token (`api_token || current_user`). A read
  token behind a writing account owned the workspace it made. Studio now asks
  the owner the rule REST and the chrome ask
  (`Tenancy.Auth.may_create_workspace?/2`), and refuses as the chrome does.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Repo, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @ds "production"
  @refusal "You need write access in this workspace to create a workspace"

  setup do
    ws = create_workspace!("scwo-#{System.unique_integer([:positive])}")
    {:ok, proj} = Tenancy.create_project_with_dataset(ws, %{name: "scwo-p"})
    %{ws: ws, proj: proj}
  end

  defp token!(ws, perms) do
    raw = "scwo-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "scwo", @ds, perms, ws.id)
    {raw, token}
  end

  defp account!(ws, role) do
    email = "scwo-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    {raw, user}
  end

  defp studio(session, c) do
    {:ok, view, _html} =
      scoped_conn()
      |> Plug.Test.init_test_session(session)
      |> live("/w/#{c.ws.slug}/p/#{c.proj.slug}/d/#{@ds}/studio")

    view
  end

  defp name, do: "scwo-new-#{System.unique_integer([:positive])}"
  defp made(name), do: Enum.find(Tenancy.list_workspaces(), &(&1.name == name))

  # {principal_type, principal_id} of each owner seat of `ws`.
  defp owners(ws) do
    Repo.all(
      from(m in Barkpark.Tenancy.Membership,
        where: m.workspace_id == ^ws.id and m.role == "owner",
        select: {m.principal_type, m.principal_id}
      )
    )
  end

  test "a read token behind a writing account creates nothing, and owns nothing", c do
    {raw, _token} = token!(c.ws, ["read"])
    {session, _user} = account!(c.ws, "member")
    view = studio(%{"api_token" => raw, "user_session" => session}, c)
    before = length(Tenancy.list_workspaces())
    n = name()

    html = render_hook(view, "create-workspace", %{"name" => n})

    assert html =~ @refusal
    refute made(n)
    assert length(Tenancy.list_workspaces()) == before
  end

  # A revoke kicks the socket to /login before any press arrives; a narrowed
  # permission list does not, and `Caps` reads the row as it is now.
  test "a write token narrowed to read mid-session behind a writing account creates nothing",
       c do
    {raw, token} = token!(c.ws, ["read", "write"])
    {session, _user} = account!(c.ws, "member")
    view = studio(%{"api_token" => raw, "user_session" => session}, c)
    token |> Ecto.Changeset.change(permissions: ["read"]) |> Repo.update!()
    n = name()

    html = render_hook(view, "create-workspace", %{"name" => n})

    assert html =~ @refusal
    refute made(n)
  end

  test "control: a write token behind an account creates, owned by the token", c do
    {raw, token} = token!(c.ws, ["read", "write"])
    {session, _user} = account!(c.ws, "member")
    view = studio(%{"api_token" => raw, "user_session" => session}, c)
    n = name()

    _ = render_hook(view, "create-workspace", %{"name" => n})

    assert %{} = ws = made(n)
    assert owners(ws) == [{"api_token", token.id}]
  end

  test "control: a write token alone, and an account alone, each create and own", c do
    {raw, token} = token!(c.ws, ["read", "write"])
    n = name()
    _ = render_hook(studio(%{"api_token" => raw}, c), "create-workspace", %{"name" => n})
    assert owners(made(n)) == [{"api_token", token.id}]

    {session, user} = account!(c.ws, "member")
    n = name()
    _ = render_hook(studio(%{"user_session" => session}, c), "create-workspace", %{"name" => n})
    assert owners(made(n)) == [{"user", user.id}]
  end
end
