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

  @dataset "production"
  @admin "shares-studio-admin"
  @junior "shares-studio-junior"

  setup %{conn: conn} do
    {:ok, _} = Auth.create_token(@admin, "shares admin", "production", ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(@junior, "shares junior", "production", ["read", "write"])

    prior_shares = Application.get_env(:barkpark, :shares)
    prior_env = Application.get_env(:barkpark, :shares_env)
    Application.put_env(:barkpark, :shares, [])
    Application.put_env(:barkpark, :shares_env, [])

    on_exit(fn ->
      restore(:shares, prior_shares)
      restore(:shares_env, prior_env)
    end)

    {:ok, conn: conn}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp admin_view(conn) do
    conn
    |> init_test_session(%{"api_token" => @admin})
    |> live(scoped_studio("/studio/#{@dataset}"))
  end

  defp junior_view(conn) do
    conn
    |> init_test_session(%{"api_token" => @junior})
    |> live(scoped_studio("/studio/#{@dataset}"))
  end

  # ── admin happy path ──────────────────────────────────────────────────────

  describe "admin" do
    test "the top-bar Share button renders for an admin", %{conn: conn} do
      {:ok, _view, html} = admin_view(conn)
      assert html =~ ~s(phx-click="shares-open")
    end

    test "opens the panel, adds a share live, then removes it", %{conn: conn} do
      {:ok, view, _html} = admin_view(conn)

      # Open via the real top-bar button.
      view |> element("button[phx-click=shares-open]") |> render_click()
      panel = render(view)
      assert panel =~ "Network shares"
      assert panel =~ "Active shares"

      # Add — registry was empty, the share goes live immediately.
      refute Sharing.shared?("gyldendal", "default", "production", :papers)

      render_hook(view, "shares-add", %{
        "scope" => "gyldendal/default/production",
        "surfaces" => ["papers", "docs"]
      })

      assert Sharing.shared?("gyldendal", "default", "production", :papers)
      assert Sharing.shared?("gyldendal", "default", "production", :docs)
      # access is pinned to read until the edit path (P5) lands.
      assert Sharing.access_for("gyldendal", "default", "production") == :read
      assert render(view) =~ "gyldendal/default/production"

      # Remove.
      render_hook(view, "shares-remove", %{"scope" => "gyldendal/default/production"})
      refute Sharing.shared?("gyldendal", "default", "production", :papers)
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
  end

  # ── privilege-escalation guard (the security core) ────────────────────────

  describe "non-admin is locked out" do
    test "the Share button is hidden for a non-admin token", %{conn: conn} do
      {:ok, _view, html} = junior_view(conn)
      refute html =~ ~s(phx-click="shares-open")
    end

    test "the Share button is hidden for an anonymous session", %{conn: conn} do
      {:ok, _view, html} = live(conn, scoped_studio("/studio/#{@dataset}"))
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
end
