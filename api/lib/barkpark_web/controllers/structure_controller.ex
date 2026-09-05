defmodule BarkparkWeb.StructureController do
  @moduledoc """
  GET /v1/structure/:dataset — the server's canonical desk structure as JSON.

  `Barkpark.Structure.build/2` is what Studio renders: host groups (content,
  papers, sheets, books, media, taxonomy, content-types, settings) PLUS the
  plugin resolver chain's contributions (frt's game groups, any future
  plugin's desk items). The Go TUI consumed only raw schemas and rebuilt a
  crude desk client-side — its private→Settings heuristic buried every plugin
  collection (sheet, book, the 25 frt types) under Settings as broken
  singletons. Serving the real tree makes the TUI's desk == Studio's desk,
  including plugin groups, with zero client logic per plugin.

  `content-types` (issue #8463) is the same generic-fallback fix applied to
  the HOST side of that heuristic: a non-plugin-owned schema that no curated
  group claimed and that isn't marked `singleton: true` gets a real
  `:document_type_list` row there instead of a dead Settings singleton.
  Placement keys on `singleton` ALONE — never on `visibility`, which is an
  access control (Gyldendal #25); keying on it stranded every schema
  registered without an explicit `visibility`, since that defaults to
  `"public"`.

  Auth matches the schema index the TUI already calls (admin token on the
  same pipelines); response: `{"structure": <node>}` where a node is
  `{id, title, icon, type, typeName, filter, items: [node], child: node}`.
  `type` is one of `list · document_type_list · document · divider ·
  plugin_link · plugin_document_list`. `filter` is a `"field=value"` string
  (a path on `plugin_link` nodes), EXCEPT on `plugin_document_list` nodes
  where it is the raw filter-map object — the Go client decodes it as
  `json.RawMessage` and `DeskNode.FilterString()` normalizes both shapes.
  Absent fields are omitted, never null-padded.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Structure

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  def show(conn, %{"dataset" => dataset}) do
    json(conn, %{structure: node_json(Structure.build(dataset, scope_opts(conn)))})
  end

  defp node_json(%Structure.Node{} = node) do
    %{}
    |> put_present(:id, node.id)
    |> put_present(:title, node.title)
    |> put_present(:icon, node.icon)
    |> put_present(:type, node.type && Atom.to_string(node.type))
    |> put_present(:typeName, node.type_name)
    |> put_present(:filter, node.filter)
    # Gyldendal parity E3.2 — additive keys; a client that ignores them keeps
    # the legacy "document id == type name" reading.
    |> put_present(:docId, node.doc_id)
    |> put_present(:orderings, node.orderings)
    |> put_items(node.items)
    |> put_child(node.child)
  end

  defp put_present(map, _k, nil), do: map
  defp put_present(map, _k, ""), do: map
  defp put_present(map, k, v), do: Map.put(map, k, v)

  defp put_items(map, items) when is_list(items) and items != [] do
    Map.put(map, :items, Enum.map(items, &node_json/1))
  end

  defp put_items(map, _), do: map

  defp put_child(map, %Structure.Node{} = child), do: Map.put(map, :child, node_json(child))
  defp put_child(map, _), do: map
end
