defmodule BarkparkWeb.WorkspaceCreateSuspendedTest do
  @moduledoc """
  task-ca975477b8ca8a67: a suspended workspace creates no other workspace.
  Suspension is the operator's hard stop on a tenant. A fresh, unsuspended
  workspace made by the suspended tenant's own token or account stepped round
  it, on REST (201), in Studio and in the chrome fallback.

  The rule is asked of the workspace the create acts from: REST uses the
  token's home, and Studio and the chrome use the mounted workspace. It is read
  from the row at the press (`Quota.suspended?/1`), so these tests suspend
  after mount. A token with no home (a signup PAT) has nothing to be suspended.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Quota

  @ds "production"
  @refusal "This workspace is suspended, so no workspace can be created from it"

  setup do
    ws = create_workspace!("wcs-#{System.unique_integer([:positive])}")
    {:ok, proj} = Tenancy.create_project_with_dataset(ws, %{name: "wcs-p"})
    %{ws: ws, proj: proj}
  end

  defp token!(ws_id) do
    raw = "wcs-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "wcs", @ds, ["read", "write"], ws_id)
    {raw, token}
  end

  defp account!(ws) do
    email = "wcs-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    raw
  end

  defp suspend!(ws), do: {:ok, _} = Quota.suspend(Tenancy.get_workspace_by_id(ws.id), "wcs")
  defp reinstate!(ws), do: {:ok, _} = Quota.reinstate(Tenancy.get_workspace_by_id(ws.id))

  defp name, do: "wcs-new-#{System.unique_integer([:positive])}"
  defp exists?(name), do: Enum.any?(Tenancy.list_workspaces(), &(&1.name == name))

  defp post_ws(raw, name),
    do:
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> raw)
      |> post("/api/workspaces", %{"name" => name})

  defp session(:token, ws), do: %{"api_token" => elem(token!(ws.id), 0)}
  defp session(:account, ws), do: %{"user_session" => account!(ws)}

  defp view(session, c, suffix) do
    {:ok, view, _html} =
      scoped_conn()
      |> Plug.Test.init_test_session(session)
      |> live("/w/#{c.ws.slug}/p/#{c.proj.slug}/d/#{@ds}/studio" <> suffix)

    view
  end

  describe "REST POST /api/workspaces" do
    test "a token whose home is suspended is refused 403 workspace_suspended", c do
      {raw, _} = token!(c.ws.id)
      suspend!(c.ws)
      n = name()

      conn = post_ws(raw, n)

      assert conn.status == 403
      assert %{"error" => %{"code" => "workspace_suspended"}} = Jason.decode!(conn.resp_body)
      refute exists?(n)
    end

    test "the refusal names the operator's reason in details.reason (task-b52ef8bc59eb1060)",
         c do
      {raw, _} = token!(c.ws.id)
      suspend!(c.ws)

      conn = post_ws(raw, name())

      assert %{"error" => %{"code" => "workspace_suspended", "details" => %{"reason" => "wcs"}}} =
               Jason.decode!(conn.resp_body)
    end

    test "control: reinstated, the same token creates; a signup PAT with no home creates", c do
      {raw, _} = token!(c.ws.id)
      suspend!(c.ws)
      reinstate!(c.ws)
      n = name()
      assert post_ws(raw, n).status == 201
      assert exists?(n)

      {raw, token} = token!(nil)

      {:ok, user} =
        Accounts.register_user(%{
          email: "wcs-pat-#{System.unique_integer([:positive])}@example.com",
          password: "correct-horse-battery"
        })

      token |> Ecto.Changeset.change(owner_user_id: user.id) |> Barkpark.Repo.update!()
      n = name()
      assert post_ws(raw, n).status == 201
      assert exists?(n)
    end
  end

  for {label, suffix} <- [{"Studio", ""}, {"the chrome (Media)", "/media"}],
      kind <- [:token, :account] do
    describe "#{label}, #{kind}" do
      test "suspended after mount: the press is refused and nothing is created", c do
        v = view(session(unquote(kind), c.ws), c, unquote(suffix))
        suspend!(c.ws)
        n = name()

        html = render_submit(v, "create-workspace", %{"name" => n})

        assert html =~ @refusal
        refute exists?(n)
      end

      test "control: reinstated, the same press creates", c do
        v = view(session(unquote(kind), c.ws), c, unquote(suffix))
        suspend!(c.ws)
        reinstate!(c.ws)
        n = name()

        _ = render_submit(v, "create-workspace", %{"name" => n})

        assert exists?(n)
      end
    end
  end
end
