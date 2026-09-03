defmodule Barkpark.PortableDoc.Bpml.Parser do
  @moduledoc """
  BPML → blocks. The strict half of the isomorphism in
  `Barkpark.PortableDoc.Bpml`: a hand-rolled recursive-descent parser that
  tracks line numbers and turns every wrong guess into a teaching error —
  unknown tags suggest the intended block, HTML-isms (`<div>`, `class=`)
  explain the BPML way, and errors are COLLECTED across sibling blocks
  (validate-all spirit), not just the first one hit. Pure; no Repo, no I/O.
  """

  @block_attrs %{
    "paper" => ~w(slug title),
    "section" => ~w(id title variant),
    "callout" => ~w(id tone title),
    "diagram" => ~w(id caption),
    "route" => ~w(id sport distance elevation duration caption),
    "code" => ~w(id),
    "eyebrow" => ~w(id),
    "p" => ~w(id),
    "pullquote" => ~w(id),
    "ingress" => ~w(id),
    "byline" => ~w(id),
    "ul" => ~w(id),
    "stats" => ~w(id),
    "steps" => ~w(id),
    "table" => ~w(id),
    "h1" => ~w(id),
    "h2" => ~w(id),
    "h3" => ~w(id),
    "notes" => ~w(id),
    "note" => ~w(id label lead),
    "stat" => ~w(label value denom caption note),
    # The grid/widget tier (task-3b08cbd8a16ad48e criterion 1) — the corpus's
    # biggest unspellable types and their child elements. `stat` above is
    # SHARED by <stats> and <stat-grid>: the renderer composes both through one
    # clause (compose.ex `t in ["stats", "stat-grid"]`), so one element spells
    # both, and `caption`/`note` are the two attrs only the grid uses today.
    "paper-links" => ~w(id title description layout),
    "ref" => ~w(slug title eyebrow meta reason featured prefer_authored_copy),
    "cards" => ~w(id),
    "card" => ~w(title tone),
    "terminal" => ~w(id title footer live),
    "action" => ~w(id label href priority),
    "pipeline" => ~w(id),
    "node" => ~w(title kind source files),
    "stat-grid" => ~w(id),
    "blockquote" => ~w(id cite),
    "toc" => ~w(id depth numbered),
    "entry" => ~w(level anchor),
    "bar-chart" => ~w(id values),
    "bar" => ~w(label value),
    "lineage" => ~w(id),
    "lineage-node" => ~w(title overline source),
    "chart" => ~w(id kind caption min max xlabels),
    "series" => ~w(label),
    "step" => ~w(title),
    "tag" => ~w(tag strength),
    "item" => [],
    "li" => [],
    "tr" => [],
    "th" => [],
    "td" => [],
    "meta" => [],
    "description" => [],
    "a" => ~w(href),
    "hr" => ~w(id),
    "expandable" => ~w(id summary)
  }

  @unknown_tag_hints %{
    "div" => "BPML has no generic containers — group content with <section title=\"…\">",
    "main" => "BPML has no generic containers — group content with <section title=\"…\">",
    "article" => "the document root is <paper>; inside it, group with <section>",
    "aside" => "use <callout tone=\"info\"> for side notes",
    "span" => "plain text needs no wrapper; use <b>/<i>/<code> for emphasis",
    "br" => "line breaks are separate <p> blocks",
    "img" => "the image block is not in the BPML kernel yet",
    "h4" => "headings stop at <h3>",
    "h5" => "headings stop at <h3>",
    "h6" => "headings stop at <h3>",
    "ol" => "ordered lists are not in the BPML kernel yet — use <ul>",
    "em" => "<em>/<i> are inline — valid only inside a text-bearing element like <p>",
    "strong" => "<strong>/<b> are inline — valid only inside a text-bearing element like <p>"
  }

  @known_block_tags ~w(section p pullquote ingress eyebrow h1 h2 h3 byline ul table code diagram route stats notes note steps callout hr expandable paper-links cards terminal action pipeline stat-grid blockquote toc bar-chart lineage chart)

  @inline_marks %{
    "b" => "strong",
    "strong" => "strong",
    "i" => "em",
    "em" => "em",
    "code" => "code",
    "u" => "underline",
    "s" => "strike"
  }

  # ── public ──────────────────────────────────────────────────────────────────

  @doc "The tag → allowed-attributes table (the grammar's attribute contract)."
  def block_attrs, do: @block_attrs

  @doc "Block tags valid at document level."
  def known_block_tags, do: @known_block_tags

  @doc "Inline tag → mark name (aliases included: strong→strong, b→strong…)."
  def inline_marks, do: @inline_marks

  def parse_blocks(bpml) when is_binary(bpml) do
    {blocks, errors, _cur} = block_seq({bpml, 1}, nil)
    finish(blocks, errors)
  end

  def parse_paper(bpml) when is_binary(bpml) do
    cur = skip_ws({bpml, 1})

    case open_tag(cur) do
      {:ok, "paper", attrs, false, cur} ->
        case check_attrs("paper", attrs, line(cur)) do
          [] ->
            {meta, meta_errors, cur} = maybe_meta(cur)
            {blocks, errors, cur} = block_seq(cur, "paper")
            {errors, _cur} = expect_close("paper", cur, errors)

            paper =
              %{"blocks" => blocks}
              |> put_attr("slug", attrs)
              |> put_attr("title", attrs)
              |> Map.merge(meta)

            case finish(paper, meta_errors ++ errors) do
              {:ok, paper} -> {:ok, paper}
              other -> other
            end

          attr_errors ->
            {:error, attr_errors}
        end

      {:ok, other, _attrs, _sc, cur} ->
        {:error,
         [
           err(
             "unknown-root",
             "document root must be <paper>, found <#{other}>",
             line(cur),
             "wrap the document in <paper slug=\"…\" title=\"…\">"
           )
         ]}

      {:error, e} ->
        {:error, [e]}
    end
  end

  defp finish(result, []), do: {:ok, result}
  defp finish(_result, errors), do: {:error, Enum.reverse(errors)}

  # ── block sequence (inside <paper>, <section>, or at top level) ─────────────

  defp block_seq(cur, parent), do: block_seq(cur, parent, [], [])

  defp block_seq(cur, parent, blocks, errors) do
    cur = skip_ws(cur)

    case peek(cur) do
      :eof ->
        {Enum.reverse(blocks), errors, cur}

      :close ->
        {Enum.reverse(blocks), errors, cur}

      :tag ->
        case block_element(cur) do
          {:ok, block, cur} -> block_seq(cur, parent, [block | blocks], errors)
          {:skip, more_errors, cur} -> block_seq(cur, parent, blocks, more_errors ++ errors)
        end

      :text ->
        {_text, cur2} = raw_text(cur)

        e =
          err(
            "stray-text",
            "text outside a text-bearing element",
            line(cur),
            "prose lives inside <p>…</p> (or another text-bearing tag)"
          )

        block_seq(cur2, parent, blocks, [e | errors])
    end
  end

  # ── one block element ───────────────────────────────────────────────────────

  defp block_element(cur) do
    case open_tag(cur) do
      {:error, e} -> {:skip, [e], skip_to_next_tag(cur)}
      {:ok, tag, attrs, self_closed, cur2} -> block_element(tag, attrs, self_closed, cur, cur2)
    end
  end

  defp block_element(tag, attrs, self_closed, cur, cur2) do
    cond do
      tag in @known_block_tags ->
        case check_attrs(tag, attrs, line(cur)) do
          [] -> build_block(tag, attrs, self_closed, cur2)
          attr_errors -> {:skip, attr_errors, consume_element(tag, self_closed, cur2)}
        end

      true ->
        hint =
          Map.get(@unknown_tag_hints, tag) ||
            "known block tags: " <> Enum.join(@known_block_tags, ", ")

        e = err("unknown-tag", "unknown tag <#{tag}>", line(cur), hint)
        {:skip, [e], consume_element(tag, self_closed, cur2)}
    end
  end

  defp build_block("eyebrow", attrs, sc, cur),
    do: text_block("eyebrow", %{"type" => "eyebrow"}, attrs, sc, cur)

  defp build_block(<<"h", l>>, attrs, sc, cur) when l in ?1..?3 do
    base = %{"type" => "heading", "level" => l - ?0}
    text_block(<<"h", l>>, base, attrs, sc, cur, "text")
  end

  defp build_block("code", attrs, sc, cur) do
    with {:ok, text, cur} <- tag_text("code", sc, cur) do
      {:ok, %{"type" => "code", "value" => text} |> put_attr("id", attrs), cur}
    end
  end

  defp build_block("diagram", attrs, sc, cur) do
    with {:ok, text, cur} <- tag_text("diagram", sc, cur) do
      block =
        %{"type" => "diagram", "source" => text}
        |> put_attr("id", attrs)
        |> put_attr("caption", attrs)

      {:ok, block, cur}
    end
  end

  # `route` (sport track): the body is the encoded polyline — opaque data like
  # a diagram's mermaid source; whitespace is trimmed (the polyline alphabet is
  # ASCII 63–126, so indentation can never be data).
  defp build_block("route", attrs, sc, cur) do
    with {:ok, text, cur} <- tag_text("route", sc, cur) do
      block =
        %{"type" => "route", "polyline" => String.trim(text)}
        |> put_attr("id", attrs)
        |> put_attr("sport", attrs)
        |> put_attr("distance", attrs)
        |> put_attr("elevation", attrs)
        |> put_attr("duration", attrs)
        |> put_attr("caption", attrs)

      {:ok, block, cur}
    end
  end

  defp build_block(tag, attrs, sc, cur) when tag in ["p", "pullquote", "ingress"] do
    type = if tag == "p", do: "paragraph", else: tag

    with {:ok, nodes, cur} <- tag_inline(tag, sc, cur) do
      {:ok, %{"type" => type, "content" => nodes} |> put_attr("id", attrs), cur}
    end
  end

  defp build_block("callout", attrs, sc, cur) do
    with {:ok, nodes, cur} <- tag_inline("callout", sc, cur) do
      block =
        %{"type" => "callout", "content" => nodes}
        |> put_attr("id", attrs)
        |> put_attr("tone", attrs)
        |> put_attr("title", attrs)

      {:ok, block, cur}
    end
  end

  defp build_block("byline", attrs, sc, cur) do
    with {:ok, items, cur} <-
           child_seq("byline", "item", sc, cur, fn _attrs, sc, cur ->
             tag_text("item", sc, cur)
           end) do
      {:ok, %{"type" => "byline", "items" => items} |> put_attr("id", attrs), cur}
    end
  end

  defp build_block("ul", attrs, sc, cur) do
    with {:ok, items, cur} <-
           child_seq("ul", "li", sc, cur, fn _attrs, sc, cur -> tag_inline("li", sc, cur) end) do
      {:ok, %{"type" => "list", "items" => items} |> put_attr("id", attrs), cur}
    end
  end

  defp build_block("stats", attrs, sc, cur) do
    with {:ok, items, cur} <- child_seq("stats", "stat", sc, cur, &stat_item_builder/3) do
      {:ok, %{"type" => "stats", "items" => items} |> put_attr("id", attrs), cur}
    end
  end

  # The notes grid mirrors `stats`: a `<notes>` holds N `<note>` children, each
  # carrying id/label/lead attrs and a plain-text body. The body maps to the key
  # `text` — the legacy `notes` item vocab (slots.ex legacy_slot body→flat
  # `text`); a `body` key would render every note EMPTY on web + TUI. Empty text
  # is dropped, so canonical items are `{label, lead, text}` (id present-only).
  defp build_block("notes", attrs, sc, cur) do
    with {:ok, items, cur} <- child_seq("notes", "note", sc, cur, &note_item_builder/3) do
      {:ok, %{"type" => "notes", "items" => items} |> put_attr("id", attrs), cur}
    end
  end

  # The singular `note` widget (composition-doctrine split): the editable per-item
  # twin of ONE `notes` grid item, promoted to a block with `"type" => "note"`.
  # Same attrs and the same `text` body key as a grid item.
  defp build_block("note", attrs, sc, cur) do
    with {:ok, item, cur} <- note_item_builder(attrs, sc, cur) do
      {:ok, Map.put(item, "type", "note"), cur}
    end
  end

  # ── the grid/widget tier (task-3b08cbd8a16ad48e criterion 1) ────────────────
  #
  # Eleven block types the printer now spells, read back. Every clause is the
  # exact inverse of its printer clause: the printer emits the CANONICAL key
  # (it accepts several spellings on read), so what these return re-prints
  # byte-for-byte — which is what the golden round-trip tests pin.
  #
  # A scalar that is a NUMBER or a BOOLEAN in the stored block comes back as
  # one (`put_num_attr` / `put_bool_attr`), never as the string it travelled
  # as: a pull/push must not retype `level: 2` into `level: "2"`.

  # `paper-links` — the ref's `description` is the long field and rides the
  # element body; everything else is an attribute.
  defp build_block("paper-links", attrs, sc, cur) do
    builder = fn ref_attrs, sc, cur ->
      with {:ok, body, cur} <- tag_text("ref", sc, cur) do
        ref =
          %{}
          |> put_attr("slug", ref_attrs)
          |> put_attr("title", ref_attrs)
          |> put_attr("eyebrow", ref_attrs)
          |> put_attr("meta", ref_attrs)
          |> put_attr("reason", ref_attrs)
          |> put_bool_attr("featured", ref_attrs)
          |> put_bool_attr("prefer_authored_copy", ref_attrs)
          |> then(&if body == "", do: &1, else: Map.put(&1, "description", body))

        {:ok, ref, cur}
      end
    end

    with {:ok, refs, cur} <- child_seq("paper-links", "ref", sc, cur, builder) do
      block =
        %{"type" => "paper-links", "refs" => refs}
        |> put_attr("id", attrs)
        |> put_attr("title", attrs)
        |> put_attr("description", attrs)
        |> put_attr("layout", attrs)

      {:ok, block, cur}
    end
  end

  # `cards` — the item body is canonically `text` (the printer also READS the
  # legacy `body` spelling, so a `body`-keyed card canonicalizes on round-trip).
  defp build_block("cards", attrs, sc, cur) do
    builder = fn card_attrs, sc, cur ->
      with {:ok, body, cur} <- tag_text("card", sc, cur) do
        item =
          %{}
          |> put_attr("title", card_attrs)
          |> put_attr("tone", card_attrs)
          |> then(&if body == "", do: &1, else: Map.put(&1, "text", body))

        {:ok, item, cur}
      end
    end

    with {:ok, items, cur} <- child_seq("cards", "card", sc, cur, builder) do
      {:ok, %{"type" => "cards", "items" => items} |> put_attr("id", attrs), cur}
    end
  end

  # `terminal` — a console transcript whose body is a real BLOCK list, so it
  # recurses through `block_seq` exactly as `section` does. Canonical body key
  # is `children`, the one the renderer prefers (compose.ex container_children).
  defp build_block("terminal", attrs, sc, cur) do
    base = fn blocks ->
      %{"type" => "terminal", "children" => blocks}
      |> put_attr("id", attrs)
      |> put_attr("title", attrs)
      |> put_attr("footer", attrs)
      |> put_bool_attr("live", attrs)
    end

    if sc do
      {:ok, base.([]), cur}
    else
      {blocks, errors, cur} = block_seq(cur, "terminal")
      {errors, cur} = expect_close("terminal", cur, errors)

      if errors == [], do: {:ok, base.(blocks), cur}, else: {:skip, errors, cur}
    end
  end

  # `action` — a call-to-action leaf, the `hr` shape (attributes only, no body).
  defp build_block("action", attrs, _sc, cur) do
    block =
      %{"type" => "action"}
      |> put_attr("id", attrs)
      |> put_attr("label", attrs)
      |> put_attr("href", attrs)
      |> put_attr("priority", attrs)

    {:ok, block, cur}
  end

  # `pipeline` — ordered stage nodes; `detail` is the body. `source` is a
  # boolean in 27 corpus nodes and a string source-ref in 1, so `put_bool_attr`
  # reads "true"/"false" back as booleans and leaves every other value a string.
  defp build_block("pipeline", attrs, sc, cur) do
    builder = fn node_attrs, sc, cur ->
      with {:ok, body, cur} <- tag_text("node", sc, cur) do
        node =
          %{}
          |> put_attr("title", node_attrs)
          |> put_attr("kind", node_attrs)
          |> put_bool_attr("source", node_attrs)
          |> put_attr("files", node_attrs)
          |> then(&if body == "", do: &1, else: Map.put(&1, "detail", body))

        {:ok, node, cur}
      end
    end

    with {:ok, nodes, cur} <- child_seq("pipeline", "node", sc, cur, builder) do
      {:ok, %{"type" => "pipeline", "nodes" => nodes} |> put_attr("id", attrs), cur}
    end
  end

  # `stat-grid` — the renderer's accepted alias of `stats`; SAME `<stat>` child.
  defp build_block("stat-grid", attrs, sc, cur) do
    with {:ok, items, cur} <- child_seq("stat-grid", "stat", sc, cur, &stat_item_builder/3) do
      {:ok, %{"type" => "stat-grid", "items" => items} |> put_attr("id", attrs), cur}
    end
  end

  # `blockquote` — an attributed quotation: `paragraph`'s inline body plus a
  # `cite`. (The printer also reads the legacy bare-`text` body spelling; this
  # returns the canonical `content` list.)
  defp build_block("blockquote", attrs, sc, cur) do
    with {:ok, nodes, cur} <- tag_inline("blockquote", sc, cur) do
      block =
        %{"type" => "blockquote", "content" => nodes}
        |> put_attr("id", attrs)
        |> put_attr("cite", attrs)

      {:ok, block, cur}
    end
  end

  # `toc` — `level` and `depth` are integers, `numbered` a boolean.
  defp build_block("toc", attrs, sc, cur) do
    builder = fn entry_attrs, sc, cur ->
      with {:ok, body, cur} <- tag_text("entry", sc, cur) do
        item =
          %{}
          |> put_int_attr("level", entry_attrs)
          |> put_attr("anchor", entry_attrs)
          |> then(&if body == "", do: &1, else: Map.put(&1, "text", body))

        {:ok, item, cur}
      end
    end

    with {:ok, items, cur} <- child_seq("toc", "entry", sc, cur, builder) do
      block =
        %{"type" => "toc", "items" => items}
        |> put_attr("id", attrs)
        |> put_int_attr("depth", attrs)
        |> put_bool_attr("numbered", attrs)

      {:ok, block, cur}
    end
  end

  # `bar-chart` — a bar's `value` is numeric; the block's `values` (show the
  # numbers) is a boolean.
  defp build_block("bar-chart", attrs, sc, cur) do
    builder = fn bar_attrs, sc, cur ->
      with {:ok, _body, cur} <- tag_text("bar", sc, cur) do
        {:ok, %{} |> put_attr("label", bar_attrs) |> put_num_attr("value", bar_attrs), cur}
      end
    end

    with {:ok, bars, cur} <- child_seq("bar-chart", "bar", sc, cur, builder) do
      block =
        %{"type" => "bar-chart", "bars" => bars}
        |> put_attr("id", attrs)
        |> put_bool_attr("values", attrs)

      {:ok, block, cur}
    end
  end

  # `lineage` — dated nodes on a line; `source` carries THE KILDE LAW's
  # provenance ref and `body` is the node's prose.
  defp build_block("lineage", attrs, sc, cur) do
    builder = fn node_attrs, sc, cur ->
      with {:ok, body, cur} <- tag_text("lineage-node", sc, cur) do
        node =
          %{}
          |> put_attr("title", node_attrs)
          |> put_attr("overline", node_attrs)
          |> put_attr("source", node_attrs)
          |> then(&if body == "", do: &1, else: Map.put(&1, "body", body))

        {:ok, node, cur}
      end
    end

    with {:ok, nodes, cur} <- child_seq("lineage", "lineage-node", sc, cur, builder) do
      {:ok, %{"type" => "lineage", "nodes" => nodes} |> put_attr("id", attrs), cur}
    end
  end

  # `chart` — the axis bounds and the x labels ride the block's own attributes
  # and reassemble into the stored `axes` map; a series body is its comma-
  # separated numeric points. An axes map with nothing in it is OMITTED, not
  # written as `%{}` — the one corpus chart without axes must re-print the same.
  defp build_block("chart", attrs, sc, cur) do
    builder = fn series_attrs, sc, cur ->
      with {:ok, body, cur} <- tag_text("series", sc, cur) do
        {:ok, %{} |> put_attr("label", series_attrs) |> Map.put("points", num_list(body)), cur}
      end
    end

    with {:ok, series, cur} <- child_seq("chart", "series", sc, cur, builder) do
      axes =
        %{}
        |> put_num_attr("min", attrs)
        |> put_num_attr("max", attrs)
        |> put_labels_attr("xLabels", "xlabels", attrs)

      block =
        %{"type" => "chart", "series" => series}
        |> put_attr("id", attrs)
        |> put_attr("kind", attrs)
        |> put_attr("caption", attrs)
        |> then(&if axes == %{}, do: &1, else: Map.put(&1, "axes", axes))

      {:ok, block, cur}
    end
  end

  defp build_block("steps", attrs, sc, cur) do
    builder = fn step_attrs, sc, cur ->
      if sc do
        {:ok, %{"blocks" => []} |> put_attr("title", step_attrs) |> Map.put_new("blocks", []),
         cur}
      else
        {blocks, errors, cur} = block_seq(cur, "step")

        case expect_close("step", cur, errors) do
          {[], cur} -> {:ok, %{"blocks" => blocks} |> put_attr("title", step_attrs), cur}
          {errors, cur} -> {:error, errors, cur}
        end
      end
    end

    with {:ok, steps, cur} <- child_seq("steps", "step", sc, cur, builder) do
      {:ok, %{"type" => "steps", "steps" => steps} |> put_attr("id", attrs), cur}
    end
  end

  # The divider is a self-closing leaf (<hr/>) — no content, id-only. It always
  # round-trips through the printer's self-close, so `sc` carries no block body.
  defp build_block("hr", attrs, _sc, cur),
    do: {:ok, put_attr(%{"type" => "divider"}, "id", attrs), cur}

  # A disclosure container — the `section` template with a `summary` attr and a
  # body of blocks. Empty (self-closed) and populated forms both round-trip.
  defp build_block("expandable", attrs, sc, cur) do
    if sc do
      {:ok,
       %{"type" => "expandable", "blocks" => []}
       |> put_attr("id", attrs)
       |> put_attr("summary", attrs), cur}
    else
      {blocks, errors, cur} = block_seq(cur, "expandable")
      {errors, cur} = expect_close("expandable", cur, errors)

      if errors == [] do
        {:ok,
         %{"type" => "expandable", "blocks" => blocks}
         |> put_attr("id", attrs)
         |> put_attr("summary", attrs), cur}
      else
        {:skip, errors, cur}
      end
    end
  end

  defp build_block("table", attrs, sc, cur) do
    with {:ok, {head, rows}, cur} <- table_rows(sc, cur) do
      block =
        %{"type" => "table"}
        |> put_attr("id", attrs)
        |> then(&if head == [], do: &1, else: Map.put(&1, "head", head))
        |> Map.put("rows", rows)

      {:ok, block, cur}
    end
  end

  defp build_block("section", attrs, sc, cur) do
    if sc do
      {:ok,
       %{"type" => "section", "blocks" => []}
       |> put_attr("id", attrs)
       |> put_attr("title", attrs)
       |> put_attr("variant", attrs), cur}
    else
      {blocks, errors, cur} = block_seq(cur, "section")
      {errors, cur} = expect_close("section", cur, errors)

      if errors == [] do
        {:ok,
         %{"type" => "section", "blocks" => blocks}
         |> put_attr("id", attrs)
         |> put_attr("title", attrs)
         |> put_attr("variant", attrs), cur}
      else
        {:skip, errors, cur}
      end
    end
  end

  # ── shared block shapes ─────────────────────────────────────────────────────

  defp text_block(tag, base, attrs, sc, cur, key \\ "text") do
    with {:ok, text, cur} <- tag_text(tag, sc, cur) do
      {:ok, base |> Map.put(key, text) |> put_attr("id", attrs), cur}
    end
  end

  # Shared builder for a `<note>` — a `notes` grid item and the singular `note`
  # block are the SAME shape (the block just adds its `"type"` tag). Body under
  # `text` (never `body` — the legacy `notes` item vocab, slots.ex legacy_slot
  # body→flat `text`), empty body dropped (the stats precedent).
  # ONE `<stat>` item, shared by `<stats>` and `<stat-grid>` — the renderer
  # composes both through a single clause (`t in ["stats", "stat-grid"]`), so
  # one element spells both. `caption`/`note` are the two attrs only the grid
  # uses today; a `stats` item that grows one reads it rather than dropping it.
  defp stat_item_builder(stat_attrs, sc, cur) do
    with {:ok, body, cur} <- tag_text("stat", sc, cur) do
      item =
        %{}
        |> put_attr("value", stat_attrs)
        |> put_attr("label", stat_attrs)
        |> put_attr("denom", stat_attrs)
        |> put_attr("caption", stat_attrs)
        |> put_attr("note", stat_attrs)
        |> then(&if body == "", do: &1, else: Map.put(&1, "body", body))

      {:ok, item, cur}
    end
  end

  defp note_item_builder(note_attrs, sc, cur) do
    with {:ok, body, cur} <- tag_text("note", sc, cur) do
      item =
        %{}
        |> put_attr("id", note_attrs)
        |> put_attr("label", note_attrs)
        |> put_attr("lead", note_attrs)
        |> then(&if body == "", do: &1, else: Map.put(&1, "text", body))

      {:ok, item, cur}
    end
  end

  # Plain-text content: everything up to the closing tag; nested markup is an error.
  defp tag_text(_tag, true, cur), do: {:ok, "", cur}

  defp tag_text(tag, false, cur) do
    {text, cur2} = raw_text(cur)

    case close_tag(cur2) do
      {:ok, ^tag, cur3} ->
        {:ok, text, cur3}

      {:ok, other, cur3} ->
        {:skip,
         [
           err(
             "mismatched-close",
             "expected </#{tag}>, found </#{other}>",
             line(cur2),
             "close <#{tag}> before opening the next element"
           )
         ], cur3}

      :not_close ->
        e =
          err(
            "markup-in-text",
            "<#{tag}> holds plain text — markup is not allowed inside it",
            line(cur2),
            "escape literal angle brackets as &lt; and &gt;"
          )

        {:skip, [e], consume_until_close(tag, cur2)}
    end
  end

  # Inline content: text + marks + links up to the closing tag.
  defp tag_inline(_tag, true, cur), do: {:ok, [], cur}

  defp tag_inline(tag, false, cur) do
    case inline_seq(cur, [], []) do
      {:ok, nodes, cur2} ->
        case close_tag(cur2) do
          {:ok, ^tag, cur3} ->
            {:ok, nodes, cur3}

          {:ok, other, cur3} ->
            {:skip,
             [
               err(
                 "mismatched-close",
                 "expected </#{tag}>, found </#{other}>",
                 line(cur2),
                 "inline tags nest strictly"
               )
             ], cur3}

          :not_close ->
            {:skip,
             [err("unclosed-tag", "<#{tag}> is never closed", line(cur2), "add </#{tag}>")], cur2}
        end

      {:error, errors, cur2} ->
        {:skip, errors, consume_until_close(tag, cur2)}
    end
  end

  # ── inline ──────────────────────────────────────────────────────────────────

  defp inline_seq(cur, marks, acc) do
    {text, cur} = raw_text(cur)
    acc = if text == "", do: acc, else: [text_node(text, marks) | acc]

    cond do
      peek(cur) == :close or peek(cur) == :eof ->
        {:ok, Enum.reverse(acc), cur}

      true ->
        case open_tag(cur) do
          {:error, e} ->
            {:error, [e], skip_to_next_tag(cur)}

          {:ok, tag, attrs, self_closed, cur2} ->
            inline_element(tag, attrs, self_closed, cur, cur2, marks, acc)
        end
    end
  end

  defp inline_element(tag, attrs, self_closed, cur, cur2, marks, acc) do
    cond do
      Map.has_key?(@inline_marks, tag) and not self_closed ->
        mark = @inline_marks[tag]

        case inline_seq(cur2, marks ++ [mark], []) do
          {:ok, inner, cur3} ->
            case close_tag(cur3) do
              {:ok, ^tag, cur4} ->
                inline_seq(cur4, marks, Enum.reverse(inner) ++ acc)

              {:ok, other, cur4} ->
                {:error,
                 [
                   err(
                     "mismatched-close",
                     "expected </#{tag}>, found </#{other}>",
                     line(cur3),
                     "inline marks nest strictly"
                   )
                 ], cur4}

              :not_close ->
                {:error,
                 [err("unclosed-tag", "<#{tag}> is never closed", line(cur3), "add </#{tag}>")],
                 cur3}
            end

          error ->
            error
        end

      tag == "a" and marks == [] and not self_closed ->
        case check_attrs("a", attrs, line(cur)) do
          [] ->
            case inline_seq(cur2, [], []) do
              {:ok, children, cur3} ->
                case close_tag(cur3) do
                  {:ok, "a", cur4} ->
                    node = %{"type" => "link", "children" => children} |> put_attr("href", attrs)
                    inline_seq(cur4, marks, [node | acc])

                  _ ->
                    {:error, [err("unclosed-tag", "<a> is never closed", line(cur3), "add </a>")],
                     cur3}
                end

              error ->
                error
            end

          attr_errors ->
            {:error, attr_errors, cur2}
        end

      tag == "a" ->
        {:error,
         [
           err(
             "link-in-mark",
             "links cannot nest inside <b>/<i>/<code>",
             line(cur),
             "put the emphasis inside the link instead: <a href=\"…\"><b>…</b></a>"
           )
         ], cur2}

      true ->
        hint =
          Map.get(@unknown_tag_hints, tag, "inline tags: <b> <i> <code> <u> <s> <a href=\"…\">")

        {:error, [err("unknown-inline-tag", "unknown inline tag <#{tag}>", line(cur), hint)],
         cur2}
    end
  end

  defp text_node(text, []), do: %{"type" => "text", "value" => text}
  defp text_node(text, marks), do: %{"type" => "text", "marks" => marks, "value" => text}

  # ── structured children (byline/ul/stats/steps/table) ───────────────────────

  defp child_seq(_parent, _child, true, cur, _builder), do: {:ok, [], cur}

  defp child_seq(parent, child, false, cur, builder),
    do: child_seq_loop(parent, child, cur, builder, [], [])

  defp child_seq_loop(parent, child, cur, builder, items, errors) do
    cur = skip_ws(cur)

    case peek(cur) do
      :close ->
        {errors, cur} = expect_close(parent, cur, errors)
        if errors == [], do: {:ok, Enum.reverse(items), cur}, else: {:skip, errors, cur}

      :tag ->
        case open_tag(cur) do
          {:error, e} ->
            child_seq_loop(parent, child, skip_to_next_tag(cur), builder, items, [e | errors])

          {:ok, tag, attrs, sc, cur2} ->
            child_seq_item(parent, child, cur, builder, items, errors, tag, attrs, sc, cur2)
        end

      _ ->
        {:skip,
         [
           err("unclosed-tag", "<#{parent}> is never closed", line(cur), "add </#{parent}>")
           | errors
         ], cur}
    end
  end

  defp child_seq_item(parent, child, cur, builder, items, errors, tag, attrs, sc, cur2) do
    if tag == child do
      case check_attrs(child, attrs, line(cur)) do
        [] ->
          case builder.(attrs, sc, cur2) do
            {:ok, item, cur3} ->
              child_seq_loop(parent, child, cur3, builder, [item | items], errors)

            {:skip, es, cur3} ->
              child_seq_loop(parent, child, cur3, builder, items, es ++ errors)

            {:error, es, cur3} ->
              child_seq_loop(parent, child, cur3, builder, items, es ++ errors)
          end

        attr_errors ->
          child_seq_loop(
            parent,
            child,
            consume_element(child, sc, cur2),
            builder,
            items,
            attr_errors ++ errors
          )
      end
    else
      e =
        err(
          "wrong-child",
          "<#{parent}> holds only <#{child}> children, found <#{tag}>",
          line(cur),
          "each entry is one <#{child}>"
        )

      child_seq_loop(parent, child, consume_element(tag, sc, cur2), builder, items, [e | errors])
    end
  end

  defp table_rows(true, cur), do: {:ok, {[], []}, cur}

  defp table_rows(false, cur), do: table_rows_loop(cur, [], [], [])

  defp table_rows_loop(cur, head, rows, errors) do
    cur = skip_ws(cur)

    case peek(cur) do
      :close ->
        {errors, cur} = expect_close("table", cur, errors)

        if errors == [] do
          {:ok, {Enum.reverse(head), Enum.reverse(rows)}, cur}
        else
          {:skip, errors, cur}
        end

      :tag ->
        case open_tag(cur) do
          {:error, e} -> table_rows_loop(skip_to_next_tag(cur), head, rows, [e | errors])
          {:ok, tag, _attrs, sc, cur2} -> table_row(cur, cur2, tag, sc, head, rows, errors)
        end

      _ ->
        {:skip,
         [err("unclosed-tag", "<table> is never closed", line(cur), "add </table>") | errors],
         cur}
    end
  end

  defp table_row(cur, cur2, tag, sc, head, rows, errors) do
    if tag == "tr" and not sc do
      case row_cells(cur2, cur) do
        {:ok, {:head, cells}, cur3} ->
          table_rows_loop(cur3, Enum.reverse(cells) ++ head, rows, errors)

        {:ok, {:body, cells}, cur3} ->
          table_rows_loop(cur3, head, [cells | rows], errors)

        {:skip, es, cur3} ->
          table_rows_loop(cur3, head, rows, es ++ errors)
      end
    else
      e =
        err(
          "wrong-child",
          "<table> holds only <tr> rows, found <#{tag}>",
          line(cur),
          "wrap cells in <tr>…</tr>"
        )

      table_rows_loop(consume_element(tag, sc, cur2), head, rows, [e | errors])
    end
  end

  defp row_cells(cur, at), do: row_cells_loop(cur, at, nil, [])

  defp row_cells_loop(cur, at, kind, cells) do
    cur = skip_ws(cur)

    case peek(cur) do
      :close ->
        case close_tag(cur) do
          {:ok, "tr", cur2} ->
            {:ok, {kind || :body, Enum.reverse(cells)}, cur2}

          {:ok, other, cur2} ->
            {:skip,
             [
               err(
                 "mismatched-close",
                 "expected </tr>, found </#{other}>",
                 line(cur),
                 "close the row first"
               )
             ], cur2}
        end

      :tag ->
        case open_tag(cur) do
          {:error, e} -> {:skip, [e], consume_until_close("tr", skip_to_next_tag(cur))}
          {:ok, tag, _attrs, sc, cur2} -> row_cell(cur, cur2, tag, sc, at, kind, cells)
        end

      _ ->
        {:skip, [err("unclosed-tag", "<tr> is never closed", line(cur), "add </tr>")], cur}
    end
  end

  defp row_cell(cur, cur2, tag, sc, at, kind, cells) do
    case {tag, kind} do
      # Head cells parse as INLINE content and emit inline-node lists — the
      # write chokepoint's canonical head-cell shape, so blocks fetched from
      # the server round-trip byte-equal (the legacy %{"text" => …} map is a
      # printer-input shape only).
      {"th", k} when k in [nil, :head] ->
        case tag_inline("th", sc, cur2) do
          {:ok, nodes, cur3} -> row_cells_loop(cur3, at, :head, [nodes | cells])
          {:skip, es, cur3} -> {:skip, es, consume_until_close("tr", cur3)}
        end

      {"td", k} when k in [nil, :body] ->
        case tag_inline("td", sc, cur2) do
          {:ok, nodes, cur3} -> row_cells_loop(cur3, at, :body, [nodes | cells])
          {:skip, es, cur3} -> {:skip, es, consume_until_close("tr", cur3)}
        end

      {t, _} when t in ["th", "td"] ->
        {:skip,
         [
           err(
             "mixed-row",
             "a row holds either <th> cells or <td> cells, not both",
             line(cur),
             "head rows are all <th>; body rows are all <td>"
           )
         ], consume_until_close("tr", cur2)}

      _ ->
        {:skip,
         [
           err(
             "wrong-child",
             "<tr> holds only <th> or <td> cells, found <#{tag}>",
             line(cur),
             "cells are <th> (head) or <td> (body)"
           )
         ], consume_until_close("tr", consume_element(tag, sc, cur2))}
    end
  end

  # ── paper <meta> ────────────────────────────────────────────────────────────

  defp maybe_meta(cur) do
    cur2 = skip_ws(cur)

    with :tag <- peek(cur2),
         {:ok, "meta", _attrs, false, cur3} <- open_tag(cur2) do
      meta_loop(cur3, %{}, [])
    else
      _ -> {%{}, [], cur}
    end
  end

  defp meta_loop(cur, meta, errors) do
    cur = skip_ws(cur)

    case peek(cur) do
      :close ->
        {errors, cur} = expect_close("meta", cur, errors)
        {meta, errors, cur}

      :tag ->
        case open_tag(cur) do
          {:error, e} -> meta_loop(skip_to_next_tag(cur), meta, [e | errors])
          {:ok, tag, attrs, sc, cur2} -> meta_entry(cur, cur2, tag, attrs, sc, meta, errors)
        end

      _ ->
        {meta, [err("unclosed-tag", "<meta> is never closed", line(cur), "add </meta>") | errors],
         cur}
    end
  end

  defp meta_entry(cur, cur2, tag, attrs, sc, meta, errors) do
    case tag do
      "description" ->
        case tag_text("description", sc, cur2) do
          {:ok, text, cur3} -> meta_loop(cur3, Map.put(meta, "description", text), errors)
          {:skip, es, cur3} -> meta_loop(cur3, meta, es ++ errors)
        end

      "tag" ->
        case tag_text("tag", sc, cur2) do
          {:ok, rationale, cur3} ->
            entry =
              %{"rationale" => rationale}
              |> put_attr("tag", attrs)
              |> put_int_attr("strength", attrs)

            meta_loop(cur3, Map.update(meta, "tags", [entry], &(&1 ++ [entry])), errors)

          {:skip, es, cur3} ->
            meta_loop(cur3, meta, es ++ errors)
        end

      other ->
        e =
          err(
            "wrong-child",
            "<meta> holds <description> and <tag> entries, found <#{other}>",
            line(cur),
            "publish-wall fields live in <meta>"
          )

        meta_loop(consume_element(other, sc, cur2), meta, [e | errors])
    end
  end

  # ── attribute checking ──────────────────────────────────────────────────────

  defp check_attrs(tag, attrs, line) do
    allowed = Map.get(@block_attrs, tag, [])

    attrs
    |> Enum.reject(fn {k, _v} -> k in allowed end)
    |> Enum.map(fn
      {"class", _} ->
        err(
          "no-styling",
          "class= on <#{tag}> — BPML carries no styling",
          line,
          "surfaces own their rendering; remove the attribute"
        )

      {"style", _} ->
        err(
          "no-styling",
          "style= on <#{tag}> — BPML carries no styling",
          line,
          "surfaces own their rendering; remove the attribute"
        )

      {k, _} ->
        err(
          "unknown-attr",
          "unknown attribute #{k}= on <#{tag}>",
          line,
          "allowed on <#{tag}>: " <> attrs_hint(allowed)
        )
    end)
  end

  defp attrs_hint([]), do: "(no attributes)"
  defp attrs_hint(allowed), do: Enum.join(allowed, ", ")

  defp put_attr(map, key, attrs) do
    case List.keyfind(attrs, key, 0) do
      {^key, v} -> Map.put(map, key, v)
      nil -> map
    end
  end

  defp put_int_attr(map, key, attrs) do
    case List.keyfind(attrs, key, 0) do
      {^key, v} ->
        case Integer.parse(v) do
          {n, ""} -> Map.put(map, key, n)
          _ -> Map.put(map, key, v)
        end

      nil ->
        map
    end
  end

  # A stored BOOLEAN travels as the attribute text "true"/"false" and comes
  # back a boolean — anything else stays the string it was, which is what lets
  # `pipeline`'s `source` be a boolean in 27 corpus nodes and a source-ref
  # string ("queue.ex:42") in one without either losing its type.
  defp put_bool_attr(map, key, attrs) do
    case List.keyfind(attrs, key, 0) do
      {^key, "true"} -> Map.put(map, key, true)
      {^key, "false"} -> Map.put(map, key, false)
      {^key, v} -> Map.put(map, key, v)
      nil -> map
    end
  end

  # A stored NUMBER (a bar's value, a chart axis bound) — integer where the
  # text is an integer, float where it is a float, else the string verbatim.
  defp put_num_attr(map, key, attrs) do
    case List.keyfind(attrs, key, 0) do
      {^key, v} -> Map.put(map, key, num(v))
      nil -> map
    end
  end

  # The comma-joined `xlabels` attribute → the stored `xLabels` list. An absent
  # or empty attribute contributes NO key, so an axes map that would be empty
  # stays absent rather than becoming `%{}`.
  defp put_labels_attr(map, key, attr_key, attrs) do
    case List.keyfind(attrs, attr_key, 0) do
      {^attr_key, ""} -> map
      {^attr_key, v} -> Map.put(map, key, String.split(v, ","))
      nil -> map
    end
  end

  defp num_list(""), do: []
  defp num_list(s), do: s |> String.split(",") |> Enum.map(&num/1)

  defp num(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, ""} ->
        i

      _ ->
        case Float.parse(s) do
          {f, ""} -> f
          _ -> s
        end
    end
  end

  # ── lexing ──────────────────────────────────────────────────────────────────

  defp peek({<<"</", _::binary>>, _}), do: :close
  defp peek({<<"<", _::binary>>, _}), do: :tag
  defp peek({<<>>, _}), do: :eof
  defp peek(_), do: :text

  defp line({_, ln}), do: ln

  defp skip_ws({<<"\n", rest::binary>>, ln}), do: skip_ws({rest, ln + 1})
  defp skip_ws({<<c, rest::binary>>, ln}) when c in [?\s, ?\t, ?\r], do: skip_ws({rest, ln})
  defp skip_ws(cur), do: cur

  # Raw text up to the next tag (or EOF), entities unescaped.
  defp raw_text(cur), do: raw_text(cur, [])

  defp raw_text({<<"<", _::binary>>, _} = cur, acc), do: {unescape(acc), cur}
  defp raw_text({<<>>, _} = cur, acc), do: {unescape(acc), cur}
  defp raw_text({<<"\n", rest::binary>>, ln}, acc), do: raw_text({rest, ln + 1}, [?\n | acc])

  defp raw_text({<<c::utf8, rest::binary>>, ln}, acc),
    do: raw_text({rest, ln}, [<<c::utf8>> | acc])

  defp unescape(acc) do
    acc
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  # <name attr="v" …> | <name …/> — returns {:ok, name, attrs, self_closed?, cur}
  defp open_tag({<<"<", rest::binary>>, ln}) do
    {name, cur} = tag_name({rest, ln})
    {attrs, cur} = attr_list(cur, [])

    case cur do
      {<<"/>", rest::binary>>, ln} ->
        {:ok, name, attrs, true, {rest, ln}}

      {<<">", rest::binary>>, ln} ->
        {:ok, name, attrs, false, {rest, ln}}

      {_, ln} ->
        {:error,
         err(
           "bad-tag",
           "malformed tag <#{name} …",
           ln,
           "attributes are name=\"value\"; close the tag with > or />"
         )}
    end
  end

  defp tag_name(cur),
    do: take_while(cur, [], fn c -> c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?- end)

  defp attr_list(cur, acc) do
    cur = skip_ws_inline(cur)

    case cur do
      {<<"/>", _::binary>>, _} ->
        {Enum.reverse(acc), cur}

      {<<">", _::binary>>, _} ->
        {Enum.reverse(acc), cur}

      _ ->
        {name, cur2} =
          take_while(cur, [], fn c -> c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?- end)

        case {name, cur2} do
          {"", _} ->
            {Enum.reverse(acc), cur2}

          {name, {<<"=\"", rest::binary>>, ln}} ->
            {value, cur3} = attr_value({rest, ln}, [])
            attr_list(cur3, [{name, value} | acc])

          {name, cur3} ->
            attr_list(cur3, [{name, ""} | acc])
        end
    end
  end

  defp attr_value({<<"\"", rest::binary>>, ln}, acc), do: {unescape(acc), {rest, ln}}
  defp attr_value({<<"\n", rest::binary>>, ln}, acc), do: attr_value({rest, ln + 1}, [?\n | acc])

  defp attr_value({<<c::utf8, rest::binary>>, ln}, acc),
    do: attr_value({rest, ln}, [<<c::utf8>> | acc])

  defp attr_value({<<>>, ln}, acc), do: {unescape(acc), {<<>>, ln}}

  defp skip_ws_inline({<<c, rest::binary>>, ln}) when c in [?\s, ?\t],
    do: skip_ws_inline({rest, ln})

  defp skip_ws_inline({<<"\n", rest::binary>>, ln}), do: skip_ws_inline({rest, ln + 1})
  defp skip_ws_inline(cur), do: cur

  defp take_while({<<c::utf8, rest::binary>>, ln} = cur, acc, fun) do
    if fun.(c) do
      take_while({rest, ln}, [<<c::utf8>> | acc], fun)
    else
      {acc |> Enum.reverse() |> IO.iodata_to_binary(), cur}
    end
  end

  defp take_while({<<>>, _} = cur, acc, _fun),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), cur}

  defp close_tag({<<"</", rest::binary>>, ln}) do
    {name, cur} = tag_name({rest, ln})

    case cur do
      {<<">", rest::binary>>, ln} -> {:ok, name, {rest, ln}}
      _ -> {:ok, name, cur}
    end
  end

  defp close_tag(_cur), do: :not_close

  defp expect_close(tag, cur, errors) do
    cur = skip_ws(cur)

    case close_tag(cur) do
      {:ok, ^tag, cur2} ->
        {errors, cur2}

      {:ok, other, cur2} ->
        {[
           err(
             "mismatched-close",
             "expected </#{tag}>, found </#{other}>",
             line(cur),
             "elements close in the order they open"
           )
           | errors
         ], cur2}

      :not_close ->
        {[err("unclosed-tag", "<#{tag}> is never closed", line(cur), "add </#{tag}>") | errors],
         cur}
    end
  end

  # ── error recovery: consume a whole (possibly unknown) element ─────────────

  defp consume_element(_tag, true, cur), do: cur
  defp consume_element(tag, false, cur), do: consume_until_close(tag, cur)

  defp consume_until_close(tag, cur), do: consume_until_close(tag, cur, 0)

  defp consume_until_close(tag, cur, depth) do
    {_text, cur} = raw_text(cur)

    case cur do
      {<<>>, _} ->
        cur

      _ ->
        case close_tag(cur) do
          {:ok, ^tag, cur2} when depth == 0 ->
            cur2

          {:ok, ^tag, cur2} ->
            consume_until_close(tag, cur2, depth - 1)

          {:ok, _other, cur2} ->
            consume_until_close(tag, cur2, depth)

          :not_close ->
            case open_tag(cur) do
              {:ok, ^tag, _attrs, false, cur2} -> consume_until_close(tag, cur2, depth + 1)
              {:ok, _other, _attrs, _sc, cur2} -> consume_until_close(tag, cur2, depth)
              {:error, _} -> advance_one(cur) |> then(&consume_until_close(tag, &1, depth))
            end
        end
    end
  end

  # Recovery from a malformed tag: step past the "<" and run to the next one.
  defp skip_to_next_tag(cur) do
    {_text, cur2} = cur |> advance_one() |> raw_text()
    cur2
  end

  defp advance_one({<<"\n", rest::binary>>, ln}), do: {rest, ln + 1}
  defp advance_one({<<_::utf8, rest::binary>>, ln}), do: {rest, ln}
  defp advance_one(cur), do: cur

  defp err(code, message, line, hint), do: %{code: code, message: message, line: line, hint: hint}
end
