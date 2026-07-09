defmodule BarkparkWeb.StudioComponents.NavTest do
  @moduledoc """
  Guards the canonical Studio nav model (`default_top_menu_entries/3`,
  the sole `studio-nav-model` capability owner) and the boundary
  semantics of `plugin_tab_active?/2`. Both are pure — no Repo, no
  LiveView render — so this is a plain ExUnit case.

  Replaces the retired `BarkparkWeb.Studio.NavTest`, which pinned a dead
  `/d/:ds/studio`-shaped fork the live code never produced.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.StudioComponents.Nav

  describe "default_top_menu_entries/3 — canonical nav model" do
    test "non-admin returns exactly the three built-ins, ordered" do
      entries = Nav.default_top_menu_entries("production", "", false)

      assert Enum.map(entries, & &1.label) == ["Structure", "Media", "API"]
      assert Enum.map(entries, & &1.order) == [10, 20, 30]
      # Flat surface (empty scope prefix) uses the /studio/:ds canonical.
      assert Enum.map(entries, & &1.path) == [
               "/studio/production",
               "/studio/production/media",
               "/studio/production/api-tester"
             ]
    end

    test "admin list is a stable superset of the non-admin list" do
      non_admin = Nav.default_top_menu_entries("production", "", false)
      admin = Nav.default_top_menu_entries("production", "", true)

      # The three built-ins lead the admin list unchanged — admin gating
      # only ever APPENDS extras, never reorders or drops. (Compared on the
      # stable fields; the Structure `:active_when` regex is recompiled per
      # call so the struct isn't value-equal, but its pattern is identical.)
      identity = fn entries ->
        Enum.map(entries, &Map.take(&1, [:label, :path, :order]))
      end

      assert identity.(Enum.take(admin, 3)) == identity.(non_admin)
      assert length(admin) >= length(non_admin)

      # The unconditional admin extra (Style, order 50) is always present.
      assert Enum.any?(admin, &(&1.label == "Style" and &1.path == "/studio/styleguide"))
    end

    test "entries come out sorted by :order (non-decreasing)" do
      admin = Nav.default_top_menu_entries("production", "", true)
      orders = Enum.map(admin, & &1.order)
      assert orders == Enum.sort(orders)
    end

    test "scoped surface addresses tabs via the /d/ canonical under the scope prefix" do
      entries =
        Nav.default_top_menu_entries("production", "/w/acme/p/site", false)

      assert Enum.map(entries, & &1.path) == [
               "/w/acme/p/site/d/production/studio",
               "/w/acme/p/site/d/production/studio/media",
               "/w/acme/p/site/d/production/studio/api-tester"
             ]
    end

    test "every built-in entry carries an :active_when highlight rule" do
      for entry <- Nav.default_top_menu_entries("production", "", true) do
        assert Map.has_key?(entry, :active_when)
        refute is_nil(entry.active_when)
      end
    end
  end

  describe "plugin_tab_active?/2 — string active_when boundary match" do
    defp media_tab,
      do: %{active_when: "/studio/production/media", path: "/studio/production/media"}

    test "exact path is active" do
      assert Nav.plugin_tab_active?(media_tab(), "/studio/production/media")
    end

    test "a child under the prefix boundary is active" do
      assert Nav.plugin_tab_active?(media_tab(), "/studio/production/media/asset-123")
    end

    test "a sibling that merely shares the prefix string is NOT active" do
      # The bug this fix kills: a bare String.starts_with? lit up Media here.
      refute Nav.plugin_tab_active?(media_tab(), "/studio/production/media-library")
    end

    test "chat deep-link highlights the chat tab (boundary preserved)" do
      chat = %{active_when: "/studio/chat", path: "/studio/chat"}
      assert Nav.plugin_tab_active?(chat, "/studio/chat")
      assert Nav.plugin_tab_active?(chat, "/studio/chat/session-abc")
      # But a chat-adjacent sibling route stays inactive.
      refute Nav.plugin_tab_active?(chat, "/studio/chatterbox")
    end
  end

  describe "plugin_tab_active?/2 — regex and fallback clauses (unchanged)" do
    test "Structure regex matches the base and sub-routes but not media/api-tester" do
      [structure | _] = Nav.default_top_menu_entries("production", "", false)

      assert Nav.plugin_tab_active?(structure, "/studio/production")
      assert Nav.plugin_tab_active?(structure, "/studio/production/desk")
      refute Nav.plugin_tab_active?(structure, "/studio/production/media")
      refute Nav.plugin_tab_active?(structure, "/studio/production/api-tester")
    end

    test "with no active_when, only the exact tab.path is active" do
      tab = %{path: "/studio/production/media"}
      assert Nav.plugin_tab_active?(tab, "/studio/production/media")
      refute Nav.plugin_tab_active?(tab, "/studio/production/media/asset-1")
    end

    test "nil or empty current_path is never active" do
      refute Nav.plugin_tab_active?(media_tab(), nil)
      refute Nav.plugin_tab_active?(media_tab(), "")
    end
  end
end
