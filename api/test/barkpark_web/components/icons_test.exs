defmodule BarkparkWeb.IconsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias BarkparkWeb.Icons

  describe "icon_name/1" do
    test "maps known emoji to their icon names" do
      assert Icons.icon_name("📄") == "file-text"
      assert Icons.icon_name("📁") == "folder"
      assert Icons.icon_name("👤") == "user"
    end

    test "maps both folder emoji variants to the same icon" do
      assert Icons.icon_name("📁") == "folder"
      assert Icons.icon_name("📂") == "folder"
    end

    test "maps each desk-type emoji to its dedicated icon" do
      assert Icons.icon_name("📰") == "newspaper"
      assert Icons.icon_name("📊") == "table"
      assert Icons.icon_name("🎫") == "ticket"
      assert Icons.icon_name("🧩") == "puzzle"
      assert Icons.icon_name("🗂") == "folder-tree"
    end

    test "remaps ✅ to check-square and 📑 to sticky-note (no longer shared glyphs)" do
      assert Icons.icon_name("✅") == "check-square"
      assert Icons.icon_name("📑") == "sticky-note"
    end

    test "returns 'file' as default for unknown emoji" do
      assert Icons.icon_name("🚀") == "file"
      assert Icons.icon_name("") == "file"
      assert Icons.icon_name("not-an-emoji") == "file"
    end
  end

  describe "icon/1 component" do
    test "renders an SVG element for a known icon name" do
      html = render_component(&Icons.icon/1, name: "plus")
      assert html =~ "<svg"
      assert html =~ "M5 12h14"
    end

    test "accepts emoji name and renders the mapped icon" do
      html = render_component(&Icons.icon/1, name: "📄")
      assert html =~ "<svg"
      # file-text paths
      assert html =~ "M15 2H6"
    end

    test "raises on an unknown name in :test, naming the offender" do
      # Was: a silent fall-through to the "file" document glyph. That default
      # painted a document on the Studio back button and on the AI-not-ready
      # warning card for months without reddening anything.
      assert_raise ArgumentError, ~r/nonexistent-icon-xyz/, fn ->
        render_component(&Icons.icon/1, name: "nonexistent-icon-xyz")
      end
    end

    test "the dev/prod policy still falls back to 'file' and never raises" do
      # The raise above is gated to :test. A cosmetic glyph must never crash a
      # page, and tab_icon/1 hands icon/1 tenant-supplied strings verbatim, so
      # the :warn path has to stay total.
      paths = Icons.resolve_paths("nonexistent-icon-xyz", :warn)

      assert paths =~ "M15 2H6"
      assert paths == Icons.resolve_paths("file", :warn)
    end

    test "alert-triangle renders a warning triangle, NOT the 'file' document glyph" do
      # chat_readiness_card/1 (live/studio/chat_live.ex) asks for this by name on
      # every AI-provider-not-ready state. Before the glyph existed these two
      # renders were BYTE-IDENTICAL — the warning card painted a document.
      alert_html = render_component(&Icons.icon/1, name: "alert-triangle")
      file_html = render_component(&Icons.icon/1, name: "file")

      refute alert_html == file_html
      assert alert_html =~ "m21.73 18-8-14"
      refute alert_html =~ "M15 2H6a2 2 0 0 0-2 2v16"
    end

    test "renders a distinct non-fallback path for every new desk/top-bar glyph" do
      # {icon name, a path substring unique to that glyph and absent from 'file'}
      cases = [
        {"newspaper", "M18 14h-8"},
        {"table", "M3 15h18"},
        {"ticket", "M2 9a3 3"},
        {"puzzle", "M15.39 4.39"},
        {"folder-tree", "M3 5a2 2 0 0 0 2 2h3"},
        {"columns", "M12 3v18"},
        {"kanban", "M6 5v11"},
        {"check-square", "M21 10.5V19"},
        {"zap", "9.9-10.2"},
        {"github", "M9 18c-4.51"},
        {"clock", "12 6 12 12 16 14"},
        {"sticky-note", "M15 21v-5"},
        {"messages-square", "M20 9a2 2"}
      ]

      for {name, marker} <- cases do
        html = render_component(&Icons.icon/1, name: name)
        assert html =~ "<svg", "expected #{name} to render an svg"
        assert html =~ marker, "expected #{name} to render its own path, got fallback"
        # Prove it is NOT the 'file' fallback glyph.
        refute html =~ "M15 2H6a2 2 0 0 0-2 2v16", "#{name} fell back to the 'file' glyph"
      end
    end

    test "respects the size attribute" do
      html = render_component(&Icons.icon/1, name: "circle", size: 32)
      assert html =~ ~s(width="32")
      assert html =~ ~s(height="32")
    end
  end
end
