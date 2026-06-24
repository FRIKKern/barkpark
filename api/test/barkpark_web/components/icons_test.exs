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

    test "falls back to the 'file' icon for unknown names" do
      html = render_component(&Icons.icon/1, name: "nonexistent-icon-xyz")
      assert html =~ "<svg"
      # 'file' icon path
      assert html =~ "M15 2H6"
    end

    test "respects the size attribute" do
      html = render_component(&Icons.icon/1, name: "circle", size: 32)
      assert html =~ ~s(width="32")
      assert html =~ ~s(height="32")
    end
  end
end
