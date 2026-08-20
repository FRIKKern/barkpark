defmodule BarkparkWeb.Studio.CapsMountReachabilityTest do
  @moduledoc """
  arpss-w10 — the REACHABILITY ratchet the parity table's BENIGN labels stand on.

  The sibling slice (`arpss-w10-caps-admin-parity-table`) labels several
  decision-layer divergences between `BarkparkWeb.Studio.Caps` and the canonical
  `Barkpark.Tenancy.Auth.authorize/3` BENIGN — not because the two agree on those
  cells, but because the socket shape that exhibits them CANNOT BE MOUNTED. That
  is an argument about routing and mount guards, not about Caps, and nothing in
  the tree held it: the probe that settled it lived in a throwaway worktree and
  is gone, and two surveyors flatly contradicted each other on it. This file is
  that argument, checked in and executable.

  ## The split this file owns (do NOT widen it)

  REACHABILITY only — which principal shapes can obtain a Caps-bearing socket at
  all. The caps DECISION values (`caps.admin`, `caps.write`, …) belong to the
  parity table's suite; asserting them here would red this file the moment the
  sibling fix lands. Shape B below deliberately asserts only fix-INDEPENDENT
  facts. A future editor who "helpfully" adds `assert caps.admin` here is
  breaking the split on purpose — don't.

  ## What is pinned

  1. ROUTE CENSUS (structural). Every `StudioLive` / `ApiTesterLive` route in the
     router lives in exactly ONE `live_session` — `:scoped_studio` — whose
     on_mount list carries `{BarkparkWeb.LiveScope, :resolve}`. Asserted from the
     router's own compiled route metadata AND from the router source, so a fourth
     Caps-bearing route added anywhere reds HERE, in the file whose whole job is
     to notice.

  2. SHAPE A IS UNREACHABLE — the headline. An api_token carrying global
     `["read","write","admin"]` permissions and ZERO membership rows anywhere
     gets HTTP 403, halted, no `Location`, on all FOUR Caps-bearing addresses
     (scoped studio, api-tester, the `/*path` wildcard, and its OWN default
     workspace once the auto-created membership row is deleted). Proven by DEAD
     RENDER — a plain `get/2` — because no LiveView socket is ever built for this
     shape. The FIRST guard is the `:shared_studio_browser` pipeline's
     `BarkparkWeb.Plugs.ResolveWorkspace` (`halt_envelope(conn, {:error,
     :forbidden})`, resolve_workspace.ex:134); `LiveScope.on_mount(:resolve)`
     never runs. The SECOND is `LiveScope.authorize_read/4`'s EXCLUSIVE
     `%ApiToken{}` branch — it returns `err` with no fallthrough to the
     anonymous-default / share / grant arms — pinned structurally below.

     FIXTURE TRAP: `Barkpark.Auth.create_token/5` AUTO-CREATES a membership in
     the token's home workspace. Shape A therefore requires DELETING that row;
     the delete count is asserted, because a builder who skips it silently
     measures shape B and records the opposite result.

  3. SHAPE B IS REACHABLE. A global-admin api_token holding a plain `"member"`
     row in the mounted workspace MOUNTS the scoped studio, and Caps IS attached
     there. This is what makes the parity table's admin cells live rather than
     hypothetical — the "global-admin token with a member row" principal is a
     real, mountable Studio user.

  4. LiveScope RE-AUTHORIZES ON SCOPE CHANGE: a live navigation out of the
     authorized workspace into one the token holds no row in is denied, so a
     mounted socket cannot walk into a foreign tenant.

  5. THE FLAT `/studio/*` CHROME ROUTES CARRY NO CAPS. On `live_session
     :admin_studio` (org-admin, styleguide, …) `StudioChrome.default_scope_fallback/1`
     labels the socket with the seeded Default workspace with NO membership
     check — but `assigns[:caps]` is NIL there, so no deny-gate exists to be
     misled. Phantom chrome label, not an authorization bypass. If Caps is ever
     attached to those routes, this file reds — which is the point. (The
     chrome-side scoping defect itself is out of fence and filed as
     `arpss-w10-bl-studiochrome-admin-default-workspace-scoping`.)

     FINDING — one brief claim REFUTED by run, recorded rather than forced: the
     brief predicted that firing `shares-open` on the flat chrome raises
     `:function_clause` ("no handler exists"). It does not.
     `StudioChrome.chrome_fallback("shares-open", …)` (studio_chrome.ex:176 →
     `nav_to_shares/1`) handles it on every non-StudioLive surface and
     `push_navigate`s to `<scoped studio>?shares=open`. The disposition is
     UNCHANGED and the mechanism is stronger than "absent handler": the shares
     PANEL exists only in StudioLive, so the affordance re-enters
     `live_session :scoped_studio` behind `{LiveScope, :resolve}` — and shape A,
     which CAN mount the flat chrome (it holds global admin perms, which is all
     `LiveAuth :admin` asks), dead-renders 403 at that destination. Both facts
     are pinned below.

  MUTATION-PROVEN: relaxing `ResolveWorkspace`'s forbidden halt to `assign(conn,
  :current_workspace, workspace)` reds the shape-A rows — see the commit message
  body for the quoted failure names.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Barkpark.{Auth, Repo}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership

  @dataset "production"

  # The two LiveViews that derive `BarkparkWeb.Studio.Caps` on their socket.
  @caps_bearing [BarkparkWeb.Studio.StudioLive, BarkparkWeb.Studio.ApiTesterLive]

  setup %{conn: conn} do
    {default_ws, default_proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    {:ok, conn: conn, default_ws: default_ws, default_proj: default_proj}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp workspace_with_project!(prefix) do
    ws = Barkpark.TenancyFixtures.create_workspace!(unique(prefix))
    {ws, Barkpark.TenancyFixtures.create_project!(ws, unique("#{prefix}-proj"))}
  end

  defp studio_url(ws, proj, tail \\ ""),
    do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio" <> tail

  defp admin_token!(label) do
    raw = "#{label}-#{Ecto.UUID.generate()}"
    {:ok, token} = Auth.create_token(raw, label, @dataset, ["read", "write", "admin"])
    {raw, token}
  end

  defp memberships_of(token),
    do: Repo.all(from(m in Membership, where: m.principal_id == ^token.id))

  defp session(conn, raw), do: Plug.Test.init_test_session(conn, %{"api_token" => raw})

  # A LiveView redirect carries its flash as a SIGNED token, not a bare map.
  defp flash_of(%{flash: token}) when is_binary(token),
    do: Phoenix.LiveView.Utils.verify_flash(BarkparkWeb.Endpoint, token)

  defp flash_of(%{flash: %{} = flash}), do: flash
  defp flash_of(_), do: %{}

  # ── 1. ROUTE CENSUS ────────────────────────────────────────────────────────

  defp caps_bearing_routes do
    Enum.flat_map(BarkparkWeb.Router.__routes__(), fn route ->
      case route.metadata[:phoenix_live_view] do
        {mod, _action, _opts, extra} when mod in @caps_bearing -> [{route.path, extra}]
        _ -> []
      end
    end)
  end

  describe "route census — every Caps-bearing LiveView sits behind LiveScope :resolve" do
    test "there are exactly THREE such routes and all live in live_session :scoped_studio" do
      routes = caps_bearing_routes()

      assert length(routes) == 3,
             """
             The Caps-bearing route census changed: #{inspect(Enum.map(routes, &elem(&1, 0)))}.

             Every StudioLive/ApiTesterLive route MUST live in `live_session
             :scoped_studio` behind {BarkparkWeb.LiveScope, :resolve}. If you added
             a route, add it there and bump this count. If you added one OUTSIDE
             that session, the parity table's BENIGN-by-unreachability labels no
             longer hold and this is the failure that says so.
             """

      assert Enum.sort(Enum.map(routes, &elem(&1, 0))) == [
               "/w/:workspace_slug/p/:project_slug/d/:dataset/studio",
               "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/*path",
               "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/api-tester"
             ]

      for {path, extra} <- routes do
        assert extra.name == :scoped_studio, "#{path} is not in live_session :scoped_studio"

        on_mount_ids = Enum.map(extra.extra.on_mount, & &1.id)

        assert {BarkparkWeb.LiveScope, :resolve} in on_mount_ids,
               "#{path} does not hook LiveScope :resolve — its mounts are unguarded"

        assert on_mount_ids == [
                 {BarkparkWeb.LiveAuth, :fetch_api_token},
                 {BarkparkWeb.LiveAuth, :require_org_mfa},
                 {BarkparkWeb.LiveScope, :resolve},
                 {BarkparkWeb.StudioChrome, :default}
               ]
      end
    end

    test "the router SOURCE declares StudioLive/ApiTesterLive exactly three times" do
      source = File.read!("lib/barkpark_web/router.ex")

      declarations =
        Regex.scan(~r/live\("[^"]*",\s*(StudioLive|ApiTesterLive)\)/, source)
        |> Enum.map(&hd/1)

      assert length(declarations) == 3, "router source declares: #{inspect(declarations)}"
      assert source =~ "live_session :scoped_studio"
    end

    test "LiveScope's %ApiToken{} read arm is EXCLUSIVE — no fallthrough to the anonymous arms" do
      source = File.read!("lib/barkpark_web/live_scope.ex")

      assert source =~
               """
                   case socket.assigns[:api_token] do
                     %Barkpark.Auth.ApiToken{} = token ->
                       case Tenancy.Auth.authorize(token, ws.id, :read) do
                         :ok -> {:ok, :member}
                         err -> err
                       end
               """,
             """
             LiveScope.authorize_read/4's %ApiToken{} branch must return the
             authorize/3 error DIRECTLY. If it ever falls through to the
             anonymous-default / share / grant `cond` below, a token denied by
             Tenancy.Auth could still mount a Caps-bearing socket on the seeded
             Default workspace (public_demo_studio) — and shape A stops being
             unreachable.
             """
    end
  end

  # ── 2. SHAPE A — no membership row anywhere → 403 on all four addresses ────

  describe "shape A (global-admin perms, ZERO memberships) is unreachable" do
    setup %{conn: conn, default_ws: default_ws, default_proj: default_proj} do
      {raw, token} = admin_token!("caps-reach-shape-a")

      # THE FIXTURE TRAP: create_token/5 auto-memberships the token in its home
      # workspace. Without this delete, shape A silently degrades into shape B.
      {deleted, _} = Repo.delete_all(from(m in Membership, where: m.principal_id == ^token.id))
      assert deleted == 1, "create_token/5 no longer auto-creates a home membership"
      assert memberships_of(token) == []

      {foreign_ws, foreign_proj} = workspace_with_project!("shape-a-foreign")

      {:ok,
       conn: session(conn, raw),
       token: token,
       foreign_ws: foreign_ws,
       foreign_proj: foreign_proj,
       default_ws: default_ws,
       default_proj: default_proj}
    end

    test "403, halted, no Location on all four Caps-bearing addresses", ctx do
      addresses = [
        {"scoped studio", studio_url(ctx.foreign_ws, ctx.foreign_proj)},
        {"api-tester", studio_url(ctx.foreign_ws, ctx.foreign_proj, "/api-tester")},
        {"/*path wildcard", studio_url(ctx.foreign_ws, ctx.foreign_proj, "/some/deep/path")},
        {"its OWN default workspace", studio_url(ctx.default_ws, ctx.default_proj)}
      ]

      for {label, url} <- addresses do
        conn = get(ctx.conn, url)

        assert conn.status == 403, "#{label} (#{url}) returned #{conn.status}, expected 403"
        assert conn.halted, "#{label} (#{url}) was not halted"

        assert Plug.Conn.get_resp_header(conn, "location") == [],
               "#{label} (#{url}) redirected instead of forbidding"
      end

      # Still zero rows: nothing in the request path created a membership.
      assert memberships_of(ctx.token) == []
    end

    test "the denial is the ResolveWorkspace envelope, not a LiveView redirect", ctx do
      conn = get(ctx.conn, studio_url(ctx.foreign_ws, ctx.foreign_proj))

      assert %{"error" => %{"code" => code}} = json_response(conn, 403)
      assert code in ["forbidden", "FORBIDDEN"]
    end
  end

  # ── 3. SHAPE B — global-admin token + plain member row → MOUNTS ────────────

  describe "shape B (global-admin perms + a plain `member` row) mounts" do
    setup %{conn: conn} do
      {raw, token} = admin_token!("caps-reach-shape-b")
      {ws, proj} = workspace_with_project!("shape-b")

      # create_membership/4's DEFAULT role is "member" — routing through
      # create_token/5 instead would mint a perms-derived "admin" row and build
      # the wrong shape.
      {:ok, membership} = TenancyAuth.create_membership(ws.id, token.id)

      {:ok, conn: session(conn, raw), token: token, ws: ws, proj: proj, membership: membership}
    end

    test "the view mounts, Caps IS attached, and the row really is a plain member", ctx do
      assert ctx.membership.role == "member"

      {:ok, view, _html} = live(ctx.conn, studio_url(ctx.ws, ctx.proj))

      assigns = :sys.get_state(view.pid).socket.assigns

      # FIX-INDEPENDENT facts only. The caps DECISION values (caps.admin & co)
      # flip under the sibling parity slice — they belong to that suite.
      assert is_map(assigns.caps), "Caps is not attached on the scoped studio route"
      assert assigns.current_workspace.slug == ctx.ws.slug

      # Re-read the row from the store: the mount did not escalate it.
      assert %Membership{role: "member"} =
               Repo.one!(
                 from(m in Membership,
                   where: m.principal_id == ^ctx.token.id and m.workspace_id == ^ctx.ws.id
                 )
               )
    end

    test "a live navigation into a workspace it holds no row in is re-authorized and DENIED",
         ctx do
      {:ok, view, _html} = live(ctx.conn, studio_url(ctx.ws, ctx.proj))

      {other_ws, other_proj} = workspace_with_project!("shape-b-foreign")
      assert memberships_of(ctx.token) |> Enum.all?(&(&1.workspace_id != other_ws.id))

      assert {:error, {:redirect, %{to: to} = redirect}} =
               live_redirect(view, to: studio_url(other_ws, other_proj))

      assert to =~ "/login"
      assert flash_of(redirect)["error"] == "Not authorized for that workspace"
    end
  end

  # ── 5. The FLAT /studio/* chrome routes carry NO Caps ──────────────────────

  describe "the flat /studio/* admin chrome routes are Caps-free" do
    setup %{conn: conn} do
      {raw, token} = admin_token!("caps-reach-flat")
      {:ok, conn: session(conn, raw), token: token}
    end

    test "assigns[:caps] is nil on org-admin and styleguide", %{conn: conn, default_ws: ws} do
      for path <- ["/studio/org-admin", "/studio/styleguide"] do
        {:ok, view, _html} = live(conn, path)
        assigns = :sys.get_state(view.pid).socket.assigns

        assert assigns[:caps] == nil,
               """
               #{path} now carries a Caps map. These routes have NO LiveScope
               :resolve — StudioChrome.default_scope_fallback/1 labels the socket
               with the seeded Default workspace WITHOUT a membership check — so a
               Caps deny-gate here would be deciding against an unauthorized
               workspace label. If Caps is genuinely wanted on the flat chrome,
               the route needs LiveScope :resolve first.
               """

        # The fallback label itself is present (this is the mechanism the pin
        # describes) — harmless only because no capability is derived from it.
        assert assigns[:current_workspace].id == ws.id
      end
    end

    # REFUTED BRIEF CLAIM, recorded rather than forced: firing `shares-open`
    # on the flat chrome does NOT raise :function_clause. StudioChrome's
    # `chrome_fallback("shares-open", …)` (studio_chrome.ex:176 → nav_to_shares/1)
    # handles it for every non-StudioLive surface. It still cannot open a
    # deny-gated panel in place — the shares PANEL only exists in StudioLive —
    # so the event push_navigates INTO the scoped studio, back behind
    # LiveScope :resolve. That is the honest mechanism, and it is stronger than
    # the "no handler" story: the guard is re-entered, not merely absent.
    test "shares-open on the flat chrome navigates INTO the LiveScope-guarded scoped studio",
         %{conn: conn, default_ws: ws, default_proj: proj} do
      {:ok, view, _html} = live(conn, "/studio/org-admin")

      assert {:error, {:live_redirect, %{to: to}}} = render_hook(view, "shares-open", %{})

      assert to == studio_url(ws, proj) <> "?shares=open"

      # …and that destination is one of the three census routes, i.e. it mounts
      # behind {LiveScope, :resolve}. No panel opens on this Caps-free socket.
      assert Enum.any?(caps_bearing_routes(), fn {path, extra} ->
               path == "/w/:workspace_slug/p/:project_slug/d/:dataset/studio" and
                 extra.name == :scoped_studio
             end)
    end

    test "shape A can mount the flat chrome, but the shares navigation it fires is DENIED",
         %{conn: _conn, default_ws: ws, default_proj: proj} = ctx do
      # Shape A holds global admin permissions, so LiveAuth :admin admits it to
      # the flat chrome — this is precisely the socket the phantom affordance
      # renders on. Follow the affordance to its end and it dies at the scoped
      # route's guard.
      {raw, token} = admin_token!("caps-reach-flat-shape-a")
      {deleted, _} = Repo.delete_all(from(m in Membership, where: m.principal_id == ^token.id))
      assert deleted == 1
      conn = session(ctx.conn, raw)

      {:ok, view, _html} = live(conn, "/studio/org-admin")
      assert :sys.get_state(view.pid).socket.assigns[:caps] == nil

      assert {:error, {:live_redirect, %{to: to}}} = render_hook(view, "shares-open", %{})
      assert to == studio_url(ws, proj) <> "?shares=open"

      # The destination dead-renders 403 for this principal: ResolveWorkspace
      # halts before any Caps-bearing socket exists.
      assert get(conn, to).status == 403
    end
  end
end
