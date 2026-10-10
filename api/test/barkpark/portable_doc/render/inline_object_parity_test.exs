defmodule Barkpark.PortableDoc.Render.InlineObjectParityTest do
  @moduledoc """
  The Elixir leg of the inline object parity lock (task-85fee859cf3bfef6).

  An inline object is a childless inline node `{type, ...fields}` with no
  built-in renderer, such as a schema's `blocks.inline` type. Three engines
  render it and read ONE fixture, `api/test/support/fixtures/inline-object-text.json`:

    Elixir  render/inline.ex `inline_object_text/1`, render/walk.ex — tested HERE
    JS      js/packages/react/src/inline.tsx `inlineObjectText`
            — js/packages/react/tests/inline-object.parity.test.ts
    Go      internal/pdrender/inline.go `inlineObjectText`
            — internal/pdrender/inline_object_parity_test.go

  Before this, every engine rendered such a node as nothing, so post-11's
  Sanity chip read "Status , written with Ada."
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Inline

  @fixture Path.expand("../../../support/fixtures/inline-object-text.json", __DIR__)

  setup_all do
    %{"cases" => cases} = @fixture |> File.read!() |> Jason.decode!()
    # A shrunken fixture would make every assertion below pass vacuously.
    assert length(cases) >= 10
    {:ok, cases: cases}
  end

  defp para(node),
    do: %{
      "id" => "p1",
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => "A "}, node]
    }

  defp render(block, opts \\ %{}), do: Render.render_block(block, Map.put(opts, :style, :article))

  test "every fixture case yields its recorded text", %{cases: cases} do
    for %{"name" => name, "node" => node, "text" => expected} <- cases do
      assert Inline.inline_object_text(node) == expected, "text disagreed for: #{name}"
    end
  end

  test "a node with text renders the span; one without renders nothing", %{cases: cases} do
    for %{"name" => name, "node" => node, "text" => text} <- cases do
      html = render(para(node))

      span =
        ~s(<span class="bp-inline-object" data-inline-type="#{node["type"]}">) <>
          Render.escape_html(text) <> "</span>"

      if text == "" do
        refute html =~ "bp-inline-object", "a textless node rendered a span for: #{name}"
      else
        assert html =~ span, "missing span for #{name}: #{html}"
      end
    end
  end

  test "markup in the text is escaped" do
    html = render(para(%{"type" => "mention", "text" => "<b>x</b>"}))
    assert html =~ "&lt;b&gt;x&lt;/b&gt;"
    refute html =~ "<b>x</b>"
  end

  test "a registered renderer gets the stored node and owns the markup" do
    node = %{"type" => "status", "text" => "Reviewed", "tone" => "positive"}

    render_status = fn n ->
      ~s(<mark data-tone="#{Render.escape_html(n["tone"])}">#{Render.escape_html(n["text"])}</mark>)
    end

    html = render(para(node), %{inline_objects: %{"status" => render_status}})
    assert html =~ ~s(<mark data-tone="positive">Reviewed</mark>)
    refute html =~ "bp-inline-object"
  end

  test "a registered renderer that raises falls back to the span" do
    node = %{"type" => "status", "text" => "Reviewed"}
    boom = fn _ -> raise "boom" end

    html = render(para(node), %{inline_objects: %{"status" => boom}})
    assert html =~ ~s(<span class="bp-inline-object" data-inline-type="status">Reviewed</span>)
  end

  test "built-in inline types keep their own renderers" do
    html = render(para(%{"type" => "chip", "text" => "Reviewed", "tone" => "success"}))
    assert html =~ "bp-chip"
    refute html =~ "bp-inline-object"
  end
end
