defmodule BarkparkWeb.Studio.ReturnToTest do
  @moduledoc """
  The `return_to` contract for Studio's flat, scope-free destinations
  (chat/tmux/styleguide/org-admin — charter `bp-studio-deep-link` D5).

  Three layers, proven end to end:

    * the pure `ReturnTo` validator (open-redirect guard),
    * the nav top-menu tabs that emit `?return_to=<canonical>` from a SCOPED
      surface and stay bare from a flat one,
    * the flat LiveViews (chat/tmux) that thread the param through their own
      patches and prefer the validated `return_to` over the `/studio` funnel
      on their disabled-fallback / exit redirect.

  `async: false` — the nav + LV arcs flip global `:claude_chat` / `:tmux_console`
  enable flags (restored in `on_exit`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias BarkparkWeb.Studio.ReturnTo

  @scoped "/w/acme/p/site/d/production/studio"
  @ws_scoped "/w/acme/p/site/studio/settings"
  @admin_token "return-to-admin-token"

  # ── Layer 1: the pure validator (open-redirect guard) ────────────────────

  describe "valid?/1" do
    test "accepts a dataset-scoped canonical Studio path" do
      assert ReturnTo.valid?(@scoped)
      assert ReturnTo.valid?("/w/ws/p/proj/d/ds/studio")
      assert ReturnTo.valid?("/w/ws/p/proj/d/ds/studio/media")
      assert ReturnTo.valid?("/w/ws/p/proj/d/ds/studio/some/deep/path")
    end

    test "accepts a workspace-level (dataset-less) canonical Studio path" do
      assert ReturnTo.valid?(@ws_scoped)
      assert ReturnTo.valid?("/w/ws/p/proj/studio")
    end

    test "accepts a canonical path carrying a query string" do
      assert ReturnTo.valid?("/w/ws/p/proj/d/ds/studio?shares=open")
    end

    test "rejects absolute URLs" do
      refute ReturnTo.valid?("https://evil.com")
      refute ReturnTo.valid?("http://evil.com/w/ws/p/proj/d/ds/studio")
    end

    test "rejects scheme-relative host redirects" do
      refute ReturnTo.valid?("//evil.com")
      refute ReturnTo.valid?("//evil.com/w/ws/p/proj/d/ds/studio")
    end

    test "rejects non-Studio local paths" do
      refute ReturnTo.valid?("/admin")
      refute ReturnTo.valid?("/studio")
      refute ReturnTo.valid?("/w/ws/p/proj/d/ds/other")
    end

    test "rejects a `/studio` prefix trick (must be followed by / or ? or end)" do
      refute ReturnTo.valid?("/w/ws/p/proj/d/ds/studioevil")
    end

    test "rejects dot-segment traversal (browser would normalize to another path)" do
      refute ReturnTo.valid?("/w/a/p/b/studio/../../../../logout")
      refute ReturnTo.valid?("/w/a/p/b/d/ds/studio/./x")
      # WHATWG URL parsers treat %2e-spelled dot-segments as dots too.
      refute ReturnTo.valid?("/w/a/p/b/studio/%2E%2E/%2e%2e/logout")
      refute ReturnTo.valid?("/w/a/p/b/studio/.%2e/x")
    end

    test "rejects empty and non-binary" do
      refute ReturnTo.valid?("")
      refute ReturnTo.valid?(nil)
      refute ReturnTo.valid?(:not_a_string)
    end
  end

  describe "sanitize/1" do
    test "returns the value when valid, nil otherwise" do
      assert ReturnTo.sanitize(@scoped) == @scoped
      assert ReturnTo.sanitize("https://evil.com") == nil
      assert ReturnTo.sanitize("//evil.com") == nil
      assert ReturnTo.sanitize("/admin") == nil
      assert ReturnTo.sanitize("") == nil
      assert ReturnTo.sanitize(nil) == nil
    end
  end

  describe "sanitize_dest/1 (login-return destination — charter D69)" do
    test "admits the FLAT /studio deep links the notifier links to" do
      assert ReturnTo.sanitize_dest("/studio/chat/abc-123") == "/studio/chat/abc-123"

      assert ReturnTo.sanitize_dest("/studio/chat/abc?panel=diff") ==
               "/studio/chat/abc?panel=diff"

      assert ReturnTo.sanitize_dest("/studio/tmux") == "/studio/tmux"
      assert ReturnTo.sanitize_dest("/studio") == "/studio"
    end

    test "still admits the scoped grammar (superset of sanitize/1)" do
      assert ReturnTo.sanitize_dest(@scoped) == @scoped

      assert ReturnTo.sanitize_dest("/w/ws/p/proj/d/ds/studio/media") ==
               "/w/ws/p/proj/d/ds/studio/media"
    end

    test "rejects off-origin, authority tricks, and non-Studio paths" do
      assert ReturnTo.sanitize_dest("https://evil.com") == nil
      assert ReturnTo.sanitize_dest("//evil.com") == nil
      assert ReturnTo.sanitize_dest("//evil.com/studio/chat/x") == nil
      assert ReturnTo.sanitize_dest("/admin") == nil
      assert ReturnTo.sanitize_dest("/studioevil") == nil
      assert ReturnTo.sanitize_dest("") == nil
      assert ReturnTo.sanitize_dest(nil) == nil
    end

    test "rejects dot-segment traversal (incl. %2e spellings)" do
      assert ReturnTo.sanitize_dest("/studio/chat/../../logout") == nil
      assert ReturnTo.sanitize_dest("/studio/%2e%2e/logout") == nil
    end
  end

  describe "with_return_to/2" do
    test "appends a www-form-encoded return_to when non-empty" do
      assert ReturnTo.with_return_to("/studio/chat", @scoped) ==
               "/studio/chat?return_to=" <> URI.encode_www_form(@scoped)
    end

    test "leaves the path untouched for nil/empty" do
      assert ReturnTo.with_return_to("/studio/chat", nil) == "/studio/chat"
      assert ReturnTo.with_return_to("/studio/chat", "") == "/studio/chat"
    end
  end

  # ── Layer 2: nav top-menu tabs carry (or omit) the return path ────────────

  describe "top-menu tabs (nav *_entry helpers)" do
    setup do
      enable_flat_surfaces!()
      :ok
    end

    test "a scoped surface stamps return_to=<current canonical path> on the flat tabs" do
      html =
        render_component(&BarkparkWeb.StudioComponents.Nav.studio_tabs/1,
          dataset: "production",
          scope_prefix: "/w/acme/p/site",
          admin?: true,
          current_path: @scoped
        )

      encoded = URI.encode_www_form(@scoped)
      assert html =~ ~s(href="/studio/tmux?return_to=#{encoded}")
      assert html =~ ~s(href="/studio/styleguide?return_to=#{encoded}")

      # CHAT IS NO LONGER A FLAT TAB (task-58b55b015f222b51). tmux and
      # styleguide are genuinely instance-level singletons, so their tabs stay
      # flat and rely on return_to to get you home. ChatLive is dual-mounted and
      # workspace-scoped in substance — it reads the workspace's registered
      # EXECUTION HOSTS and stamps `owner_workspace_id` on the session it
      # creates — so from a scoped surface its tab now addresses the workspace
      # the page is on, like Settings and Connectors. It keeps return_to for the
      # exit affordance; only the path gained the scope prefix.
      assert html =~ ~s(href="/w/acme/p/site/studio/chat?return_to=#{encoded}")
      refute html =~ ~s(href="/studio/chat?return_to=#{encoded}")
    end

    test "a flat surface (scope_prefix \"\") emits bare tabs — no return_to to build" do
      html =
        render_component(&BarkparkWeb.StudioComponents.Nav.studio_tabs/1,
          dataset: "production",
          scope_prefix: "",
          admin?: true,
          current_path: "/studio/chat"
        )

      assert html =~ ~s(href="/studio/chat")
      refute html =~ "return_to="
    end
  end

  describe "shared flat-surface chrome" do
    setup %{conn: conn} do
      enable_flat_surfaces!()
      {:ok, _} = Auth.create_token(@admin_token, "rt admin", "production", ["read", "admin"])
      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
    end

    test "renders exactly one scoped return control on every flat surface", %{conn: conn} do
      encoded = URI.encode_www_form(@scoped)

      for path <- ~w(/studio/chat /studio/tmux /studio/styleguide /studio/org-admin) do
        {:ok, view, html} = live(conn, "#{path}?return_to=#{encoded}")

        selector =
          ~s|a[data-test-id="return-to-scope"][href="#{@scoped}"][aria-label="Back to Studio"][title="Back to Studio"]|

        assert has_element?(view, selector)
        assert length(Regex.scan(~r/data-test-id="return-to-scope"/, html)) == 1
        assert has_element?(view, selector <> ~s| span.bp-action-icon[aria-hidden="true"] svg|)
      end
    end

    test "omits the return control when return_to is absent", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/styleguide")

      refute html =~ ~s|data-test-id="return-to-scope"|
    end

    test "omits hostile external and admin returns without reflecting attacker text", %{
      conn: conn
    } do
      for {return_to, marker} <- [
            {"https://evil.example/ATTACKER_EXTERNAL", "ATTACKER_EXTERNAL"},
            {"/admin?ATTACKER_ADMIN", "ATTACKER_ADMIN"}
          ] do
        {:ok, _view, html} =
          live(conn, "/studio/styleguide?return_to=#{URI.encode_www_form(return_to)}")

        refute html =~ ~s|data-test-id="return-to-scope"|
        refute html =~ marker
      end
    end
  end

  # ── Layer 3: the flat LiveViews thread + honor the return path ────────────

  describe "ChatLive return_to flow" do
    setup %{conn: conn} do
      {:ok, _} = Auth.create_token(@admin_token, "rt admin", "production", ["read", "admin"])
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, conn: conn}
    end

    test "disabled fallback redirects to a validated return_to instead of /studio",
         %{conn: conn} do
      set_chat!(enabled: false, command: {"cat", []})

      assert {:error, {:redirect, %{to: to}}} =
               live(conn, "/studio/chat?return_to=#{URI.encode_www_form(@scoped)}")

      assert to == @scoped
    end

    test "disabled fallback with a hostile return_to falls back to /studio", %{conn: conn} do
      set_chat!(enabled: false, command: {"cat", []})

      assert {:error, {:redirect, %{to: "/studio"}}} =
               live(conn, "/studio/chat?return_to=#{URI.encode_www_form("https://evil.com")}")
    end

    test "enabled chat threads return_to through its own session patch links", %{conn: conn} do
      set_chat!(enabled: true, command: {"cat", []})
      {:ok, _} = StudioChat.create_session(%{id: Ecto.UUID.generate(), cwd: ".", mode: "plan"})

      {:ok, view, html} =
        live(conn, "/studio/chat?return_to=#{URI.encode_www_form(@scoped)}")

      encoded = URI.encode_www_form(@scoped)
      # The "New" (new-chat) patch link and every session-row patch link carry
      # the return path forward, so navigating inside chat never loses scope.
      assert html =~ ~s(patch="/studio/chat?return_to=#{encoded}") or
               html =~ ~s(href="/studio/chat?return_to=#{encoded}")

      assert html =~ "return_to=#{encoded}"

      # Clicking "New" issues a push_patch that carries the param.
      view |> element("a.btn-primary", "New") |> render_click()
      assert_patch(view, "/studio/chat?return_to=#{encoded}")
    end

    test "enabled chat ignores a hostile return_to (no param leaks into links)", %{conn: conn} do
      set_chat!(enabled: true, command: {"cat", []})

      {:ok, _view, html} =
        live(conn, "/studio/chat?return_to=#{URI.encode_www_form("//evil.com")}")

      refute html =~ "evil.com"
      refute html =~ "return_to="
    end
  end

  describe "TmuxLive return_to flow" do
    setup %{conn: conn} do
      {:ok, _} = Auth.create_token(@admin_token, "rt admin", "production", ["read", "admin"])
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, conn: conn}
    end

    test "disabled fallback redirects to a validated return_to instead of /studio",
         %{conn: conn} do
      set_tmux!(enabled: false)

      assert {:error, {:redirect, %{to: to}}} =
               live(conn, "/studio/tmux?return_to=#{URI.encode_www_form(@scoped)}")

      assert to == @scoped
    end

    test "disabled fallback with a hostile return_to falls back to /studio", %{conn: conn} do
      set_tmux!(enabled: false)

      assert {:error, {:redirect, %{to: "/studio"}}} =
               live(conn, "/studio/tmux?return_to=#{URI.encode_www_form("/admin")}")
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp enable_flat_surfaces! do
    set_chat!(enabled: true, command: {"cat", []})
    set_tmux!(enabled: true, backend: ExPTY)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, false)
    on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, prev_demo) end)
  end

  defp set_chat!(config) do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, config)
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      restore(:claude_chat, prev)
      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)
  end

  defp set_tmux!(config) do
    prev = Application.get_env(:barkpark, :tmux_console)
    Application.put_env(:barkpark, :tmux_console, config)
    on_exit(fn -> restore(:tmux_console, prev) end)
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, prev), do: Application.put_env(:barkpark, key, prev)
end
