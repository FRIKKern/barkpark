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
  `{id, title, icon, type, typeName, filter, items: [node], child: node}`
  (plus `paneTitle` on a declared list whose pane has its own title, and
  `initialValues` on a declared type list whose "+" presets fields).
  `type` is one of `list · document_type_list · document · divider ·
  plugin_link · plugin_document_list`. `filter` is a `"field=value"` string
  (a path on `plugin_link` nodes), EXCEPT on `plugin_document_list` nodes
  where it is the raw filter-map object — the Go client decodes it as
  `json.RawMessage` and `DeskNode.FilterString()` normalizes both shapes.
  Absent fields are omitted, never null-padded.

  `?desk=<id>` builds the tree from the published `deskStructure` document
  with that id instead of `deskStructure`; when that document exists the
  response names it back as `desk` (task-31f9264adeb053be). An id that is not a published document id
  (or a `drafts.` id) is a 400. Without `?desk=` the response is unchanged.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Structure

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  # A published document id: letters, digits, `_ . -`, never `drafts.`.
  @desk_id ~r/\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\z/

  def show(conn, %{"dataset" => dataset} = params) do
    case params["desk"] do
      nil ->
        json(conn, %{structure: node_json(Structure.build(dataset, scope_opts(conn)))})

      desk when is_binary(desk) ->
        if Regex.match?(@desk_id, desk) and not String.starts_with?(desk, "drafts.") do
          opts = Keyword.put(scope_opts(conn), :desk_id, desk)
          desk_doc = Structure.desk_doc(dataset, opts)
          tree = node_json(Structure.build(dataset, Keyword.put(opts, :desk_doc, desk_doc)))

          # Named back only when that document was read; otherwise this is
          # the default tree and must not pass as the requested desk.
          json(conn, if(desk_doc, do: %{structure: tree, desk: desk}, else: %{structure: tree}))
        else
          refuse_desk(conn, desk)
        end

      desk ->
        refuse_desk(conn, desk)
    end
  end

  defp refuse_desk(conn, desk) do
    BarkparkWeb.ErrorResponse.emit_custom(
      conn,
      400,
      "malformed",
      "?desk= must be a published document id; received #{inspect(desk)}",
      %{parameter: "desk", received: desk, expected: "published document id"},
      "Send ?desk= as letters, digits, _ . - (no drafts. prefix), or leave it out for the default desk."
    )
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
    |> put_present(:tree, node.tree)
    # task-d99d878b061b435a — a declared desk item that could not be built
    # carries the reason; the rest of the desk is unaffected.
    |> put_present(:error, Map.get(node, :error))
    # task-a3e829ace0b184ea — the title of the pane a declared list opens,
    # when it differs from the row's.
    |> put_present(:paneTitle, Map.get(node, :pane_title))
    # task-dc9b751450c2c2c4 — the fields a declared type list's "+" starts a
    # document with.
    |> put_present(:initialValues, Map.get(node, :initial_values))
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
