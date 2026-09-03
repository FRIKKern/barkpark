defmodule BarkparkWeb.Studio.StudioLiveCapsGateTest do
  @moduledoc """
  ag-studio-capability-hide — the `@caps` map + the LOAD-BEARING server-side
  deny-gate (`BarkparkWeb.Studio.Caps`).

  Hidden ≠ denied: a forged `phx` event for a HIDDEN affordance is server-DENIED
  by the capability gate on EVERY Studio socket — proven NON-VACUOUSLY by the
  absence of the side-effect (no share / grant / document created), not merely a
  flash. The gate re-derives caps server-side, so a grant that expires
  mid-session denies a forged event even though LiveScope's write ladder (built
  from the STALE mount-time grant set) would still pass it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Accounts, Auth, Content, Sharing}
  alias Barkpark.Repo
  alias Barkpark.TenancyFixtures

  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias BarkparkWeb.Studio.Caps

  @dataset "production"
  @admin "caps-studio-admin"
  @member "caps-studio-member"
  @readonly "caps-studio-readonly"

  setup %{conn: conn} do
    {ws, _proj} = TenancyFixtures.ensure_default_scope!()

    {:ok, _} = Auth.create_token(@admin, "caps admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(@member, "caps member", @dataset, ["read", "write"])
    # A READ-ONLY api token: create_token auto-memberships it on the Default ws,
    # so it IS a member — but its permission array is ["read"], so derive/1's
    # write arm (permits?(token, :write)) is false. This is the exact shape of
    # the hole: a member-but-read-only principal on the non-restricted Default.
    {:ok, _} = Auth.create_token(@readonly, "caps readonly", @dataset, ["read"])

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    # A NON-default workspace: the Default workspace is an open public-demo in
    # test (`public_demo_studio: true`), so a grantee there mounts as the
    # anonymous-demo grade (no gate). A private workspace exercises the real
    # grant grade + LiveScope gates that the caps gate layers onto.
    priv_ws = create_workspace!("caps-priv-#{System.unique_integer([:positive])}")
    priv_proj = create_project!(priv_ws, "caps-priv-proj")

    # arpss-w8: refresh-proof Default-OFF baseline. A bare `put_env(:shares, [])`
    # is undone by the next Sharing.refresh/0 (which this suite CAN reach through
    # the forged `shares-add` events), and it never snapshots :shares_env.
    Barkpark.SharingFixtures.clear_shares!()

    {:ok, conn: conn, ws: ws, priv_ws: priv_ws, priv_proj: priv_proj}
  end

  defp priv_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  defp token_view(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{"api_token" => token})
    |> live(scoped_studio("/d/#{@dataset}/studio"))
  end

  # A signed-in, non-member USER admitted only by a covering grant.
  defp grantee_session(conn) do
    email = "caps-grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  # `grant_authority!/1` + `bind_grant!/3` moved to `Barkpark.AccessFixtures`
  # (imported above) — shared byte-identically across the four enforcement suites.

  defp caps(view), do: :sys.get_state(view.pid).socket.assigns.caps
  defp flash_error(view), do: :sys.get_state(view.pid).socket.assigns.flash["error"]
  defp doc_count, do: Repo.aggregate(Content.Document, :count)

  # ── 1. LOAD-BEARING forged-event admin deny (hidden ≠ denied) ────────────────

  describe "forged admin-event deny — the security core" do
    test "a non-admin MEMBER forging shares-add is server-DENIED — no share created", %{
      conn: conn
    } do
      {:ok, view, html} = token_view(conn, @member)
      # affordance hidden
      refute html =~ ~s(phx-click="shares-open")
      refute Sharing.active?()

      render_hook(view, "shares-add", %{
        "scope" => "evil/default/production",
        "surfaces" => ["papers", "docs", "media"]
      })

      # NON-VACUOUS: the gate halted before the handler — no registry mutation.
      refute Sharing.shared?("evil", "default", "production", :papers)
      refute Sharing.active?()
      assert flash_error(view) == "You don't have access to do that."
    end

    test "a non-admin MEMBER forging item-share-create mints NO link", %{conn: conn, ws: ws} do
      {:ok, view, _html} = token_view(conn, @member)

      render_hook(view, "item-share-open", %{
        "kind" => "doc",
        "ref-type" => "paper",
        "ref-id" => "x"
      })

      render_hook(view, "item-share-create", %{"access" => "read"})

      assert Sharing.Links.list_for(ws.id, "doc", "paper", "x") == []
    end

    test "a READ-ONLY grantee forging shares-add is DENIED — no share created", %{
      conn: conn,
      priv_ws: ws,
      priv_proj: proj
    } do
      {user, conn} = grantee_session(conn)
      bind_grant!(ws, user, %{capabilities: ["read"]})

      {:ok, view, html} = live(conn, priv_url(ws, proj))
      refute html =~ ~s(phx-click="shares-open")

      render_hook(view, "shares-add", %{
        "scope" => "evil/default/production",
        "surfaces" => ["papers"]
      })

      refute Sharing.active?()
    end
  end

  # ── 2. write-tier forged deny + write-capable success ────────────────────────

  describe "write-tier enforcement" do
    test "a READ-ONLY grantee forging a write (new-document) is DENIED — nothing persists", %{
      conn: conn,
      priv_ws: ws,
      priv_proj: proj
    } do
      {user, conn} = grantee_session(conn)
      bind_grant!(ws, user, %{capabilities: ["read"]})

      {:ok, view, _html} = live(conn, priv_url(ws, proj))

      before = doc_count()
      render_click(view, "new-document", %{"type" => "post"})
      assert doc_count() == before
    end

    test "a WRITE-capable grantee's new-document SUCCEEDS", %{
      conn: conn,
      priv_ws: ws,
      priv_proj: proj
    } do
      {user, conn} = grantee_session(conn)
      bind_grant!(ws, user, %{capabilities: ["read", "write"]})

      {:ok, view, _html} = live(conn, priv_url(ws, proj))

      before = doc_count()
      render_click(view, "new-document", %{"type" => "post"})
      assert doc_count() > before
    end
  end

  # ── 2b. write tier enforced on ALL sockets (authz-drift fix) ─────────────────

  describe "write-tier enforced on non-restricted sockets too" do
    test "a READ-ONLY api-token MEMBER forging new-document is DENIED — nothing persists", %{
      conn: conn
    } do
      {:ok, view, _html} = token_view(conn, @readonly)

      # The hole's exact shape: a member (auto-membership) whose token is
      # read-only, mounted on the non-restricted Default. Before the fix the
      # :write tier short-circuited on `not restricted?` and this write PASSED.
      assert caps(view) == %{read: true, write: false, admin: false}

      before = doc_count()
      render_click(view, "new-document", %{"type" => "post"})

      assert doc_count() == before
      assert flash_error(view) == "You don't have access to do that."
    end

    test "a READ-ONLY member forging save/publish/confirm-delete is DENIED (all :write)", %{
      conn: conn
    } do
      {:ok, view, _html} = token_view(conn, @readonly)

      for event <- ["save", "publish", "confirm-delete"] do
        render_hook(view, event, %{})
        assert flash_error(view) == "You don't have access to do that."
      end
    end

    test "a full-WRITE api-token member is NOT over-denied — new-document persists", %{
      conn: conn
    } do
      {:ok, view, _html} = token_view(conn, @member)

      before = doc_count()
      render_click(view, "new-document", %{"type" => "post"})
      assert doc_count() > before
    end

    test "a USER member (role member ⇒ read+write) is NOT over-denied", %{conn: conn, ws: ws} do
      {user, conn} = grantee_session(conn)
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")

      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))
      assert caps(view).write == true

      before = doc_count()
      render_click(view, "new-document", %{"type" => "post"})
      assert doc_count() > before
    end
  end

  # ── 3. affordance hiding driven by @caps.admin ───────────────────────────────

  describe "affordance hiding" do
    test "an admin SEES the Share affordance; a non-admin member does NOT", %{conn: conn} do
      {:ok, _admin_v, admin_html} = token_view(conn, @admin)
      assert admin_html =~ ~s(phx-click="shares-open")

      {:ok, _mem_v, mem_html} = token_view(conn, @member)
      refute mem_html =~ ~s(phx-click="shares-open")
    end
  end

  # ── 4. @caps correctness (observed from the mounted socket) ──────────────────

  describe "@caps map" do
    test "a membership admin ⇒ read+write+admin", %{conn: conn} do
      {:ok, view, _html} = token_view(conn, @admin)
      assert caps(view) == %{read: true, write: true, admin: true}
    end

    test "a read-only grantee ⇒ read only", %{conn: conn, priv_ws: ws, priv_proj: proj} do
      {user, conn} = grantee_session(conn)
      bind_grant!(ws, user, %{capabilities: ["read"]})

      {:ok, view, _html} = live(conn, priv_url(ws, proj))
      c = caps(view)
      assert c.read == true
      assert c.write == false
      assert c.admin == false
    end

    test "a write grant ⇒ write true (admin still false — grants never confer admin)", %{
      conn: conn,
      priv_ws: ws,
      priv_proj: proj
    } do
      {user, conn} = grantee_session(conn)
      bind_grant!(ws, user, %{capabilities: ["read", "write"]})

      {:ok, view, _html} = live(conn, priv_url(ws, proj))
      c = caps(view)
      assert c.write == true
      assert c.admin == false
    end
  end

  # ── 5. mid-session expiry denies (server RE-DERIVES, not stale) ──────────────

  describe "mid-session grant expiry" do
    test "a write grant that expires MID-SESSION denies a forged write — the caps gate re-derives",
         %{conn: conn, priv_ws: ws, priv_proj: proj} do
      {user, conn} = grantee_session(conn)

      grant =
        bind_grant!(ws, user, %{
          capabilities: ["read", "write"],
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      {:ok, view, _html} = live(conn, priv_url(ws, proj))
      # baseline: caps say write while the grant is live.
      assert caps(view).write == true

      # Expire the grant in the DB — the socket's mount-time grant set is now stale.
      grant
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Repo.update!()

      before = doc_count()
      render_click(view, "new-document", %{"type" => "post"})

      # LiveScope's write ladder uses the STALE mount-time grant (still future) and
      # would pass; the caps gate re-derives from the DB (expired ⇒ excluded) and
      # DENIES. Nothing persists, and the deny is the caps gate's.
      assert doc_count() == before
      assert flash_error(view) == "You don't have access to do that."
    end
  end

  # ── 6. members not regressed ─────────────────────────────────────────────────

  describe "members are byte-identical" do
    test "a real member's new-document persists (the gate does not over-deny)", %{conn: conn} do
      {:ok, view, _html} = token_view(conn, @member)
      before = doc_count()
      render_click(view, "new-document", %{"type" => "post"})
      assert doc_count() > before
    end
  end

  # ── 2c. admin-tier structural mutation (arpss-schema-action-write-tier-ruling) ─

  describe "structural mutation is admin-tier, not write-tier" do
    # The three events named by the ruling PLUS the two confirm-modal steps that
    # continue the same schema action (`confirm_modal_dryrun/1` dispatches
    # `:dryrun`, `confirm_modal_real/1` dispatches `:real`) — the steps are where
    # the mutation actually happens, so leaving them :write would gate the
    # operation one tier too low at the step that performs it.
    @structural_events ~w(schema_action bulk-publish bulk-unpublish
                          confirm-modal-dryrun confirm-modal-real)

    test "each structural event classifies to :admin" do
      for event <- @structural_events do
        assert Caps.classify(event) == :admin, "#{event} is not admin-tier"
      end
    end

    test "a WRITE-capable NON-admin member is HALTED on every structural event", %{conn: conn} do
      {:ok, view, _html} = token_view(conn, @member)

      # NON-VACUITY: this principal HAS write. Any deny below is therefore the
      # admin tier talking, not a missing write cap.
      assert caps(view) == %{read: true, write: true, admin: false}

      for event <- @structural_events do
        render_hook(view, event, %{"name" => "not-a-real-action"})

        assert flash_error(view) == "You don't have access to do that.",
               "write-capable non-admin was NOT halted on #{event}"
      end
    end

    test "an ADMIN is not over-denied — schema_action reaches the handler", %{conn: conn} do
      {:ok, view, _html} = token_view(conn, @admin)
      assert caps(view).admin == true

      render_hook(view, "schema_action", %{"name" => "not-a-real-action"})

      # The handler's own unknown-action branch flashed :info — only reachable
      # PAST the gate, so this is a positive pass proof, not an absent deny.
      state = :sys.get_state(view.pid).socket.assigns.flash
      assert state["info"] == "Action not-a-real-action not yet wired"
      refute state["error"] == "You don't have access to do that."
    end
  end

  # ── comprehensiveness: every privileged event is classified (default-deny) ───

  describe "gate comprehensiveness (default-deny by construction)" do
    test "every live handle_event head classifies to a KNOWN tier — never the :deny default" do
      source =
        File.read!(Path.join(File.cwd!(), "lib/barkpark_web/live/studio/studio_live.ex"))

      events =
        Regex.scan(~r/def handle_event\("([^"]+)"/, source)
        |> Enum.map(fn [_, name] -> name end)
        |> Enum.uniq()

      # sanity: we actually parsed a substantial set of heads
      assert length(events) > 50

      unclassified = Enum.filter(events, &(Caps.classify(&1) == :deny))

      assert unclassified == [],
             "these Studio events fall to the default-DENY tier — classify them in " <>
               "BarkparkWeb.Studio.Caps (safe/read/write/admin): #{inspect(unclassified)}"
    end

    test "the default (an unknown event) is DENY, and admin/write tiers are non-empty" do
      assert Caps.classify("some-brand-new-privileged-event") == :deny
      assert Caps.classify("shares-add") == :admin
      assert Caps.classify("save") == :write
      assert Caps.classify("select") == :none
    end
  end
end
