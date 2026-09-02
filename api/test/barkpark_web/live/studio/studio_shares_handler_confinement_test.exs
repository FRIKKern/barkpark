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

  ## The divergence declared here is CLOSED (task-9e9b49d5787a90be)

  This section used to read "The one divergence that SURVIVES, declared":
  `create/2` answers 422 for a scope naming a workspace that does not exist
  (THE GHOST SHARE), and this door still ALLOWED it — deferred because closing
  it reds two `studio_live_shares_test.exs` happy paths spelled on
  `gyldendal/default/production`, a slug with no workspace row.

  The lead-security ruling of 2026-09-02 settled that trade the other way: "the
  Studio shares handler must REFUSE a declare or remove whose scope names a
  workspace that does not exist, with the SAME generic denial a foreign scope
  gets", because a ghost share is an AUTHORISATION ATTACHED TO A NAME and
  whoever later registers that slug inherits a public exposure they never made.
  Those happy-path fixtures moved onto a workspace that EXISTS, and the third
  test below now pins the REFUSAL — with the foreign-scope sentence, so this
  surface is not an existence oracle.
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

    # THE DECLARED DIVERGENCE, NOW FLIPPED — THIS TEST IS THE RECORD OF ITS
    # CLOSURE, NOT OF THE HOLE.
    #
    # Its previous spelling was titled "STILL OPEN (recorded)" and asserted the
    # OPPOSITE — `assert Sharing.shared?(ghost, ...)` — with the note "a later
    # fix has to come back and delete this test rather than silently leaving it
    # green". This IS that fix coming back, and the assertion is inverted rather
    # than deleted so the flip stays legible in one place.
    #
    # THE RULING (lead-security, 2026-09-02, task-9e9b49d5787a90be): "the Studio
    # shares handler must REFUSE a declare or remove whose scope names a
    # workspace that does not exist, with the SAME generic denial a foreign
    # scope gets". A ghost share is an AUTHORISATION ATTACHED TO A NAME:
    # whoever later registers that slug inherits a public exposure they never
    # made. Legitimate pre-provisioning is the operator env registry
    # (`BARKPARK_SHARES` / `Sharing.shares_env/0`), not this panel.
    test "a scope naming NO workspace at all is refused, with the foreign-scope sentence", %{
      conn: conn,
      raw: raw
    } do
      ghost = "shares-edge-ghost-#{System.unique_integer([:positive])}"
      assert is_nil(Barkpark.Tenancy.get_workspace_by_slug(ghost))

      {:ok, view, _html} = instance_admin_view(conn, raw)

      # The panel must be OPEN for the denial sentence to be rendered at all —
      # `shares_error` lives inside the modal.
      assert render_hook(view, "shares-open", %{}) =~ "Network shares"

      html =
        render_hook(view, "shares-add", %{
          "scope" => "#{ghost}/default/#{@dataset}",
          "surfaces" => ["papers"]
        })

      # THE ROW, not the flash — a "denial" that still wrote the row would be
      # the same pre-planted exposure in disguise.
      refute Sharing.shared?(ghost, "default", @dataset, :papers),
             "the panel pre-declared a public share on a slug nobody has registered yet"

      assert stored_rows_for(ghost) == [],
             "a StoredShare row survived the ghost denial"

      # ...and it is the SAME sentence a foreign-but-real workspace gets (the
      # first test in this describe). NO EXISTENCE ORACLE: a caller cannot
      # walk slugs here to learn which workspaces are taken.
      assert html =~ "not an admin of that scope&#39;s workspace"
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

      remaining = stored_rows_for(ws_b.slug)

      assert match?([_still_there], remaining),
             "the victim's StoredShare row was deleted despite the denial — " <>
               "stored rows for #{ws_b.slug}: #{inspect(remaining)}"

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
