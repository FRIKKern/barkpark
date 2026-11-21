defmodule Barkpark.PortableDoc.Render.Callout do
  @moduledoc """
  A callout's Pd node, for `Render.Compose.compose_block/2`'s callout clause.

  A callout's words are its content (else its text), then every block of its body
  slot, in that order (api/assets/paper-editor/src/markdown/callout-words.js;
  task-e70b11497064225b). The first line is one inline `PdText`, as it always was.
  Each body block is composed by `Compose.compose_block/2`, the same function that
  composes a top-level block, so a list, a table or a callout in a body shows whole.
  A callout with no body composes the one `PdText` it always did (byte-identical); one
  with a body and no first-line words leaves the empty `PdText` out.
  """

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.{Compose, Inline}
  alias Barkpark.PortableDoc.Slots

  @spec compose(map(), atom()) :: map()
  def compose(b, style) do
    head = %{
      "kind" => "PdText",
      "children" => Inline.compose_inline_children(Slots.callout_head_inline(b))
    }

    children =
      case Slots.callout_body_blocks(b) do
        [] ->
          [head]

        blocks ->
          composed = Enum.map(blocks, &compose_body_block(&1, b, style))
          if head["children"] == [], do: composed, else: [head | composed]
      end

    base =
      %{"kind" => "PdCallout", "tone" => Map.get(b, "tone") || "info", "children" => children}
      |> maybe_put("title", Map.get(b, "title"))

    # Collapse is a SCREEN-only affordance: thread collapsible/collapsed ONLY in
    # article mode (and only when `true`) so the email renderer — which shares
    # walk.ex callout/3 — always emits the expanded <div>. Email clients strip
    # <details> and would HIDE the body (the opposite of degrade-to-expanded).
    # Skipping non-true also keeps existing callouts byte-identical at the Pd
    # level, even after a re-save that writes an explicit collapsible:false.
    if style == :article do
      base
      |> maybe_put_true("collapsible", Map.get(b, "collapsible"))
      |> maybe_put_true("collapsed", Map.get(b, "collapsed"))
    else
      base
    end
  end

  # A body block composes as a top-level block does. With the callout's carried
  # render options (Render.prepare_block/2) it gets the same pre-pass first, as a
  # section's stack children do.
  defp compose_body_block(block, callout, style) do
    case Compose.render_opts(callout) do
      nil -> Compose.compose_block(block, style)
      opts -> Compose.compose_block(Render.prepare_block(block, opts), style)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Writes ONLY when the value is exactly `true`, so a boolean attr's absence and an
  # explicit `false` render identically (an un-folded callout keeps its bytes).
  defp maybe_put_true(map, key, true), do: Map.put(map, key, true)
  defp maybe_put_true(map, _key, _value), do: map
end
