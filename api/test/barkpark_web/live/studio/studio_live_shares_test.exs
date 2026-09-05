defmodule BarkparkWeb.Studio.StudioLiveSharesTest do
  @moduledoc """
  P6 — the Studio "Network shares" panel.

  StudioLive runs in the :studio_public live_session (only :fetch_api_token), so
  a non-admin — even an anonymous — session can reach the desk. The shares panel
  calls Barkpark.Sharing.* IN-PROCESS, bypassing the /v1/shares :require_admin
  gate, so every shares-* handler re-checks admin server-side. These tests pin
  BOTH the happy path (admin can add/remove) AND the privilege-escalation guard:
  a non-admin pushing the raw event (button hidden) must NOT mutate the registry.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Sharing}
  alias Barkpark.Repo
  alias Barkpark.Sharing.{Links, ShareLink}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  import Barkpark.TenancyFixtures

  @dataset "production"
  @admin "shares-studio-admin"
  @junior "shares-studio-junior"

  setup %{conn: conn} do
    {:ok, admin_tok} =
      Auth.create_token(@admin, "shares admin", "production", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior, "shares junior", "production", ["read", "write"])

    prior_shares = Application.get_env(:barkpark, :shares)
    prior_env = Application.get_env(:barkpark, :shares_env)
    Application.put_env(:barkpark, :shares, [])
    Application.put_env(:barkpark, :shares_env, [])

    on_exit(fn ->
      restore(:shares, prior_shares)
      restore(:shares_env, prior_env)
    end)

    {:ok, conn: conn, admin_tok: admin_tok}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  # A REAL workspace the @admin token administers, for the declare/revoke happy
  # paths. These used to name `gyldendal/default/production` — a slug with NO
  # workspace row — which stopped being declarable when the Shares panel went
  # fail-closed on an unresolvable workspace (lead-security 2026-09-02: a ghost
  # share is an authorisation attached to a NAME, and whoever later registers
  # that slug inherits a public exposure they never made). The happy path is now
  # spelled on a workspace that EXISTS and that this actor genuinely administers,
  # which also makes these tests exercise the foreign-but-authorized arm rather
  # than a slug the clamp could never resolve.
  defp declarable_scope!(admin_tok) do
    n = System.unique_integer([:positive])
    ws = create_workspace!("shares-happy-#{n}")
    proj = create_project!(ws, "shares-happy-proj-#{n}")
    {:ok, _} = TenancyAuth.create_membership(ws.id, admin_tok.id, "admin", "api_token")
    assert TenancyAuth.workspace_admin?(admin_tok, ws.id)
    {ws.slug, proj.slug, "#{ws.slug}/#{proj.slug}/#{@dataset}"}
  end

  defp admin_view(conn) do
    conn
    |> init_test_session(%{"api_token" => @admin})
    |> live(scoped_studio("/d/#{@dataset}/studio"))
  end

  defp junior_view(conn) do
    conn
    |> init_test_session(%{"api_token" => @junior})
    |> live(scoped_studio("/d/#{@dataset}/studio"))
  end

  # ── admin happy path ──────────────────────────────────────────────────────

  describe "admin" do
    test "the top-bar Share button renders for an admin", %{conn: conn} do
      {:ok, _view, html} = admin_view(conn)
      assert html =~ ~s(phx-click="shares-open")
    end

    test "opens the panel, adds a share live, then removes it", %{
      conn: conn,
      admin_tok: admin_tok
    } do
      {ws, proj, scope} = declarable_scope!(admin_tok)
      {:ok, view, _html} = admin_view(conn)

      # Open via the real top-bar button.
      view |> element("button[phx-click=shares-open]") |> render_click()
      panel = render(view)
      assert panel =~ "Network shares"
      assert panel =~ "Active shares"

      # Add — registry was empty, the share goes live immediately.
      refute Sharing.shared?(ws, proj, "production", :papers)

      render_hook(view, "shares-add", %{"scope" => scope, "surfaces" => ["papers", "docs"]})

      assert Sharing.shared?(ws, proj, "production", :papers)
      assert Sharing.shared?(ws, proj, "production", :docs)
      # access is pinned to read until the edit path (P5) lands.
      assert Sharing.access_for(ws, proj, "production") == :read
      assert render(view) =~ scope

      # Remove.
      render_hook(view, "shares-remove", %{"scope" => scope})
      refute Sharing.shared?(ws, proj, "production", :papers)
    end

    test "rejects an invalid scope without crashing the panel", %{conn: conn} do
      {:ok, view, _html} = admin_view(conn)
      view |> element("button[phx-click=shares-open]") |> render_click()

      render_hook(view, "shares-add", %{
        "scope" => "*/default/production",
        "surfaces" => ["papers"]
      })

      refute Sharing.shared?("*", "default", "production", :papers)
      assert render(view) =~ "Invalid share"
    end

    test "rejects an add with no surfaces selected", %{conn: conn} do
      {:ok, view, _html} = admin_view(conn)
      view |> element("button[phx-click=shares-open]") |> render_click()

      render_hook(view, "shares-add", %{"scope" => "gyldendal/default/production"})

      refute Sharing.active?()
      assert render(view) =~ "at least one surface"
    end

    test "opening with a surface pre-selects only that checkbox (P6b contextual buttons)", %{
      conn: conn
    } do
      {:ok, view, _html} = admin_view(conn)

      # The media / paper Share buttons fire shares-open with phx-value-surface.
      render_hook(view, "shares-open", %{"surface" => "media"})

      assert has_element?(view, ~s(input[value="media"][checked]))
      refute has_element?(view, ~s(input[value="papers"][checked]))
      refute has_element?(view, ~s(input[value="docs"][checked]))
    end

    test "opening from the top bar pre-selects no surface", %{conn: conn} do
      {:ok, view, _html} = admin_view(conn)
      view |> element("button[phx-click=shares-open]") |> render_click()

      refute has_element?(view, ~s(input[value="media"][checked]))
      refute has_element?(view, ~s(input[value="papers"][checked]))
    end

    # ── kit markup + param shape (sup-w3-shares-modal-kit) ──────────────────
    # The surfaces picker is the last naked native control in Studio: it must
    # ride the bp_checkbox kit (label.form-checkbox) while keeping the exact
    # surfaces[] form-param semantics the shares-add handler decodes into a list.
    test "surfaces picker renders bp_checkbox kit markup with surfaces[] params", %{
      conn: conn,
      admin_tok: admin_tok
    } do
      {ws, proj, scope} = declarable_scope!(admin_tok)
      {:ok, view, _html} = admin_view(conn)
      view |> element("button[phx-click=shares-open]") |> render_click()

      for surface <- ~w(papers docs media) do
        # Kit envelope: the input lives inside the tokenized label.form-checkbox,
        # not a bare <label> — no naked native control remains.
        assert has_element?(
                 view,
                 ~s(label.form-checkbox input[type="checkbox"][name="surfaces[]"][value="#{surface}"])
               )
      end

      # Labels come from String.capitalize/1 via the bp_checkbox <span>.
      panel = render(view)
      assert panel =~ "Papers"
      assert panel =~ "Docs"
      assert panel =~ "Media"

      # Param shape is byte-preserved: name="surfaces[]" is what makes Phoenix
      # collect the checked boxes into a list the shares-add handler consumes.
      render_hook(view, "shares-add", %{"scope" => scope, "surfaces" => ["papers", "media"]})

      assert Sharing.shared?(ws, proj, "production", :papers)
      assert Sharing.shared?(ws, proj, "production", :media)
      refute Sharing.shared?(ws, proj, "production", :docs)
    end
  end

  # ── privilege-escalation guard (the security core) ────────────────────────

  describe "non-admin is locked out" do
    test "the Share button is hidden for a non-admin token", %{conn: conn} do
      {:ok, _view, html} = junior_view(conn)
      refute html =~ ~s(phx-click="shares-open")
    end

    test "the Share button is hidden for an anonymous session", %{conn: conn} do
      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))
      refute html =~ ~s(phx-click="shares-open")
    end

    test "a non-admin pushing shares-add directly does NOT create a share", %{conn: conn} do
      {:ok, view, _html} = junior_view(conn)
      refute Sharing.shared?("evil", "default", "production", :papers)

      # The button is hidden, but a crafted client could still push the event.
      render_hook(view, "shares-add", %{
        "scope" => "evil/default/production",
        "surfaces" => ["papers", "docs", "media"]
      })

      refute Sharing.shared?("evil", "default", "production", :papers)
      refute Sharing.active?()
    end

    test "a non-admin pushing shares-remove does NOT revoke an admin's share", %{conn: conn} do
      {:ok, _} = Sharing.add_share("keep/default/production:papers:read")
      assert Sharing.shared?("keep", "default", "production", :papers)

      {:ok, view, _html} = junior_view(conn)
      render_hook(view, "shares-remove", %{"scope" => "keep/default/production"})

      assert Sharing.shared?("keep", "default", "production", :papers)
    end
  end

  # ── item (per-document) share popover (P7) ────────────────────────────────

  describe "item share — Google-Docs-style per-document links" do
    test "admin opens the popover, mints a stable link, then revokes it", %{conn: conn} do
      {:ok, view, _html} = admin_view(conn)

      # the paper Share button fires this with DASH-keyed phx-value params
      # (ref-type / ref-id) — match that exactly so the handler's param reads
      # are exercised the way the real button drives them.
      render_hook(view, "item-share-open", %{
        "kind" => "doc",
        "ref-type" => "paper",
        "ref-id" => "demo-paper",
        "title" => "Demo Paper"
      })

      panel = render(view)
      assert panel =~ "Demo Paper"
      assert panel =~ "Create view link"

      ws = Barkpark.Tenancy.get_default_workspace()
      assert Barkpark.Sharing.Links.list_for(ws.id, "doc", "paper", "demo-paper") == []

      # create — a stable /s/<token> link appears
      render_hook(view, "item-share-create", %{"access" => "read"})
      assert render(view) =~ "/s/"
      assert [link] = Barkpark.Sharing.Links.list_for(ws.id, "doc", "paper", "demo-paper")

      # revoke
      render_hook(view, "item-share-revoke", %{"id" => link.id})

      assert [%{revoked_at: revoked}] =
               Barkpark.Sharing.Links.list_for(ws.id, "doc", "paper", "demo-paper")

      refute is_nil(revoked)
    end

    # Edit-on-the-link slice 3 (task-8ac4f3918da1c433): the popover gained the
    # second access level. Both buttons land on the SAME handler and the same
    # `Links.create/1`; only `phx-value-access` differs.
    test "the popover offers BOTH access levels and mints an edit link", %{conn: conn} do
      {:ok, view, _html} = admin_view(conn)

      render_hook(view, "item-share-open", %{
        "kind" => "doc",
        "ref-type" => "paper",
        "ref-id" => "demo-paper",
        "title" => "Demo Paper"
      })

      panel = render(view)
      assert panel =~ "Create view link"
      assert panel =~ "Create edit link"

      ws = Barkpark.Tenancy.get_default_workspace()

      render_hook(view, "item-share-create", %{"access" => "edit"})

      assert [%{access: "edit"}] =
               Barkpark.Sharing.Links.list_for(ws.id, "doc", "paper", "demo-paper")
    end

    test "the per-paper Share button targets item-share, NOT the section modal", %{conn: conn} do
      # Regression for the original complaint: pressing Share on a paper must open
      # the item popover, not "Network shares".
      {:ok, view, _html} = admin_view(conn)

      render_hook(view, "item-share-open", %{
        "kind" => "doc",
        "ref-type" => "paper",
        "ref-id" => "p"
      })

      html = render(view)
      # the item popover is open...
      assert html =~ "item-share-create"
      # ...and the SECTION modal (its add form) is NOT.
      refute html =~ ~s(phx-submit="shares-add")
    end

    test "a non-admin cannot mint an item link by pushing the event", %{conn: conn} do
      {:ok, view, _html} = junior_view(conn)
      ws = Barkpark.Tenancy.get_default_workspace()

      render_hook(view, "item-share-open", %{
        "kind" => "doc",
        "ref-type" => "paper",
        "ref-id" => "x"
      })

      render_hook(view, "item-share-create", %{"access" => "read"})

      assert Barkpark.Sharing.Links.list_for(ws.id, "doc", "paper", "x") == []
    end
  end

  # ── item-share revoke: cross-tenant confinement ───────────────────────────
  #
  # arpss-item-share-revoke-unscoped-revoke. `item-share-revoke` carries a RAW
  # CLIENT `phx-value-id` into `Sharing.Links.revoke/1`, which is an unscoped
  # `Repo.get(ShareLink, uuid)`. `Caps.admin?/1` gates WHO the actor is on the
  # workspace it MOUNTED (workspace-scoped SEAT authority since #12695) — it
  # never constrains WHICH row the id names, so a seated admin of A could
  # revoke B's link. The handler now authorizes against the ROW's OWN workspace.
  describe "item share revoke — cross-tenant confinement" do
    setup %{admin_tok: admin_tok} do
      # Victim workspace B and a LIVE credential in it. B is a real foreign
      # tenant: nothing about it is reachable from the mounted (default) scope.
      ws_b = create_workspace!("item-revoke-victim-#{System.unique_integer([:positive])}")
      proj_b = create_project!(ws_b, "victim-proj-#{System.unique_integer([:positive])}")

      {:ok, {raw_b, link_b}} =
        Links.create(%{
          workspace_id: ws_b.id,
          project_id: proj_b.id,
          dataset: @dataset,
          kind: "doc",
          ref_type: "paper",
          ref_id: "victim-paper",
          access: "read"
        })

      # THE ATTACKER SHAPE the predicate choice turns on: @admin is a seat admin
      # of its OWN home workspace (the seeded default, written by
      # `Auth.create_token/5` — never a hand-inserted %ApiToken{workspace_id:
      # nil}), and holds a REAL but plain `member` membership in B. A total
      # stranger to B would be denied under BOTH candidate predicates and would
      # prove nothing.
      {:ok, _} = TenancyAuth.create_membership(ws_b.id, admin_tok.id, "member")

      # Preconditions asserted inline so the predicate choice is provably
      # load-bearing: this actor PASSES `authorize/3` in B (its api_token arm
      # ORs the token's GLOBAL permissions[] with membership) and FAILS
      # `workspace_admin?/2`. Swap the new gate to `authorize/3` and the leak
      # test below goes green on a leaking handler.
      assert TenancyAuth.membership_role(admin_tok, ws_b.id) == "member"
      assert TenancyAuth.authorize(admin_tok, ws_b.id, :admin) == :ok
      refute TenancyAuth.workspace_admin?(admin_tok, ws_b.id)

      %{ws_b: ws_b, link_b: link_b, raw_b: raw_b}
    end

    test "LEAK CLOSED: a seated admin of A cannot revoke workspace B's link", %{
      conn: conn,
      link_b: link_b,
      raw_b: raw_b
    } do
      {:ok, view, _html} = admin_view(conn)

      # The actor really does clear the handler's own admin gate on the mounted
      # workspace — without this the denial could come from `Caps.admin?/1` and
      # the test would pass for the wrong reason. The positive control below
      # drives the SAME socket to a successful revoke to prove exactly that.
      render_hook(view, "item-share-open", %{
        "kind" => "doc",
        "ref-type" => "paper",
        "ref-id" => "victim-paper"
      })

      render_hook(view, "item-share-revoke", %{"id" => link_b.id})

      # ASSERT THE ROW, not a flash: a "denial" that still stamped revoked_at
      # would be the same cross-tenant write in disguise.
      row = Repo.get(ShareLink, link_b.id)
      refute is_nil(row)
      assert is_nil(row.revoked_at)

      # ...and B's credential is still LIVE — the tenant's `/s/<token>` URL did
      # not go dark.
      assert {:ok, _} = Links.resolve(raw_b)

      # The denial is indistinguishable from a missing row: same message, no
      # existence oracle.
      foreign = render(view)
      render_hook(view, "item-share-revoke", %{"id" => Ecto.UUID.generate()})
      assert render(view) == foreign
    end

    test "POSITIVE CONTROL: the same socket DOES revoke a link in its own workspace", %{
      conn: conn,
      link_b: link_b
    } do
      {:ok, view, _html} = admin_view(conn)
      ws = Barkpark.Tenancy.get_default_workspace()

      render_hook(view, "item-share-open", %{
        "kind" => "doc",
        "ref-type" => "paper",
        "ref-id" => "own-paper",
        "title" => "Own Paper"
      })

      render_hook(view, "item-share-create", %{"access" => "read"})
      assert [own] = Links.list_for(ws.id, "doc", "paper", "own-paper")
      assert is_nil(own.revoked_at)

      render_hook(view, "item-share-revoke", %{"id" => own.id})

      refute is_nil(Repo.get(ShareLink, own.id).revoked_at)
      # ...while B's row, untouched by this legitimate revoke, still stands.
      assert is_nil(Repo.get(ShareLink, link_b.id).revoked_at)
    end

    test "a non-castable link id is a denial, never a crash", %{conn: conn} do
      {:ok, view, _html} = admin_view(conn)

      render_hook(view, "item-share-open", %{
        "kind" => "doc",
        "ref-type" => "paper",
        "ref-id" => "own-paper"
      })

      render_hook(view, "item-share-revoke", %{"id" => "not-a-uuid"})
      assert render(view) =~ "item-share-create"
    end
  end
end
