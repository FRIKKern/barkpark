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

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Repo
  alias BarkparkWeb.Studio.DatasetSwitcher

  # A second dataset this test OWNS, so the selected-option assertions below
  # always have a non-current row to be wrong about. Without one, an inverted
  # or always-on `selected` is unobservable: a one-option select looks the same
  # either way.
  @alt_dataset "w7-selected-option-alt"

  defp markup(section, current \\ "production"),
    do: render_component(&DatasetSwitcher.switcher/1, current: current, current_section: section)

  # Bind `selected` to the option it sits on. `assert html =~ "selected"` is a
  # substring search over the whole render and is true for EVERY assignment of
  # the attribute, including "all options selected" and "exactly the wrong
  # options selected" — both of which ship a browser that lands the operator on
  # a dataset they are not looking at.
  defp option_values(html),
    do:
      html |> LazyHTML.from_fragment() |> LazyHTML.query("option") |> LazyHTML.attribute("value")

  defp selected_option_values(html),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("option[selected]")
      |> LazyHTML.attribute("value")

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
    setup do
      # Give the catalog a second, test-owned dataset. `Content.list_datasets/1`
      # derives the catalog from schema rows in the default project, so this one
      # row puts a non-current option in the select for every test below.
      Repo.insert!(%SchemaDefinition{
        name: "w7SelectedOptionAlt",
        title: "W7 Selected Option Alt",
        dataset: @alt_dataset,
        project_id: Content.read_default_project_id()
      })

      :ok
    end

    test "the fixture really offers a non-current dataset to be wrong about" do
      values = option_values(markup(:structure, "production"))
      assert "production" in values
      assert @alt_dataset in values
    end

    # Purely NEGATIVE, so it is disjoint from the positive test below: an
    # always-off `selected` passes here and fails there, and vice versa.
    test "no dataset other than the current one is selected" do
      selected = selected_option_values(markup(:structure, "production"))
      strays = selected -- ["production"]

      assert strays == [],
             "only the current dataset's <option> may carry `selected`; also selected: #{inspect(strays)}"
    end

    test "the current dataset's option is the one that carries `selected`" do
      html = markup(:structure, @alt_dataset)

      assert @alt_dataset in selected_option_values(html),
             "the current dataset's <option> lost its `selected` attribute; selected: " <>
               inspect(selected_option_values(html))
    end
  end
end
