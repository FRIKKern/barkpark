defmodule Barkpark.PortableDoc.Render.Inline do
  @moduledoc """
  Inline-node composition for the PortableDoc render engine — the in-process
  twin of kernel.ts `composeInline`. Folds ProseMirror-style inline nodes and
  mark lists into Pd-tree text nodes (`PdText` / `PdInlineCode` / `PdLink`).

  Extracted verbatim from `Barkpark.PortableDoc.Render` (module location only —
  NO logic change). Self-contained: it produces Pd-tree nodes that the Walk
  family later renders; it never calls back into compose_block or walk. Output
  is byte-identical to the pre-split engine.
  """

  # ── inline walker (kernel.ts composeInline) ────────────────────────────────

  def compose_inline_children(nodes) when is_list(nodes) do
    Enum.map(nodes, &compose_inline(&1, false))
  end

  # Tolerate scalar cells (a plain string where a list of inline nodes was
  # expected — common in tables emitted by upstream converters that flatten
  # text-only cells). Treat the scalar as a single text node so the cell
  # renders as its string value instead of vanishing.
  def compose_inline_children(s) when is_binary(s), do: [s]
  def compose_inline_children(n) when is_number(n), do: [to_string(n)]
  def compose_inline_children(_), do: []

  def compose_inline(%{"type" => "text"} = n, inside_link) do
    value = Map.get(n, "value", "")

    case Map.get(n, "marks") do
      nil -> value
      [] -> value
      marks when is_list(marks) -> apply_marks(value, marks, inside_link)
      _ -> value
    end
  end

  def compose_inline(%{"type" => "strong"} = n, inside_link) do
    %{
      "kind" => "PdText",
      "weight" => "bold",
      "children" => Enum.map(Map.get(n, "children", []), &compose_inline(&1, inside_link))
    }
  end

  def compose_inline(%{"type" => "em"} = n, inside_link) do
    %{
      "kind" => "PdText",
      "italic" => true,
      "children" => Enum.map(Map.get(n, "children", []), &compose_inline(&1, inside_link))
    }
  end

  def compose_inline(%{"type" => type} = n, inside_link)
      when type in ["strikethrough", "strike", "s"] do
    %{
      "kind" => "PdText",
      "strike" => true,
      "children" => Enum.map(Map.get(n, "children", []), &compose_inline(&1, inside_link))
    }
  end

  def compose_inline(%{"type" => "underline"} = n, inside_link) do
    %{
      "kind" => "PdText",
      "underline" => true,
      "children" => Enum.map(Map.get(n, "children", []), &compose_inline(&1, inside_link))
    }
  end

  def compose_inline(%{"type" => "code"} = n, _inside_link) do
    %{"kind" => "PdInlineCode", "value" => Map.get(n, "value", "")}
  end

  def compose_inline(%{"type" => "link"} = n, inside_link) do
    children = Enum.map(Map.get(n, "children", []), &compose_inline_for_link_children(&1, true))

    if inside_link do
      # Nested link — flatten to a plain text wrapper to keep links non-recursive.
      %{"kind" => "PdText", "children" => children}
    else
      %{"kind" => "PdLink", "href" => Map.get(n, "href", ""), "children" => children}
    end
  end

  # Internal-link node kinds (storage model A — first-class AST nodes, not
  # Markdown). Targets are UNRESOLVED here; a render-time resolver task turns
  # them into hrefs/titles. Renderers degrade gracefully (raw target/name text).
  def compose_inline(%{"type" => "wikilink"} = n, inside_link) do
    children = Enum.map(Map.get(n, "children", []), &compose_inline(&1, inside_link))
    base = %{"kind" => "PdWikilink", "target" => Map.get(n, "target", ""), "children" => children}

    base =
      case Map.get(n, "alias") do
        nil -> base
        alias_val -> Map.put(base, "alias", alias_val)
      end

    # Id-pinned wikilink — the picker stamps the chosen paper's doc_id under the
    # camelCase "docId" key (JS spelling; accept "doc_id" too defensively). Carry
    # it only when present, exactly like `alias`, so a typed-not-picked wikilink
    # (no id) stays byte-identical and the walker falls back to title resolution.
    case Map.get(n, "doc_id") || Map.get(n, "docId") do
      nil -> base
      doc_id -> Map.put(base, "doc_id", doc_id)
    end
  end

  def compose_inline(%{"type" => "blockref"} = n, _inside_link) do
    %{
      "kind" => "PdBlockref",
      "target" => Map.get(n, "target", ""),
      "anchor" => Map.get(n, "anchor", "")
    }
  end

  def compose_inline(%{"type" => "tag"} = n, _inside_link) do
    %{"kind" => "PdTag", "name" => Map.get(n, "name", "")}
  end

  def compose_inline(%{"type" => type}, _inside_link) do
    raise ArgumentError, "compose_inline: unhandled inline type #{type}"
  end

  # Tolerate scalar inline nodes — upstream converters (and the list-block
  # `items: [["a"]]` shape in the public ingest contract) flatten text-only
  # inlines to bare strings/numbers. Mirrors `compose_inline_children/1`.
  def compose_inline(s, _inside_link) when is_binary(s), do: s
  def compose_inline(n, _inside_link) when is_number(n), do: to_string(n)

  # Link children are PdText | string only.
  defp compose_inline_for_link_children(node, inside_link) do
    case compose_inline(node, inside_link) do
      s when is_binary(s) -> s
      %{"kind" => "PdText"} = t -> t
      # `code` or a flattened nested link → wrap in a PdText so the type holds.
      other -> %{"kind" => "PdText", "children" => [other]}
    end
  end

  # Fold a ProseMirror-style mark list right-to-left around a text leaf,
  # so the first mark in the list ends up as the OUTERMOST wrapper (matches
  # ProseMirror's serializer order). `code` is leaf-only — it produces a
  # PdInlineCode and any remaining marks wrap that node via PdText.
  defp apply_marks(value, marks, inside_link) do
    marks
    |> Enum.reverse()
    |> Enum.reduce(value, fn mark, acc -> apply_mark(mark, acc, inside_link) end)
  end

  defp apply_mark(%{"type" => t}, acc, _il) when t in ["bold", "strong"] do
    %{"kind" => "PdText", "weight" => "bold", "children" => wrap_children(acc)}
  end

  defp apply_mark(%{"type" => t}, acc, _il) when t in ["italic", "em"] do
    %{"kind" => "PdText", "italic" => true, "children" => wrap_children(acc)}
  end

  defp apply_mark(%{"type" => "underline"}, acc, _il) do
    %{"kind" => "PdText", "underline" => true, "children" => wrap_children(acc)}
  end

  defp apply_mark(%{"type" => t}, acc, _il) when t in ["strike", "s", "strikethrough"] do
    %{"kind" => "PdText", "strike" => true, "children" => wrap_children(acc)}
  end

  defp apply_mark(%{"type" => "code"}, acc, _il) when is_binary(acc) do
    %{"kind" => "PdInlineCode", "value" => acc}
  end

  defp apply_mark(%{"type" => "code"}, acc, _il) do
    # Already wrapped by an outer mark; keep the wrapper and don't fight it.
    acc
  end

  defp apply_mark(%{"type" => "link"} = mark, acc, inside_link) do
    href = get_in(mark, ["attrs", "href"]) || Map.get(mark, "href", "")
    children = wrap_children(acc) |> Enum.map(&link_child(&1, true))

    if inside_link do
      # Mirror the nested-link clause in compose_inline/2 — flatten to PdText.
      %{"kind" => "PdText", "children" => children}
    else
      %{"kind" => "PdLink", "href" => href, "children" => children}
    end
  end

  defp apply_mark(%{"type" => "wikilink"} = mark, acc, _il) do
    base = %{
      "kind" => "PdWikilink",
      "target" => get_in(mark, ["attrs", "target"]) || "",
      "children" => wrap_children(acc)
    }

    base =
      case get_in(mark, ["attrs", "alias"]) do
        nil -> base
        alias_val -> Map.put(base, "alias", alias_val)
      end

    # Carry the id-pinned doc_id off the mark attrs (TipTap stamps "docId";
    # accept "doc_id" too), only when present — mirrors the node clause above.
    case get_in(mark, ["attrs", "doc_id"]) || get_in(mark, ["attrs", "docId"]) do
      nil -> base
      doc_id -> Map.put(base, "doc_id", doc_id)
    end
  end

  defp apply_mark(%{"type" => "blockref"} = mark, _acc, _il) do
    # Read target/anchor from attrs ONLY — the text leaf carries the "^anchor"
    # DISPLAY token, never the bare anchor (must NOT fall back to acc).
    %{
      "kind" => "PdBlockref",
      "target" => get_in(mark, ["attrs", "target"]) || "",
      "anchor" => get_in(mark, ["attrs", "anchor"]) || ""
    }
  end

  defp apply_mark(%{"type" => "tag"} = mark, _acc, _il) do
    %{"kind" => "PdTag", "name" => get_in(mark, ["attrs", "name"]) || ""}
  end

  # Unknown marks pass through (no wrapper).
  defp apply_mark(_unknown, acc, _il), do: acc

  defp wrap_children(acc) when is_binary(acc), do: [acc]
  defp wrap_children(acc) when is_list(acc), do: acc
  defp wrap_children(acc), do: [acc]

  defp link_child(s, _il) when is_binary(s), do: s
  defp link_child(%{"kind" => "PdText"} = t, _il), do: t
  defp link_child(other, _il), do: %{"kind" => "PdText", "children" => [other]}

  @doc """
  Coerce an inline child into a Pd-node for table cells.
  """
  def to_pd_node_from_inline_child(child) when is_binary(child) do
    %{"kind" => "PdText", "children" => [child]}
  end

  def to_pd_node_from_inline_child(child), do: child
end
