defmodule BarkparkWeb.EcosystemPanelLiveTest do
  @moduledoc """
  task-d599e49ba75bb30b — the ecosystem panel shell,
  `/w/:ws/p/:proj/studio/ecosystem-panel`.

  The shell draws the age line from the stored `built_at` outside the frame,
  turns it into "Stale" past 30 minutes, swaps the iframe src when a new
  snapshot is broadcast, and lets only an owner or admin of the URL workspace
  in. A demoted admin loses the page on the next tick.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Accounts
  alias Barkpark.EcosystemPanel
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.TenancyFixtures

  setup do
    ws_a = TenancyFixtures.create_workspace!()
    proj_a = TenancyFixtures.create_project!(ws_a)
    ws_b = TenancyFixtures.create_workspace!()
    proj_b = TenancyFixtures.create_project!(ws_b)

    %{
      ws_a: ws_a,
      ws_b: ws_b,
      path_a: "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/ecosystem-panel",
      path_b: "/w/#{ws_b.slug}/p/#{proj_b.slug}/studio/ecosystem-panel",
      admin_a: user!([{ws_a, "admin"}])
    }
  end

  test "a snapshot built 31 minutes ago shows Stale", ctx do
    put!(ctx.ws_a, "<p>old</p>", minutes_ago(31))

    {:ok, _view, html} = live(user_conn(ctx.admin_a), ctx.path_a)

    assert html =~ "Stale: built 31 minutes ago"
    assert html =~ ~s(data-stale="true")
  end

  test "a snapshot built 12 minutes ago shows its age and no Stale", ctx do
    {:ok, row} = put!(ctx.ws_a, "<p>fresh</p>", minutes_ago(12))

    {:ok, _view, html} = live(user_conn(ctx.admin_a), ctx.path_a)

    assert html =~ "Built 12 minutes ago"
    refute html =~ "Stale"
    assert html =~ ~s(sandbox="allow-scripts")
    assert html =~ "#{ctx.path_a}/frame?v=#{row.sha256}"
  end

  test "a workspace with no row shows No snapshot yet and no frame", ctx do
    {:ok, _view, html} = live(user_conn(ctx.admin_a), ctx.path_a)

    assert html =~ "No snapshot yet"
    refute html =~ "<iframe"
  end

  test "a member, an owner of another workspace and the flat mount are sent away", ctx do
    put!(ctx.ws_a, "<p>secret</p>", minutes_ago(1))
    {default_ws, _} = TenancyFixtures.ensure_default_scope!()

    member = user!([{ctx.ws_a, "member"}])
    owner_of_b = user!([{ctx.ws_b, "owner"}])

    assert {:error, {:redirect, %{to: "/studio"}}} = live(user_conn(member), ctx.path_a)
    # Not a member of A at all: ResolveWorkspace refuses before the LiveView.
    assert get(user_conn(owner_of_b), ctx.path_a).status == 403

    # An owner of the default workspace passes the flat `:admin` gate, so the
    # redirect (with no denial flash) is the shell's own.
    default_owner = user!([{default_ws, "owner"}, {ctx.ws_a, "admin"}])

    assert {:error, {:redirect, %{to: "/studio"} = redirect}} =
             live(user_conn(default_owner), "/studio/ecosystem-panel")

    refute Map.get(redirect, :flash, %{})["error"]
  end

  test "a broadcast with a new sha swaps the iframe src; a demoted admin is sent away", ctx do
    {:ok, first} = put!(ctx.ws_a, "<p>one</p>", minutes_ago(14))
    {:ok, view, html} = live(user_conn(ctx.admin_a), ctx.path_a)
    assert html =~ "frame?v=#{first.sha256}"

    {:ok, second} = put!(ctx.ws_a, "<p>two</p>", minutes_ago(0))
    html = render(view)

    assert html =~ "frame?v=#{second.sha256}"
    refute html =~ first.sha256
    assert html =~ "Built just now"

    ctx.admin_a
    |> TenancyAuth.membership(ctx.ws_a.id)
    |> Ecto.Changeset.change(role: "member")
    |> Repo.update!()

    send(view.pid, :tick)
    assert_redirect(view, "/studio")
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp put!(ws, html, built_at), do: EcosystemPanel.put(ws.id, html, built_at)

  defp minutes_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 60 - 5, :second)

  defp user!(memberships) do
    email = "eco-shell-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    for {ws, role} <- memberships do
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    end

    user
  end

  defp user_conn(user) do
    {:ok, raw} = Accounts.create_user_session_token(user)
    Plug.Test.init_test_session(scoped_conn(), %{"user_session" => raw})
  end
end
