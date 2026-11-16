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
  alias Barkpark.Auth
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

  test "a member and an owner of another workspace are sent away", ctx do
    put!(ctx.ws_a, "<p>secret</p>", minutes_ago(1))

    member = user!([{ctx.ws_a, "member"}])
    owner_of_b = user!([{ctx.ws_b, "owner"}])

    assert {:error, {:redirect, %{to: "/studio"}}} = live(user_conn(member), ctx.path_a)
    # Not a member of A at all: ResolveWorkspace refuses before the LiveView.
    assert get(user_conn(owner_of_b), ctx.path_a).status == 403
  end

  test "the flat mount reads nothing, even with ?workspace_slug= in the query" do
    {default_ws, _} = TenancyFixtures.ensure_default_scope!()
    {:ok, row} = put!(default_ws, "<p>default</p>", minutes_ago(2))

    # Instance-wide admin permission, but only a member seat in Default: it
    # passes the flat `:admin` gate and is refused on the scoped page.
    {raw, tok} = token!(["read", "write", "admin"], nil)
    {:ok, _} = TenancyAuth.create_membership(default_ws.id, tok.id, "member")
    default_owner = user!([{default_ws, "owner"}])

    for {label, conn} <- [
          {"admin-permission token, member of Default", token_session_conn(raw, tok)},
          {"owner of Default", user_conn(default_owner)}
        ],
        path <- ["/studio/ecosystem-panel", "/studio/ecosystem-panel?workspace_slug=x"] do
      dead = get(conn, path)
      refute dead.resp_body =~ row.sha256, "#{label} #{path}: dead render carried the sha"

      refute dead.resp_body =~ "Built 2 minutes ago",
             "#{label} #{path}: dead render carried the age"

      result = live(conn, path)

      assert match?({:error, {:redirect, %{to: "/studio"}}}, result),
             "#{label} #{path}: the flat mount did not redirect: #{inspect(result)}"
    end
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

  defp token!(permissions, workspace_id) do
    raw = "eco-shell-#{System.unique_integer([:positive])}"
    {:ok, tok} = Auth.create_token(raw, "eco shell test", "production", permissions, workspace_id)
    {raw, tok}
  end

  defp token_session_conn(raw, tok) do
    {:ok, session_id} = Auth.create_token_session(raw, tok)
    Plug.Test.init_test_session(scoped_conn(), %{"api_token_session" => session_id})
  end

  defp user_conn(user) do
    {:ok, raw} = Accounts.create_user_session_token(user)
    Plug.Test.init_test_session(scoped_conn(), %{"user_session" => raw})
  end
end
