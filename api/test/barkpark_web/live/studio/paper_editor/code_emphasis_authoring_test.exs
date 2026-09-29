defmodule BarkparkWeb.Studio.PaperEditor.CodeEmphasisAuthoringTest do
  @moduledoc """
  task-33af97d6c80cbe72 — the Studio authoring affordance for a code block's
  LINE-EMPHASIS ranges.

  Two properties, one per acceptance criterion:

    1. An author can SET and CLEAR comment/offending/fixed ranges from the
       editor without hand-editing JSON, and the saved block round-trips through
       the SAME `emphasis` field the renderers read
       (`Render.Compose.code_emphasis/1` → `Render.Figures.code_block_html/2`).

    2. View and Edit render the emphasised lines IDENTICALLY. The edit control is
       a `<textarea>` (no per-line DOM, so it can never paint the spans), so the
       edit surface carries a PREVIEW rendered by the SAME producer the reader
       uses — `Render.render_block(block, %{style: :article})` — inside the
       Studio shell, which is a `.bp-paper-surface` sink. The test asserts the
       editor's own bytes CONTAIN the reader's bytes, spans and tones included.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Compose
  alias Barkpark.PortableDoc.Render.Figures
  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  @value "alpha\nbravo\ncharlie\ndelta"

  defp code(emphasis) when is_list(emphasis),
    do: %{
      "id" => "c1",
      "type" => "code",
      "lang" => "elixir",
      "value" => @value,
      "emphasis" => emphasis
    }

  defp code_without_emphasis,
    do: %{"id" => "c1", "type" => "code", "lang" => "elixir", "value" => @value}

  # The wire a real submit carries: the body form fields PLUS one triple per
  # stored range (the shape paper_editor.ex emits).
  defp wire(ranges, extra \\ %{}) do
    base = %{
      "block_id" => "c1",
      "lang" => "elixir",
      "value" => @value,
      "emphasis-count" => Integer.to_string(length(ranges))
    }

    ranges
    |> Enum.with_index()
    |> Enum.reduce(base, fn {{from, to, tone}, i}, acc ->
      acc
      |> Map.put("emphasis-#{i}-from", from)
      |> Map.put("emphasis-#{i}-to", to)
      |> Map.put("emphasis-#{i}-tone", tone)
    end)
    |> Map.merge(extra)
  end

  defp apply_patch(block, params) do
    {:ok, patch} = Blocks.validate_block_patch(block, params)
    Map.merge(block, patch)
  end

  describe "criterion 1 — set and clear ranges without hand-editing JSON" do
    test "the add action appends a live default range the renderers accept" do
      block = code_without_emphasis()

      saved = apply_patch(block, wire([], %{"emphasis-action" => "add"}))

      assert saved["emphasis"] == [%{"from" => 1, "to" => 1, "tone" => "comment"}]
      # The default is not merely stored — it SURVIVES the renderer's normalizer,
      # so "Add range" can never mint a range that silently drops.
      assert Compose.code_emphasis(saved) == [{1, 1, "comment"}]
      assert saved["value"] == @value
    end

    test "editing from/to/tone writes the same field the renderers read" do
      block = code([%{"from" => 1, "to" => 1, "tone" => "comment"}])

      saved = apply_patch(block, wire([{"2", "3", "offending"}]))

      assert saved["emphasis"] == [%{"from" => 2, "to" => 3, "tone" => "offending"}]
      assert Compose.code_emphasis(saved) == [{2, 3, "offending"}]

      assert Figures.code_block_html(saved["value"], Compose.code_emphasis(saved)) =~
               ~s|<span class="bp-code-em bp-code-em--offending">bravo</span>|
    end

    test "all three tones round-trip" do
      for tone <- ~w(comment offending fixed) do
        block = code([%{"from" => 1, "to" => 1, "tone" => "comment"}])
        saved = apply_patch(block, wire([{"4", "4", tone}]))
        assert Compose.code_emphasis(saved) == [{4, 4, tone}]
      end
    end

    test "the remove action clears a range back to the legacy render" do
      block = code([%{"from" => 2, "to" => 3, "tone" => "offending"}])

      saved =
        apply_patch(block, wire([{"2", "3", "offending"}], %{"emphasis-action" => "remove:0"}))

      assert saved["emphasis"] == []
      assert Compose.code_emphasis(saved) == []
      # Cleared means BYTE-identical to a block that never had the field.
      assert Figures.code_block_html(saved["value"], Compose.code_emphasis(saved)) ==
               Figures.code_block_html(@value, [])
    end

    test "a tone outside the closed vocabulary is refused, never stored" do
      block = code([%{"from" => 1, "to" => 1, "tone" => "comment"}])

      assert {:error, {:invalid_option, "emphasis"}} =
               Blocks.validate_block_patch(block, wire([{"1", "1", "onclick=x"}]))

      # Second door: even a direct patch build cannot smuggle the tone in.
      patch = Blocks.build_block_patch(block, wire([{"1", "1", "onclick=x"}]))

      assert patch["emphasis"] == nil or
               patch["emphasis"] == [%{"from" => 1, "to" => 1, "tone" => "comment"}]
    end

    test "a non-integer line is refused and a stale row count is refused" do
      block = code([%{"from" => 1, "to" => 1, "tone" => "comment"}])

      assert {:error, {:invalid_number, "emphasis"}} =
               Blocks.validate_block_patch(block, wire([{"zero", "1", "comment"}]))

      stale = wire([{"1", "1", "comment"}]) |> Map.put("emphasis-count", "2")

      assert {:error, {:malformed_collection, "emphasis"}} =
               Blocks.validate_block_patch(block, stale)
    end

    test "a body-only submit (no emphasis form) leaves stored ranges untouched" do
      block = code([%{"from" => 2, "to" => 3, "tone" => "fixed"}])

      patch =
        Blocks.build_block_patch(block, %{"block_id" => "c1", "lang" => "elixir", "value" => "x"})

      refute Map.has_key?(patch, "emphasis")
      assert Map.merge(block, patch)["emphasis"] == [%{"from" => 2, "to" => 3, "tone" => "fixed"}]
    end
  end

  describe "criterion 2 — View and Edit render the emphasised lines identically" do
    test "the editor's code preview carries the reader's own span bytes" do
      block =
        code([
          %{"from" => 2, "to" => 3, "tone" => "offending"},
          %{"from" => 4, "tone" => "fixed"}
        ])

      reader = Render.render_block(block, %{style: :article})
      editor = render_editor(block)

      # The span class + tone the reader emits, present verbatim in the editor.
      assert reader =~ ~s|<span class="bp-code-em bp-code-em--offending">bravo</span>|
      assert reader =~ ~s|<span class="bp-code-em bp-code-em--fixed">delta</span>|

      # ONE PRODUCER: the editor does not hand-mirror the markup, it contains the
      # reader's bytes. If the preview were dropped or re-implemented, this fails.
      assert editor =~ reader
    end

    test "a block with no live range previews byte-identically to a field-less one" do
      with_field = code([%{"from" => 0, "tone" => "comment"}])
      without = code_without_emphasis()

      assert Render.render_block(with_field, %{style: :article}) ==
               Render.render_block(without, %{style: :article})
    end

    test "the editor exposes the range controls and the closed tone vocabulary" do
      html = render_editor(code([%{"from" => 2, "to" => 3, "tone" => "offending"}]))
      doc = LazyHTML.from_fragment(html)

      names =
        LazyHTML.attribute(
          LazyHTML.query(doc, "input[name], textarea[name], select[name]"),
          "name"
        )

      assert names == [
               "block_id",
               "lang",
               "value",
               "emphasis-count",
               "emphasis-0-from",
               "emphasis-0-to",
               "emphasis-0-tone"
             ]

      assert LazyHTML.attribute(
               LazyHTML.query(doc, ~s(select[name="emphasis-0-tone"] option)),
               "value"
             ) ==
               Blocks.code_emphasis_tones()

      assert Enum.count(LazyHTML.query(doc, ~s([data-test-id="paper-code-emphasis-add"]))) == 1
      assert Enum.count(LazyHTML.query(doc, ~s([data-test-id="paper-code-emphasis-remove"]))) == 1
      # The body textarea keeps its identity — the emphasis rows ride the SAME form.
      assert Enum.count(
               LazyHTML.query(doc, ~s(form#code-form-c1 [data-test-id="paper-field-value"]))
             ) == 1

      assert Enum.count(LazyHTML.query(doc, ~s(form#code-form-c1 [name="emphasis-0-tone"]))) == 1
    end
  end

  defp render_editor(block) do
    render_component(&PaperEditor.paper_block_fields/1, block: block)
  end
end
