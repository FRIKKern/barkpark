defmodule BarkparkWeb.Components.DraftDiff do
  @moduledoc """
  Sanity-style draft-vs-published diff view (Task `barkpark-uix`).

  Renders a top-level field-level diff between the current draft document
  and its published twin. v1 scope is intentionally narrow:

    * Top-level fields only — nested composites render as a JSON dump for
      the column, no recursion. This matches the project CLAUDE.md
      "Plugin schemas (v2)" guidance that composite editing lives in
      Studio's form, not the diff view.
    * Status per field is `:unchanged | :added | :removed | :changed`,
      computed against the schema's declared field list (not a union of
      keys present in either map) so removed-from-schema fields don't
      leak in.
    * Renders gracefully when `published` is `nil` — every row collapses
      to `:added`. The toggle button in StudioLive only surfaces when
      both sides exist, so this is the safe fallback for any future
      callsite that doesn't gate it.

  Values render the way an editor wrote them, not as storage
  (task-30d564b8b1219ab9):

    * a row is labelled with the field's title, the machine name beside it;
    * a reference shows the referenced document's title, through the
      `ref_title` resolver the caller passes (it carries the tenant scope);
      without one, the id;
    * an image shows its size and alt text;
    * rich text shows its plain text;
    * any other composite is compact JSON, and a `data:` URI (an image's
      inline LQIP preview) is never printed;
    * the status column is a word, not a glyph.

  A v2 follow-up may add nested-aware diffs and per-field revert actions —
  explicitly out of scope here.
  """

  use Phoenix.Component

  attr :draft, :map, required: true
  attr :published, :map, default: nil
  attr :schema, :map, required: true

  # `fn ref_id, ref_type -> title end`, or nil to show the id. The caller
  # builds it with the editor's tenant scope (Content.reference_title/4).
  attr :ref_title, :any, default: nil

  def draft_diff(assigns) do
    rows = compute_rows(assigns.schema, assigns.draft, assigns.published, assigns.ref_title)
    changed = Enum.count(rows, &(&1.status != :unchanged))
    assigns = assign(assigns, rows: rows, changed: changed)

    ~H"""
    <div class="bp-draft-diff" data-test-id="draft-diff">
      <header class="bp-draft-diff-header">
        <span class="bp-draft-diff-title">Draft vs Published</span>
        <span class="bp-draft-diff-meta" data-test-id="draft-diff-meta">
          <%= @changed %> <%= if @changed == 1, do: "change", else: "changes" %>
        </span>
      </header>
      <table class="bp-draft-diff-table">
        <thead>
          <tr>
            <th class="bp-diff-col-name">Field</th>
            <th class="bp-diff-col-side">Published</th>
            <th class="bp-diff-col-side">Draft</th>
            <th class="bp-diff-col-status">Status</th>
          </tr>
        </thead>
        <tbody>
          <%= for row <- @rows do %>
            <tr class={"bp-diff-row bp-diff-#{row.status}"} data-test-id={"draft-diff-row-#{row.name}"}>
              <td class="bp-diff-col-name">
                <%= row.label %>
                <code :if={row.label != row.name} class="bp-diff-field-key"><%= row.name %></code>
              </td>
              <td><pre class="bp-diff-published"><%= row.published_text %></pre></td>
              <td><pre class="bp-diff-draft"><%= row.draft_text %></pre></td>
              <td class="bp-diff-status" data-test-id={"draft-diff-status-#{row.name}"}><%= status_label(row.status) %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  # Extract the field list from the schema. Schemas in Barkpark may be
  # either Ecto structs (atom-keyed) or plain maps (string-keyed) — both
  # shapes flow into the studio editor, so we accept both. Returns `[]`
  # when no fields are declared so the renderer just shows an empty
  # table instead of raising.
  defp compute_rows(schema, draft, published, ref_title) do
    draft_content = pluck_content(draft)
    pub_content = pluck_content(published)

    schema
    |> fields()
    |> Enum.map(fn f ->
      name = field_get(f, "name")
      dv = Map.get(draft_content, name)
      pv = Map.get(pub_content, name)

      status =
        cond do
          dv == pv -> :unchanged
          is_nil(pv) -> :added
          is_nil(dv) -> :removed
          true -> :changed
        end

      title = field_get(f, "title")

      %{
        name: name,
        label: if(is_binary(title) and title != "", do: title, else: name),
        draft: dv,
        published: pv,
        draft_text: format_val(dv, f, ref_title),
        published_text: format_val(pv, f, ref_title),
        status: status
      }
    end)
  end

  defp pluck_content(nil), do: %{}

  defp pluck_content(doc) do
    cond do
      is_map(doc) and Map.has_key?(doc, :content) -> doc.content || %{}
      is_map(doc) and Map.has_key?(doc, "content") -> doc["content"] || %{}
      true -> %{}
    end
  end

  defp fields(nil), do: []

  defp fields(schema) do
    Map.get(schema, :fields) || Map.get(schema, "fields") || []
  end

  @atom_keys %{
    "name" => :name,
    "title" => :title,
    "type" => :type,
    "to" => :to,
    "refType" => :refType
  }

  defp field_get(f, key), do: Map.get(f, key) || Map.get(f, Map.fetch!(@atom_keys, key))

  @rich_types ~w(richText portableText blocks portableDoc)
  @text_cap 400

  defp format_val(nil, _field, _ref_title), do: ""

  defp format_val(v, field, ref_title) do
    case field_get(field, "type") do
      "reference" -> format_ref(v, field, ref_title)
      "image" -> format_image(v)
      type when type in @rich_types -> v |> plain_text() |> cap()
      _ -> format_plain(v)
    end
  end

  defp format_ref(v, field, ref_title) do
    id = ref_id(v)

    cond do
      not is_binary(id) -> format_plain(v)
      is_function(ref_title, 2) -> ref_title.(id, ref_type(field))
      true -> id
    end
  end

  defp ref_id(%{"_ref" => id}), do: id
  defp ref_id(%{_ref: id}), do: id
  defp ref_id(id) when is_binary(id), do: id
  defp ref_id(_), do: nil

  # A single target type narrows the lookup; several (or none) do not.
  defp ref_type(field) do
    case field_get(field, "to") do
      [%{"type" => t}] -> t
      [%{type: t}] -> t
      _ -> field_get(field, "refType")
    end
  end

  defp format_image(%{} = img) do
    size =
      case {img["width"], img["height"]} do
        {w, h} when is_integer(w) and is_integer(h) -> "Image #{w}×#{h}"
        _ -> "Image"
      end

    case img["alt"] do
      alt when is_binary(alt) and alt != "" -> "#{size} · alt: #{alt}"
      _ -> "#{size} · no alt text"
    end
  end

  defp format_image(v), do: format_plain(v)

  defp format_plain(v) when is_binary(v), do: if(data_uri?(v), do: "[inline data]", else: v)

  defp format_plain(v) when is_atom(v) or is_number(v) or is_boolean(v), do: to_string(v)

  defp format_plain(v) do
    case Jason.encode(drop_data_uris(v)) do
      {:ok, json} -> json
      _ -> inspect(v)
    end
  end

  defp data_uri?(s), do: String.starts_with?(s, "data:")

  defp drop_data_uris(%{} = m) do
    for {k, v} <- m, not (is_binary(v) and data_uri?(v)), into: %{}, do: {k, drop_data_uris(v)}
  end

  defp drop_data_uris(l) when is_list(l), do: Enum.map(l, &drop_data_uris/1)
  defp drop_data_uris(v), do: v

  # Every text run in a block tree (Portable Text `children[].text` and
  # PortableDoc `content[].value`), blocks joined by a space.
  defp plain_text(v) when is_binary(v), do: v

  defp plain_text(l) when is_list(l),
    do: l |> Enum.map(&plain_text/1) |> Enum.reject(&(&1 == "")) |> Enum.join(" ")

  defp plain_text(%{} = m) do
    own =
      case {m["text"], m["value"]} do
        {t, _} when is_binary(t) -> t
        {_, t} when is_binary(t) -> if(data_uri?(t), do: "", else: t)
        _ -> ""
      end

    nested = m |> Map.take(["children", "content", "blocks"]) |> Map.values() |> plain_text()
    Enum.join(Enum.reject([own, nested], &(&1 == "")), " ")
  end

  defp plain_text(_), do: ""

  defp cap(s) when byte_size(s) > @text_cap, do: String.slice(s, 0, @text_cap) <> "…"
  defp cap(s), do: s

  defp status_label(:unchanged), do: "Unchanged"
  defp status_label(:added), do: "Added"
  defp status_label(:removed), do: "Removed"
  defp status_label(:changed), do: "Changed"
end
