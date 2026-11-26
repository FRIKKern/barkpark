defmodule BarkparkWeb.WorkspaceCreateSuspendedHomeTest do
  @moduledoc """
  task-3e88aa09df6a3b81: a token whose home workspace A is suspended, seated
  in an unsuspended B. REST asks about the token's home and refused it (#28999),
  but Studio and the chrome asked only about the mounted workspace, so the same
  token created a workspace from a socket on B.

  Ruling (coordinator, 2026-11-26): suspension is the hard stop, so a create
  is refused when the mounted workspace OR the token's home is suspended
  (`StudioChrome.suspended_create?/2`). An account has no single home: a
  suspension of another workspace it is a member of does not stop it creating
  from B.
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
    a = create_workspace!("wsh-a-#{System.unique_integer([:positive])}")
    b = create_workspace!("wsh-b-#{System.unique_integer([:positive])}")
    {:ok, proj} = Tenancy.create_project_with_dataset(b, %{name: "wsh-p"})
    %{a: a, b: b, proj: proj}
  end

  # A token minted in A with a writing seat in B.
  defp token_session!(c) do
    raw = "wsh-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "wsh", @ds, ["read", "write"], c.a.id)
    {:ok, _} = TenancyAuth.create_membership(c.b.id, token.id, "member", "api_token")
    %{"api_token" => raw}
  end

  # An account that is a member of A and of B.
  defp account_session!(c) do
    email = "wsh-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    for ws <- [c.a, c.b],
        do: {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")

    {:ok, raw} = Accounts.create_user_session_token(user)
    %{"user_session" => raw}
  end

  defp suspend!(ws), do: {:ok, _} = Quota.suspend(Tenancy.get_workspace_by_id(ws.id), "wsh")
  defp name, do: "wsh-new-#{System.unique_integer([:positive])}"
  defp exists?(name), do: Enum.any?(Tenancy.list_workspaces(), &(&1.name == name))

  defp view(session, c, suffix) do
    {:ok, view, _html} =
      scoped_conn()
      |> Plug.Test.init_test_session(session)
      |> live("/w/#{c.b.slug}/p/#{c.proj.slug}/d/#{@ds}/studio" <> suffix)

    view
  end

  for {label, suffix} <- [{"Studio", ""}, {"the chrome (Media)", "/media"}] do
    test "#{label}: a token whose home is suspended is refused on a socket mounted on B", c do
      v = view(token_session!(c), c, unquote(suffix))
      suspend!(c.a)
      n = name()

      html = render_submit(v, "create-workspace", %{"name" => n})

      assert html =~ @refusal
      refute exists?(n)
    end

    test "#{label} control: the same token, home not suspended, creates from B", c do
      v = view(token_session!(c), c, unquote(suffix))
      n = name()

      _ = render_submit(v, "create-workspace", %{"name" => n})

      assert exists?(n)
    end

    test "#{label} control: an account with a suspended A still creates from B", c do
      v = view(account_session!(c), c, unquote(suffix))
      suspend!(c.a)
      n = name()

      _ = render_submit(v, "create-workspace", %{"name" => n})

      assert exists?(n)
    end
  end
end
