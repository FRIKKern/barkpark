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

  Composite values (maps) and array values (lists) are formatted as
  single-line JSON in their column. A v2 follow-up may add nested-aware
  diffs and per-field revert actions — explicitly out of scope here.
  """

  use Phoenix.Component

  attr :draft, :map, required: true
  attr :published, :map, default: nil
  attr :schema, :map, required: true

  def draft_diff(assigns) do
    rows = compute_rows(assigns.schema, assigns.draft, assigns.published)
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
              <td class="bp-diff-col-name"><code><%= row.name %></code></td>
              <td><pre class="bp-diff-published"><%= format_val(row.published) %></pre></td>
              <td><pre class="bp-diff-draft"><%= format_val(row.draft) %></pre></td>
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
  defp compute_rows(schema, draft, published) do
    draft_content = pluck_content(draft)
    pub_content = pluck_content(published)

    schema
    |> fields()
    |> Enum.map(fn f ->
      name = Map.get(f, "name") || Map.get(f, :name)
      dv = Map.get(draft_content, name)
      pv = Map.get(pub_content, name)

      status =
        cond do
          dv == pv -> :unchanged
          is_nil(pv) -> :added
          is_nil(dv) -> :removed
          true -> :changed
        end

      %{name: name, draft: dv, published: pv, status: status}
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

  defp format_val(nil), do: ""
  defp format_val(v) when is_binary(v), do: v
  defp format_val(v) when is_atom(v) or is_number(v) or is_boolean(v), do: to_string(v)

  defp format_val(v) do
    case Jason.encode(v) do
      {:ok, json} -> json
      _ -> inspect(v)
    end
  end

  defp status_label(:unchanged), do: "—"
  defp status_label(:added), do: "+"
  defp status_label(:removed), do: "−"
  defp status_label(:changed), do: "Δ"
end
