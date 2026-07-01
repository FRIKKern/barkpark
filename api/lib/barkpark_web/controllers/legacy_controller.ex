defmodule BarkparkWeb.LegacyController do
  @moduledoc "Backward-compatible API matching the Go TUI's original endpoints."

  use BarkparkWeb, :controller

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Envelope}

  action_fallback BarkparkWeb.FallbackController

  @dataset "production"

  def index(conn, %{"type" => type} = params) do
    filter_map = parse_legacy_filter(Map.get(params, "filter"))
    schema = fetch_schema(conn, type)
    caller_context = CallerContext.from_conn(conn)

    # WS-B MEDIUM-4 (legacy path): a `filter=field=value` over a field the caller
    # may not SEE turns row-selection + `count` into an equality oracle on a
    # hidden value, even though the response BODY is redacted. Reject BEFORE the
    # query so the WHERE never runs over a forbidden field — the same guard
    # /v1/data/query enforces, now closed on the legacy surface too.
    case forbidden_filter_field(filter_map, schema, caller_context) do
      nil ->
        documents =
          Content.list_documents(
            type,
            @dataset,
            [filter_map: filter_map, limit: 10_000] ++ scope_opts(conn)
          )

        json(conn, %{
          type: type,
          documents: Enum.map(documents, &render_legacy_doc(&1, schema, caller_context)),
          count: length(documents)
        })

      field ->
        reject_forbidden_field(conn, field)
    end
  end

  def show(conn, %{"type" => type, "id" => doc_id}) do
    with {:ok, doc} <- Content.get_document(doc_id, type, @dataset, scope_opts(conn)) do
      json(conn, render_legacy_doc(doc, fetch_schema(conn, type), CallerContext.from_conn(conn)))
    end
  end

  def create(conn, %{"type" => type} = params) do
    attrs = Map.drop(params, ["type"])

    # Map legacy format to internal format
    doc_id = Map.get(attrs, "id") || Map.get(attrs, "doc_id")

    internal_attrs = %{
      "doc_id" => doc_id,
      "title" => Map.get(attrs, "title"),
      "status" => Map.get(attrs, "status", "draft"),
      "content" => Map.drop(attrs, ["id", "doc_id", "title", "status", "updatedAt"])
    }

    case Content.upsert_document(
           type,
           internal_attrs,
           @dataset,
           [source: :api] ++ scope_opts(conn)
         ) do
      {:ok, doc} ->
        # Echo the created doc through the REAL caller (same redaction boundary
        # as a read), not the :internal no-redaction sentinel — uniform with the
        # mutation echo. The caller supplied this content, so redaction only
        # hides schema-default private values it never set; admins see all.
        conn
        |> put_status(:created)
        |> json(render_legacy_doc(doc, fetch_schema(conn, type), CallerContext.from_conn(conn)))

      # Both a plugin lifecycle veto ({:halted, reason}) and an Ecto changeset
      # error route through action_fallback → FallbackController → the canonical
      # error envelope. (The halt used to be a bare %{error: "halted", reason:
      # reason} with no code/request_id — invisible to the bp CLI + SDK.)
      {:error, _} = err ->
        err
    end
  end

  def delete(conn, %{"type" => type, "id" => doc_id}) do
    case Content.delete_document(doc_id, type, @dataset, [source: :api] ++ scope_opts(conn)) do
      {:ok, _} ->
        json(conn, %{deleted: doc_id})

      # Halts + other errors fall through to action_fallback for the canonical
      # envelope (was a bare %{error: "halted", reason: reason}).
      {:error, _} = err ->
        err
    end
  end

  def schemas(conn, _params) do
    schemas = Content.list_schemas(@dataset, scope_opts(conn))

    json(
      conn,
      Enum.map(schemas, fn s ->
        %{
          name: s.name,
          title: s.title,
          icon: s.icon,
          fields: s.fields
        }
      end)
    )
  end

  # WS-B MEDIUM-4 guard (legacy): the first filtered field NOT readable by this
  # caller (per schema + CallerContext), or nil when every key is allowed.
  # Mirrors QueryController.forbidden_query_field — internal/admin callers and
  # undeclared/promoted fields pass through `Envelope.field_readable?/3`.
  defp forbidden_filter_field(filter_map, schema, caller_context) do
    Map.keys(filter_map)
    |> Enum.find(fn field -> not Envelope.field_readable?(schema, field, caller_context) end)
  end

  defp reject_forbidden_field(conn, field) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "forbidden_field",
      message: "filter references a field you are not authorized to read",
      field: field
    })
  end

  # Parse legacy "field=value" filter string into a map for list_documents/3.
  defp parse_legacy_filter(nil), do: %{}
  defp parse_legacy_filter(""), do: %{}

  defp parse_legacy_filter(s) do
    case String.split(s, "=", parts: 2) do
      [field, value] -> %{field => value}
      _ -> %{}
    end
  end

  # Resolve the type's schema for field-visibility redaction, under the same
  # tenant scope as the read. Nil on miss — redaction then falls back to the
  # schema-free encrypted-ciphertext guard.
  defp fetch_schema(conn, type) do
    case Content.get_schema(type, @dataset, scope_opts(conn)) do
      {:ok, schema} -> schema
      _ -> nil
    end
  end

  # WS-B HIGH-1: this legacy surface formerly dumped raw `doc.content` into
  # `:values`, bypassing the Envelope redaction boundary. Route the content
  # through `Envelope.render/3` (the single chokepoint) so a `private` /
  # `owner_only` / `readable_by` / encrypted field is dropped for a
  # non-authorized caller, then re-nest the SURVIVING content fields under
  # `:values` to preserve the legacy wire shape. With no private fields the
  # output is byte-identical to before.
  defp render_legacy_doc(doc, schema, caller_context) do
    base = %{
      id: doc.doc_id,
      title: doc.title,
      status: doc.status,
      updatedAt: doc.updated_at
    }

    values =
      doc
      |> Envelope.render(schema, caller_context)
      |> Map.reject(fn {k, _v} -> String.starts_with?(k, "_") or k == "title" end)

    if map_size(values) > 0 do
      Map.put(base, :values, values)
    else
      base
    end
  end
end
