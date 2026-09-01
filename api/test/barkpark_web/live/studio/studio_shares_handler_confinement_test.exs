defmodule BarkparkWeb.Studio.StudioSharesHandlerConfinementTest do
  @moduledoc """
  `task-14dce90fc23a4fdc` — the StudioLive shares handler is the SECOND WRITE
  PATH onto the share registry, and it was wider than the first.

  `ShareController.create/2` / `delete/2` run `Tenancy.Auth.workspace_admin?/2`
  against the workspace the SCOPE names, in the order grammar -> resolve ->
  authorize -> write, BEFORE `Sharing.add_share/1` / `remove_share/3` touch the
  store (arpss-w8 slice 2, PR #12701). `Handlers.Shares.shares_add/2` and
  `shares_remove/2` call those same context functions DIRECTLY, gated only by
  `Caps.admin?/1` (the MOUNTED workspace's seat) plus
  `Shared.declarable_scope?/2`, whose foreign arm is `instance_declare_authority?`
  — the token's GLOBAL `admin` permission and nothing else.

  ## The attacker shape, and why it is the only one that certifies anything

  A total stranger to workspace B is denied by both the old and the new
  predicate and would prove nothing. The shape the predicate CHOICE turns on is
  the same one `share_controller.ex` and this panel's own item-share revoke
  confinement are written against: a token that

    * holds the global `admin` permission (so `instance_declare_authority?`
      admits it, and `:require_admin` would admit it at the HTTP door), and
    * is a seat admin of its OWN mounted workspace (so `Caps.admin?/1` passes
      and the denial cannot come from the handler's admin gate), and
    * holds a REAL but plain `member` membership in B — so
      `Tenancy.Auth.authorize/3` says `:ok` in B while
      `Tenancy.Auth.workspace_admin?/2` denies.

  Those three are asserted in `setup` so the predicate choice is provably
  load-bearing: swap the new gate for `authorize/3` and the two leak tests go
  green on a leaking handler.

  ## What is asserted

  THE ROW, never the flash. `Sharing.shared?/4` (the live merged answer that
  `RequireShareScope` serves every anonymous read) plus the `StoredShare` row
  itself — a "denial" that still wrote or still deleted a row is the same
  cross-tenant write in disguise.

  Each leak test drives the SAME socket to a successful OWN-workspace write
  afterwards, so a blanket deny cannot pass this file.

  ## The one divergence that SURVIVES, declared

  `create/2` answers 422 for a scope naming a workspace that does not exist
  (THE GHOST SHARE). This door still allows it — see the third test, which
  pins that fact rather than hiding it, and `target_workspace_admits?/2`'s
  note for why closing it is a separate change with its own blast radius.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Sharing}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup %{conn: conn} do
    {default_ws, default_proj} = ensure_default_scope!()

    raw = "shares-edge-parity-#{System.unique_integer([:positive])}"

    {:ok, token} =
      Auth.create_token(raw, "shares edge parity", @dataset, ~w(read write admin))

    # The VICTIM tenant. Real, resolvable, and foreign to the mounted scope.
    ws_b = create_workspace!("shares-edge-b-#{System.unique_integer([:positive])}")
    _proj_b = create_project!(ws_b, "shares-edge-pb-#{System.unique_integer([:positive])}")

    # A REAL but plain `member` row in B — the shape the predicate turns on.
    {:ok, _} = TenancyAuth.create_membership(ws_b.id, token.id, "member", "api_token")

    # Preconditions, asserted inline. Without these the fixture could be a
    # stranger to B and the leak test would pass for the wrong reason.
    assert TenancyAuth.membership_role(token, ws_b.id) == "member"
    assert TenancyAuth.authorize(token, ws_b.id, :admin) == :ok
    refute TenancyAuth.workspace_admin?(token, ws_b.id)
    # ...and it IS a seat admin at home, so `Caps.admin?/1` cannot be the denier.
    assert TenancyAuth.workspace_admin?(token, default_ws.id)

    prior_shares = Application.get_env(:barkpark, :shares)
    prior_env = Application.get_env(:barkpark, :shares_env)
    Application.put_env(:barkpark, :shares, [])
    Application.put_env(:barkpark, :shares_env, [])

    on_exit(fn ->
      restore(:shares, prior_shares)
      restore(:shares_env, prior_env)
    end)

    {:ok,
     conn: conn,
     raw: raw,
     token: token,
     ws_b: ws_b,
     default_ws: default_ws,
     default_proj: default_proj}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp instance_admin_view(conn, raw) do
    conn
    |> Plug.Test.init_test_session(%{"api_token" => raw})
    |> live(scoped_studio("/d/#{@dataset}/studio"))
  end

  defp stored_rows_for(ws_slug) do
    Enum.filter(Sharing.list_stored(), &(&1.workspace_slug == ws_slug))
  end

  describe "shares-add — the FORGE, at the LiveView door" do
    test "a global-admin token that is only a MEMBER of B cannot declare B's share", %{
      conn: conn,
      raw: raw,
      ws_b: ws_b,
      default_ws: default_ws,
      default_proj: default_proj
    } do
      {:ok, view, _html} = instance_admin_view(conn, raw)

      render_hook(view, "shares-add", %{
        "scope" => "#{ws_b.slug}/default/#{@dataset}",
        "surfaces" => ["papers"]
      })

      # THE ROW, not the flash.
      refute Sharing.shared?(ws_b.slug, "default", @dataset, :papers),
             "the Studio panel declared a public share over #{ws_b.slug}, " <>
               "which POST /v1/shares answers 403 for"

      assert stored_rows_for(ws_b.slug) == [],
             "a StoredShare row survived the denial"

      # POSITIVE CONTROL, SAME SOCKET: the feature still works at home.
      render_hook(view, "shares-add", %{
        "scope" => "#{default_ws.slug}/#{default_proj.slug}/#{@dataset}",
        "surfaces" => ["papers"]
      })

      assert Sharing.shared?(default_ws.slug, default_proj.slug, @dataset, :papers),
             "the confinement broke the panel's own workspace share"
    end

    # THE ONE DECLARED DIVERGENCE, PINNED SO IT CANNOT BE MISREAD AS PARITY.
    #
    # `create/2` answers 422 for a scope naming a workspace that does not exist
    # (THE GHOST SHARE). This door still allows it, because closing it reds two
    # `studio_live_shares_test.exs` cases that declare and revoke
    # `gyldendal/default/production` — a slug with no workspace row — as the
    # panel's own happy path, and that behaviour change is outside this row's
    # obligation ("workspace B", a workspace that EXISTS). Recorded here as a
    # finding, filed as a follow-up, and asserted so a later fix has to come
    # back and delete this test rather than silently leaving it green.
    test "STILL OPEN (recorded): a scope naming no workspace at all is NOT refused here", %{
      conn: conn,
      raw: raw
    } do
      ghost = "shares-edge-ghost-#{System.unique_integer([:positive])}"
      assert is_nil(Barkpark.Tenancy.get_workspace_by_slug(ghost))

      {:ok, view, _html} = instance_admin_view(conn, raw)

      render_hook(view, "shares-add", %{
        "scope" => "#{ghost}/default/#{@dataset}",
        "surfaces" => ["papers"]
      })

      assert Sharing.shared?(ghost, "default", @dataset, :papers),
             "the ghost-share divergence is CLOSED — delete this test and the " <>
               "note in `target_workspace_admits?/2`, they are now stale"
    end
  end

  describe "shares-remove — the DoS, at the LiveView door" do
    test "a global-admin token that is only a MEMBER of B cannot revoke B's share", %{
      conn: conn,
      raw: raw,
      ws_b: ws_b,
      default_ws: default_ws,
      default_proj: default_proj
    } do
      # Stand the victim share up as an instance operator would.
      {:ok, _} = Sharing.add_share("#{ws_b.slug}/default/#{@dataset}:papers:read")
      assert Sharing.shared?(ws_b.slug, "default", @dataset, :papers)
      assert [_victim] = stored_rows_for(ws_b.slug)

      {:ok, view, _html} = instance_admin_view(conn, raw)

      render_hook(view, "shares-remove", %{"scope" => "#{ws_b.slug}/default/#{@dataset}"})

      assert Sharing.shared?(ws_b.slug, "default", @dataset, :papers),
             "the Studio panel revoked #{ws_b.slug}'s share, " <>
               "which DELETE /v1/shares answers 403 for"

      assert [_still_there] = stored_rows_for(ws_b.slug),
             "the victim's StoredShare row was deleted despite the denial"

      # POSITIVE CONTROL, SAME SOCKET: removal still works at home.
      {:ok, _} =
        Sharing.add_share("#{default_ws.slug}/#{default_proj.slug}/#{@dataset}:papers:read")

      assert Sharing.shared?(default_ws.slug, default_proj.slug, @dataset, :papers)

      render_hook(view, "shares-remove", %{
        "scope" => "#{default_ws.slug}/#{default_proj.slug}/#{@dataset}"
      })

      refute Sharing.shared?(default_ws.slug, default_proj.slug, @dataset, :papers),
             "the confinement broke the panel's own workspace un-share"
    end
  end
end
