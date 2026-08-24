defmodule BarkparkWeb.Studio.StudioLiveSharesScopeTenancyTest do
  @moduledoc """
  `arpss-w10-bl-shares-add-instance-wide-scope-hole`.

  `Handlers.Shares.shares_add/2` gates on `Caps.admin?/1` — admin of the
  MOUNTED workspace — and then hands `params["scope"]` to
  `Barkpark.Sharing.add_share/1` without ever comparing that scope's workspace
  against the mounted one. `Sharing.parse_scope/1` accepts any slug, so an
  admin of workspace A could declare a public read share over workspace B.

  ## Why the SESSION arm is the whole test

  The escalation exists ONLY for an account principal. `Caps.admin?/1`'s token
  arm requires `token_admin?/1` — the same `admin` permission that
  `/v1/shares`'s `:require_admin` pipeline requires — so a token principal
  already holds instance-wide declare authority by design, and the LiveView
  path is in fact STRICTER (it also demands a membership). An account admin of
  one workspace holds no such authority: `POST /v1/shares` refuses them.

  A token fixture here would certify nothing, exactly as
  `studio_account_session_scope_test.exs` records for its own defect.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Sharing, Tenancy}

  @dataset "production"

  setup %{conn: conn} do
    ws_a = create_workspace!("arpss-shares-a-#{System.unique_integer([:positive])}")
    proj_a = create_project!(ws_a, "arpss-shares-pa-#{System.unique_integer([:positive])}")
    ws_b = create_workspace!("arpss-shares-b-#{System.unique_integer([:positive])}")
    _proj_b = create_project!(ws_b, "arpss-shares-pb-#{System.unique_integer([:positive])}")

    {default_ws, _default_proj} = ensure_default_scope!()

    prior_shares = Application.get_env(:barkpark, :shares)
    prior_env = Application.get_env(:barkpark, :shares_env)
    Application.put_env(:barkpark, :shares, [])
    Application.put_env(:barkpark, :shares_env, [])

    on_exit(fn ->
      restore(:shares, prior_shares)
      restore(:shares_env, prior_env)
    end)

    {:ok, conn: conn, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, default_ws: default_ws}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp account_admin_session!(conn, ws, role) do
    email = "arpss-shares-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  defp mount_on(conn, ws, proj) do
    live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio")
  end

  describe "an account admin of ONE workspace" do
    test "cannot declare a share over a DIFFERENT workspace", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      {_user, conn} = account_admin_session!(conn, ws_a, "admin")
      {:ok, view, _html} = mount_on(conn, ws_a, proj_a)

      render_hook(view, "shares-add", %{
        "scope" => "#{ws_b.slug}/default/#{@dataset}",
        "surfaces" => ["papers"]
      })

      refute Sharing.shared?(ws_b.slug, "default", @dataset, :papers),
             "an admin of #{ws_a.slug} declared a public share over #{ws_b.slug}"
    end

    test "cannot REVOKE a share over a DIFFERENT workspace (the availability mirror)", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      # Stand the victim share up directly, as an instance operator would.
      {:ok, _} = Sharing.add_share("#{ws_b.slug}/default/#{@dataset}:papers:read")
      assert Sharing.shared?(ws_b.slug, "default", @dataset, :papers)

      {_user, conn} = account_admin_session!(conn, ws_a, "admin")
      {:ok, view, _html} = mount_on(conn, ws_a, proj_a)

      render_hook(view, "shares-remove", %{"scope" => "#{ws_b.slug}/default/#{@dataset}"})

      assert Sharing.shared?(ws_b.slug, "default", @dataset, :papers),
             "an admin of #{ws_a.slug} revoked #{ws_b.slug}'s share"
    end

    test "CAN still declare a share over its OWN workspace (the guard is not a blanket deny)",
         %{conn: conn, ws_a: ws_a, proj_a: proj_a} do
      {_user, conn} = account_admin_session!(conn, ws_a, "admin")
      {:ok, view, _html} = mount_on(conn, ws_a, proj_a)

      render_hook(view, "shares-add", %{
        "scope" => "#{ws_a.slug}/#{proj_a.slug}/#{@dataset}",
        "surfaces" => ["papers"]
      })

      assert Sharing.shared?(ws_a.slug, proj_a.slug, @dataset, :papers)
    end
  end

  # ─── THE LIST HALF (task-c91e5e19da811fe5) ──────────────────────────────────
  #
  # The two tests above are the WRITE halves, and `shares_remove/2`'s own comment
  # calls its clamp "the availability mirror of the DISCLOSURE hole". The
  # disclosure direction it names was never closed: `load_share_rows/0` took no
  # scope argument at all, so `shares_open/2` — gated only on `Caps.admin?/1`,
  # i.e. admin of the MOUNTED workspace — assigned the whole instance's share
  # inventory: every workspace/project/dataset publicly shared, plus each one's
  # anonymous `:papers` reader URL.
  #
  # `load_item_links/2`, in the SAME module, was already workspace-scoped
  # (`Links.list_for(ws_id, ...)`). Same file, same panel, opposite treatment.

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp seed_shares!(ws_a, proj_a, ws_b) do
    {:ok, _} = Sharing.add_share("#{ws_b.slug}/default/#{@dataset}:papers:read")
    {:ok, _} = Sharing.add_share("#{ws_a.slug}/#{proj_a.slug}/#{@dataset}:papers:read")
    :ok
  end

  describe "the LIST half — the disclosure direction" do
    test "an account admin of ONE workspace does not SEE another workspace's shares", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      seed_shares!(ws_a, proj_a, ws_b)

      {_user, conn} = account_admin_session!(conn, ws_a, "admin")
      {:ok, view, _html} = mount_on(conn, ws_a, proj_a)

      html = render_hook(view, "shares-open", %{})

      refute html =~ ws_b.slug,
             "an admin of #{ws_a.slug} was shown #{ws_b.slug}'s share inventory"

      # OVER-CLAMP CONTROL, same render: the panel is not simply empty.
      assert html =~ "#{ws_a.slug}/#{proj_a.slug}/#{@dataset}",
             "the clamp hid the caller's OWN share"
    end

    # A SECOND DOOR onto the same assign: `?shares=open` opens the panel during
    # mount via `Shared.maybe_open_shares/2`, which called the same unscoped
    # `load_share_rows/0`. Fixing `shares_open/2` alone would leave this one.
    test "the ?shares=open mount door is clamped too", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      seed_shares!(ws_a, proj_a, ws_b)

      {_user, conn} = account_admin_session!(conn, ws_a, "admin")

      {:ok, _view, html} =
        live(conn, "/w/#{ws_a.slug}/p/#{proj_a.slug}/d/#{@dataset}/studio?shares=open")

      refute html =~ ws_b.slug,
             "the ?shares=open mount door served #{ws_b.slug}'s inventory"

      assert html =~ "#{ws_a.slug}/#{proj_a.slug}/#{@dataset}"
    end

    # A THIRD DOOR: both mutate handlers refresh `shares_rows` from the same
    # function after writing.
    test "the refresh after shares-add is clamped too", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      seed_shares!(ws_a, proj_a, ws_b)

      {_user, conn} = account_admin_session!(conn, ws_a, "admin")
      {:ok, view, _html} = mount_on(conn, ws_a, proj_a)
      render_hook(view, "shares-open", %{})

      html =
        render_hook(view, "shares-add", %{
          "scope" => "#{ws_a.slug}/#{proj_a.slug}/#{@dataset}",
          "surfaces" => ["papers", "docs"]
        })

      refute html =~ ws_b.slug,
             "the post-add refresh re-served #{ws_b.slug}'s inventory"
    end

    # EXISTENCE, not just bodies. The row COUNT derives from the same list, so a
    # clamped render over an unclamped list would still reveal how many shares
    # exist elsewhere. Asserted on the data, where a count would be computed —
    # the template renders no total today, and this pins that it cannot start
    # leaking one from an unclamped source. Also pins the anonymous reader URL,
    # which is the part of a row that is an entry point rather than a label.
    test "the assign holds ONLY the mounted workspace's rows", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      seed_shares!(ws_a, proj_a, ws_b)

      {_user, conn} = account_admin_session!(conn, ws_a, "admin")
      {:ok, view, _html} = mount_on(conn, ws_a, proj_a)
      render_hook(view, "shares-open", %{})

      rows = assigns(view).shares_rows

      assert length(rows) == 1, "expected exactly A's one row, got #{inspect(rows)}"
      assert [%{scope: scope}] = rows
      assert scope == "#{ws_a.slug}/#{proj_a.slug}/#{@dataset}"

      refute Enum.any?(rows, &String.contains?(&1.scope, ws_b.slug))

      refute Enum.any?(rows, fn r -> is_binary(r.url) and String.contains?(r.url, ws_b.slug) end),
             "a foreign share's anonymous reader URL survived the clamp"
    end

    # OVER-CLAMP CONTROL, the by-design arm: a token carrying the global `admin`
    # permission is exactly what `/v1/shares` (`:require_admin`) demands, so it
    # holds instance-wide declare authority and MUST still see the whole
    # inventory. Without this arm the cheapest way to pass every test above is
    # to return [].
    test "a token with instance declare authority still sees EVERY workspace's shares", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      default_ws: default_ws
    } do
      seed_shares!(ws_a, proj_a, ws_b)

      raw = "shares-list-instance-" <> Ecto.UUID.generate()

      {:ok, token} =
        Barkpark.Auth.create_token(
          raw,
          "shares-list-instance",
          @dataset,
          ~w(read admin),
          default_ws.id
        )

      {:ok, _} = Tenancy.Auth.create_membership(ws_a.id, token.id, "admin", "api_token")

      conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
      {:ok, view, _html} = mount_on(conn, ws_a, proj_a)

      html = render_hook(view, "shares-open", %{})

      assert html =~ ws_b.slug,
             "instance declare authority was over-clamped out of its own inventory"
    end
  end
end
