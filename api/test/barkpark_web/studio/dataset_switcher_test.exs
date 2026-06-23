defmodule BarkparkWeb.Studio.DatasetSwitcherTest do
  @moduledoc """
  Locks the section → URL mapping of the Studio dataset switcher.

  Four of this component's fixes were "restore /api-tester" regressions: when a
  Studio section is dropped or renamed, `section_suffix/1` silently falls through
  to the dataset root, navigating users to the wrong place — and it shipped each
  time because the component had no test. These assertions pin each section's
  suffix and the selected-option behaviour so that drift fails CI instead.
  """
  use Barkpark.DataCase, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.DatasetSwitcher

  defp markup(section, current \\ "production"),
    do: render_component(&DatasetSwitcher.switcher/1, current: current, current_section: section)

  describe "section → navigation suffix" do
    test "structure navigates to the dataset root (no subpath)" do
      html = markup(:structure)
      assert html =~ "encodeURIComponent(this.value)"
      refute html =~ "/media"
      refute html =~ "/api-tester"
    end

    test "media preserves the /media subpath" do
      assert markup(:media) =~ "/media"
    end

    test "api_tester preserves the /api-tester subpath (regressed 4×)" do
      assert markup(:api_tester) =~ "/api-tester"
    end

    test "an unknown section falls back to the dataset root, never raises" do
      html = markup(:something_new)
      assert html =~ "encodeURIComponent(this.value)"
      refute html =~ "/media"
      refute html =~ "/api-tester"
    end
  end

  describe "options" do
    test "the current dataset is the selected option" do
      # `production` is seeded by the datasets migration.
      html = markup(:structure, "production")
      assert html =~ "production"
      assert html =~ "selected"
    end
  end
end
