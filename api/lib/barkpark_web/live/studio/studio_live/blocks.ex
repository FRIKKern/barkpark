defmodule BarkparkWeb.Studio.StudioLive.Blocks do
  @moduledoc """
  Pure block-catalog helpers extracted from `BarkparkWeb.Studio.StudioLive`:
  the block-patch builders (`build_block_patch/2`), the `default_block/2`
  catalog (rich-text / visual / article-chrome / leaf `field-*` blocks), the
  MVP inline<->text converters, and the small param parsers. No socket, no
  side effects — every function here is a pure transform mirroring the block
  shapes in `Barkpark.PortableDoc.Render.compose_block/1,2`.
  """

  @doc false
  # Build the patch map for a block from the submitted form params. Only the
  # editable field(s) for that block type are included; `id`/`type` are locked
  # by patch.ex regardless. Mirrors the EXACT block shapes in
  # Barkpark.PortableDoc.Render.compose_block/1.
  def build_block_patch(%{"type" => "heading"}, params) do
    %{}
    |> put_if_present("text", params["text"])
    |> put_if_present("level", parse_level(params["level"]))
  end

  def build_block_patch(%{"type" => "paragraph"}, params) do
    %{"content" => text_to_inline(params["text"] || "")}
  end

  def build_block_patch(%{"type" => "callout"}, params) do
    %{}
    |> put_if_present("tone", params["tone"])
    # The fallback editor now owns the body through the rich WC. A chrome-only
    # form change therefore carries no `text` key and must not replace the
    # existing marked inline tree. Keep the explicit legacy text-param path so
    # older callers can still edit or clear a plain body.
    |> put_inline_text_if_present(params)
    |> put_callout_title(params["title"])
    # Unchecked checkbox sends no param → parse_bool(nil)=false (clears a prior
    # true so the toggle un-checks). Map.put = always-write semantics.
    |> Map.put("collapsible", parse_bool(params["collapsible"]))
    |> Map.put("collapsed", parse_bool(params["collapsed"]))
  end

  def build_block_patch(%{"type" => "code"}, params) do
    %{}
    |> put_if_present("lang", params["lang"])
    |> Map.put("value", params["value"] || "")
  end

  # diagram (barkpark-woxx): a Mermaid `source` textarea + an optional `caption`
  # input → the flat {source, caption} shape Render.compose_block/2 reads
  # (its `"diagram"` clause in `compose.ex`). Plain strings, no inline wrapping — the source is raw
  # Mermaid text and the caption is a short figure label.
  def build_block_patch(%{"type" => "diagram"}, params) do
    %{"source" => params["source"] || "", "caption" => params["caption"] || ""}
  end

  # ── article-chrome blocks (barkpark-54kh) ──
  # eyebrow: single text input → flat "text" string (render reads `text`).
  def build_block_patch(%{"type" => "eyebrow"}, params) do
    %{"text" => params["text"] || ""}
  end

  # byline: single text input split on " · " → "items" list (render re-joins
  # the items with " · "). Blank/whitespace segments are dropped; an empty
  # input yields [].
  def build_block_patch(%{"type" => "byline"}, params) do
    items =
      (params["text"] || "")
      |> String.split("·")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    %{"items" => items}
  end

  # ingress / pullquote: a textarea → an inline "content" array, same MVP
  # plain-text-to-inline wrapping the paragraph/callout editors use.
  def build_block_patch(%{"type" => "ingress"}, params) do
    %{"content" => text_to_inline(params["text"] || "")}
  end

  def build_block_patch(%{"type" => "pullquote"}, params) do
    %{"content" => text_to_inline(params["text"] || "")}
  end

  def build_block_patch(%{"type" => "list"}, params) do
    # Each `item-N` param is one list item's plain text. Items keep their
    # 0-based order. An ordered/unordered toggle rides in `ordered`.
    items =
      params
      |> Enum.filter(fn {k, _v} -> String.starts_with?(k, "item-") end)
      |> Enum.sort_by(fn {k, _v} -> k |> String.replace_prefix("item-", "") |> to_int(0) end)
      |> Enum.map(fn {_k, v} -> text_to_inline(v || "") end)

    %{}
    |> Map.put("items", items)
    |> put_if_present("ordered", parse_bool(params["ordered"]))
  end

  def build_block_patch(%{"type" => "section"}, params) do
    put_if_present(%{}, "title", params["title"])
  end

  # Unknown / non-editable block type (image, table, divider) → no-op patch.
  def build_block_patch(_block, _params), do: %{}

  @doc false
  # A callout title is optional; an empty string drops it back to untitled.
  def put_callout_title(patch, title) when is_binary(title) do
    case String.trim(title) do
      "" -> Map.put(patch, "title", nil)
      t -> Map.put(patch, "title", t)
    end
  end

  def put_callout_title(patch, _), do: patch

  defp put_inline_text_if_present(patch, %{"text" => text}) when is_binary(text),
    do: Map.put(patch, "content", text_to_inline(text))

  defp put_inline_text_if_present(patch, _params), do: patch

  @doc false
  def put_if_present(map, _key, nil), do: map
  def put_if_present(map, _key, ""), do: map
  def put_if_present(map, key, value), do: Map.put(map, key, value)

  @doc false
  def parse_level(nil), do: nil

  def parse_level(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n in 1..6 -> n
      _ -> nil
    end
  end

  def parse_level(_), do: nil

  @doc false
  def parse_bool("true"), do: true
  def parse_bool("on"), do: true
  def parse_bool(true), do: true
  def parse_bool(_), do: false

  @doc false
  def to_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> default
    end
  end

  def to_int(_, default), do: default

  @doc false
  # Legacy inline handling: wrap an explicitly submitted plain-text body as a
  # single text inline node. Current rich-body UI paths use the WC and submit
  # canonical inline trees directly; this remains for older form callers.
  def text_to_inline(text) when is_binary(text) do
    [%{"type" => "text", "value" => text}]
  end

  @doc false
  # Render an InlineNode array back to plain text for a textarea/input: keep
  # only text-node values (and nested children of strong/em/link), concatenated.
  # Lossy by design — the inverse of text_to_inline/1 for the MVP.
  def inline_to_text(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(&inline_node_text/1)
    |> Enum.join("")
  end

  def inline_to_text(_), do: ""

  @doc false
  def inline_node_text(%{"type" => "text", "value" => v}) when is_binary(v), do: v
  def inline_node_text(%{"value" => v}) when is_binary(v), do: v

  def inline_node_text(%{"children" => children}) when is_list(children),
    do: inline_to_text(children)

  def inline_node_text(s) when is_binary(s), do: s
  def inline_node_text(_), do: ""

  @doc false
  # Generate a short unique, immutable block id. Block ids are never reused or
  # mutated once assigned (patch.ex locks `id`).
  def new_block_id do
    "b-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))
  end

  # Find a block by id anywhere in the tree (recurses sections), so a control
  # nested inside a section still resolves its block.
  @doc false
  def find_paper_block(blocks, id) when is_list(blocks) do
    Enum.find_value(blocks, fn b ->
      cond do
        Map.get(b, "id") == id -> b
        Map.get(b, "type") == "section" -> find_paper_block(Map.get(b, "blocks", []), id)
        true -> nil
      end
    end)
  end

  def find_paper_block(_blocks, _id), do: nil

  @doc false
  # A fresh block of `type` with sensible empty defaults, in the EXACT shape
  # Render.compose_block/1 (and, for field/composite blocks, the field-block
  # editors) expect. Every type the add-block menu offers (P3.1) has a clause
  # here producing a minimal, VALID, immediately-editable block — the new id is
  # the only non-default datum. The configurable types (select / composite /
  # arrayOf / codelist / localizedText) get a minimal usable shape; real schema
  # config (option lists, subfield trees, the bound codelist, language set)
  # lands later via the Expectations layer — there is no config editor here.
  #
  # ── rich-text (Text group) ──
  def default_block("heading", id),
    do: %{"id" => id, "type" => "heading", "text" => "New heading", "level" => 2}

  def default_block("paragraph", id),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => ""}]}

  def default_block("list", id),
    do: %{
      "id" => id,
      "type" => "list",
      "ordered" => false,
      "items" => [[%{"type" => "text", "value" => ""}]]
    }

  def default_block("callout", id),
    do: %{
      "id" => id,
      "type" => "callout",
      "tone" => "info",
      "content" => [%{"type" => "text", "value" => ""}]
    }

  def default_block("code", id),
    do: %{"id" => id, "type" => "code", "lang" => "", "value" => ""}

  # ── visual blocks ──
  # diagram (barkpark-woxx): a Mermaid block. `source` is raw Mermaid text,
  # `caption` an optional figure label — the exact flat shape
  # Render.compose_block/2 reads (its `"diagram"` clause in `compose.ex`).
  # Empty defaults are valid: an
  # empty `source` renders an empty `<pre class="mermaid">`.
  def default_block("diagram", id),
    do: %{"id" => id, "type" => "diagram", "source" => "", "caption" => ""}

  # ── article-chrome blocks (render-only until now; barkpark-54kh) ──
  # These mirror the Render.compose_block/2 shapes verbatim (render.ex):
  #   eyebrow   → flat "text" string
  #   byline    → "items" list (render joins with " · ")
  #   ingress   → inline "content" array
  #   pullquote → inline "content" array (rendered italic)
  def default_block("eyebrow", id),
    do: %{"id" => id, "type" => "eyebrow", "text" => ""}

  def default_block("byline", id),
    do: %{"id" => id, "type" => "byline", "items" => []}

  def default_block("ingress", id),
    do: %{"id" => id, "type" => "ingress", "content" => []}

  def default_block("pullquote", id),
    do: %{"id" => id, "type" => "pullquote", "content" => []}

  def default_block("divider", id),
    do: %{"id" => id, "type" => "divider"}

  def default_block("section", id),
    do: %{"id" => id, "type" => "section", "title" => "New section", "blocks" => []}

  # ── canvas-insertable structural blocks (block-insertability) ──
  # These mirror the canvas slash-menu defaults (slash-insert.js canvasDefaultBlock) so
  # the LiveView add-block path and the canvas "/" pick build the SAME minimal block.
  # Each shape matches the Render.Compose.compose_block/2 clause that reads it:
  #   action   → PdButton {href, label, priority?}; empty href/label defaults.
  #   figure   → figure_html(child, caption); a caption-less figure wrapping ONE child.
  #   columns  → a list of columns, each a list of blocks; two empty columns.
  #   terminal → chrome frame over `children`; empty body (the reader renders bare chrome).
  #   table    → PdTable {rows, head?}; a headed 1-body 2-col grid with empty cells.
  def default_block("action", id),
    do: %{"id" => id, "type" => "action", "href" => "", "label" => ""}

  def default_block("figure", id),
    do: %{
      "id" => id,
      "type" => "figure",
      "child" => %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => ""}]}
    }

  def default_block("columns", id),
    do: %{"id" => id, "type" => "columns", "columns" => [[], []]}

  def default_block("terminal", id),
    do: %{"id" => id, "type" => "terminal", "children" => []}

  def default_block("table", id),
    do: %{"id" => id, "type" => "table", "head" => [[], []], "rows" => [[[], []]]}

  # ── leaf field-* blocks (P2.1) — Basic fields group ──
  # string / slug / text share the {label, value:""} shape; the field-text
  # editor also reads an optional "rows" but defaults to 3 when absent.
  def default_block("field-string", id),
    do: %{"id" => id, "type" => "field-string", "label" => "Text", "value" => ""}

  def default_block("field-slug", id),
    do: %{"id" => id, "type" => "field-slug", "label" => "Slug", "value" => ""}

  def default_block("field-text", id),
    do: %{"id" => id, "type" => "field-text", "label" => "Long text", "value" => ""}

  def default_block("field-boolean", id),
    do: %{"id" => id, "type" => "field-boolean", "label" => "Boolean", "value" => false}

  def default_block("field-datetime", id),
    do: %{"id" => id, "type" => "field-datetime", "label" => "Date & time", "value" => ""}

  def default_block("field-color", id),
    do: %{"id" => id, "type" => "field-color", "label" => "Color", "value" => "#000000"}

  def default_block("field-select", id),
    do: %{
      "id" => id,
      "type" => "field-select",
      "label" => "Select",
      "value" => "",
      "options" => [
        %{"value" => "option-1", "label" => "Option 1"},
        %{"value" => "option-2", "label" => "Option 2"}
      ]
    }

  # ── picker field-* blocks (P2.2) — Media & reference group ──
  # field-reference's refType is empty by default; the picker still browses all
  # types when ref-type is "". field-image's value is an empty image URL.
  def default_block("field-reference", id),
    do: %{
      "id" => id,
      "type" => "field-reference",
      "label" => "Reference",
      "refType" => "",
      "value" => ""
    }

  def default_block("field-image", id),
    do: %{"id" => id, "type" => "field-image", "label" => "Image", "value" => ""}

  # ── v2 composite field-* blocks (P2.3) — Structured group ──
  # composite carries an inline "fields" config (subfields use name/type/title,
  # matching PaperFieldBlock.build_subfield/1 + Render.compose_block/1) and a
  # structured map "value". arrayOf carries an "of" element descriptor + an
  # "ordered" flag + a list "value". codelist carries a (here empty) codelistId
  # + a scalar "value". localizedText carries a language set + a "format" + a
  # %{lang => text} "value".
  def default_block("composite", id),
    do: %{
      "id" => id,
      "type" => "composite",
      "label" => "Composite",
      "fields" => [%{"name" => "field1", "type" => "string", "title" => "Field 1"}],
      "value" => %{}
    }

  def default_block("arrayOf", id),
    do: %{
      "id" => id,
      "type" => "arrayOf",
      "label" => "Array",
      "of" => %{"type" => "string"},
      "ordered" => false,
      "value" => []
    }

  # codelist defaults to a REAL registered list so the picker is usable the
  # moment a block is added. `plugin` is the registry discriminator (defaults
  # to "core" in CodelistField; OnixEdit codelists live under "onixedit").
  # `variant` selects the picker UI: "flat" (default) renders CodelistField's
  # <select>/<datalist>; "tree" forces the hierarchical TreeCodelistField (see
  # PaperFieldBlock). onixedit:list_15 ("Title type", 16 flat entries) is a
  # small flat list — a clean default for the <select> path. Publishers may
  # override `codelistId`/`plugin`/`version`/`variant` per their Expectations.
  def default_block("codelist", id),
    do: %{
      "id" => id,
      "type" => "codelist",
      "label" => "Code list",
      "plugin" => "onixedit",
      "codelistId" => "onixedit:list_15",
      "version" => 73,
      "variant" => "flat",
      "value" => ""
    }

  def default_block("localizedText", id),
    do: %{
      "id" => id,
      "type" => "localizedText",
      "label" => "Localized text",
      "languages" => ["en"],
      "format" => "plain",
      "value" => %{}
    }

  def default_block(_unknown, id),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => ""}]}
end
