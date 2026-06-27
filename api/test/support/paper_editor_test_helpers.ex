defmodule BarkparkWeb.PaperEditorTestHelpers do
  @moduledoc """
  Shared test surface for the in-Studio paper BLOCK EDITOR feature suite.

  The paper-editor tests were originally one 1698-line god-test-module. They
  were split into FOCUSED per-feature ExUnit modules (one file per feature
  family) that all reuse the SAME base fixtures + edit-mode entry point. This
  module is the home of that shared surface — the only helpers called from more
  than one feature file:

    * `@dataset` / `@slug` module attrs (the base paper every file mounts).
    * `seed_paper_schema!/0` + `seed_block_paper!/0` — the `setup` fixtures.
    * `open_editor/1` — flips the pane into edit mode and asserts the editor
      controls rendered.

  Every feature file does:

      use BarkparkWeb.ConnCase, async: false
      use BarkparkWeb.PaperEditorTestHelpers

  …which brings in `Phoenix.LiveViewTest`, the `Content` / `Paper` aliases, the
  `@dataset` / `@slug` attrs, the shared `setup` (seeds the base paper schema +
  paper), and the `seed_paper_schema!/0`, `seed_block_paper!/0`, `open_editor/1`
  helpers. Section-LOCAL seed helpers (e.g. `seed_field_paper!`,
  `seed_composite_paper!`) stay in the feature file that uses them.

  Every assertion across the suite drives the LiveView through the real
  Content + PubSub spine; nothing bypasses `Content.apply_paper_block_op/3`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.LiveViewTest

      alias Barkpark.Content
      alias BarkparkWeb.Studio.StudioLive.Handlers.Paper

      import BarkparkWeb.PaperEditorTestHelpers

      @dataset "production"
      @slug "2026-05-24-editor-paper"

      setup do
        seed_paper_schema!()
        seed_block_paper!()
        :ok
      end
    end
  end

  @dataset "production"
  @slug "2026-05-24-editor-paper"

  @doc """
  Seed the minimal `paper` schema in the `production` dataset.
  """
  def seed_paper_schema! do
    {:ok, _} =
      Barkpark.Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "icon" => "📰",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  @doc """
  Seed the base 3-block paper (`heading`, two `paragraph`s) every feature file
  mounts as its default editor target.
  """
  def seed_block_paper! do
    blocks = [
      %{"id" => "h-1", "type" => "heading", "text" => "Editor Paper", "level" => 1},
      %{
        "id" => "p-intro",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Original intro text."}]
      },
      %{
        "id" => "p-second",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Second paragraph."}]
      }
    ]

    {:ok, paper} =
      Barkpark.Content.upsert_paper(%{slug: @slug, dataset: @dataset, blocks: blocks})

    paper
  end

  @doc """
  Flip the LiveView into edit mode; assert the edit controls render. Returns
  the rendered edit-mode HTML.
  """
  def open_editor(view) do
    # Flip into edit mode; assert the edit controls render.
    html =
      view
      |> Phoenix.LiveViewTest.element(~s([data-test-id="paper-edit-toggle"]))
      |> Phoenix.LiveViewTest.render_click()

    ExUnit.Assertions.assert(html =~ ~s(data-test-id="studio-paper-block-editor"))
    html
  end
end
