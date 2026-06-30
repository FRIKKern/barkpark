defmodule BarkparkWeb.QueryController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Content.Envelope
  alias Barkpark.Content.Expand

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  action_fallback BarkparkWeb.FallbackController

  def index(conn, %{"dataset" => dataset, "type" => type} = params) do
    if preview?(conn) or authed?(conn) or Content.schema_public?(type, dataset, scope_opts(conn)) do
      t0 = System.monotonic_time(:microsecond)
      perspective = resolve_perspective(conn, params)
      limit = parse_int(params["limit"], 100)
      offset = parse_int(params["offset"], 0)
      order = parse_order_param(params["order"])
      filter_map = params |> Map.get("filter", %{}) |> normalize_filter_map()
      expand_spec = parse_expand(params["expand"])

      schema = fetch_schema(conn, type, dataset)
      caller_context = CallerContext.from_conn(conn)

      # WS-B MEDIUM-4: reject a filter/order that targets a field this caller may
      # not SEE — otherwise the WHERE/ORDER becomes an oracle to binary-search or
      # sort by a hidden field's value even though the body is redacted. Checked
      # BEFORE the query so the COUNT/order never runs over a forbidden field.
      case forbidden_query_field(filter_map, order, schema, caller_context) do
        nil ->
          docs =
            Content.list_documents(
              type,
              dataset,
              [
                perspective: perspective,
                filter_map: filter_map,
                limit: limit,
                offset: offset,
                order: order
              ] ++ scope_opts(conn)
            )

          rendered =
            Envelope.render_many(docs, schema, caller_context)
            |> Expand.expand(
              expand_spec,
              dataset,
              [published_only: anon_pinned?(conn), caller_context: caller_context] ++
                scope_opts(conn)
            )
            |> project_fields(parse_fields(params["fields"]))

          inner =
            %{
              perspective: to_string(perspective),
              documents: rendered,
              count: length(docs),
              limit: limit,
              offset: offset
            }
            |> maybe_put_total(conn, params, type, dataset, perspective, filter_map)

          etag = list_etag(dataset, type, rendered)
          respond(conn, inner, dataset, list_sync_tags(dataset, type, rendered), etag, t0)

        field ->
          reject_forbidden_field(conn, field)
      end
    else
      {:error, :not_found}
    end
  end

  def show(conn, %{"dataset" => dataset, "type" => type, "doc_id" => doc_id} = params) do
    cond do
      # NO anonymous caller may fetch a draft by id — neither a read-only
      # public share nor a plain tokenless read of a public schema (publish is
      # the act of making content public; a `drafts.` id is unpublished by
      # definition). Rejected as not-found BEFORE any get_document call — the
      # same 404 path the controller already returns for a missing doc. An
      # `:edit` share and any token/preview caller pass through unchanged.
      anon_pinned?(conn) and String.starts_with?(doc_id, "drafts.") ->
        {:error, :not_found}

      preview?(conn) or authed?(conn) or Content.schema_public?(type, dataset, scope_opts(conn)) ->
        show_doc(conn, dataset, type, doc_id, params)

      true ->
        {:error, :not_found}
    end
  end

  defp show_doc(conn, dataset, type, doc_id, params) do
    t0 = System.monotonic_time(:microsecond)
    expand_spec = parse_expand(params["expand"])

    with {:ok, doc} <- Content.get_document(doc_id, type, dataset, scope_opts(conn)) do
      schema = fetch_schema(conn, type, dataset)
      caller_context = CallerContext.from_conn(conn)

      rendered =
        [Envelope.render(doc, schema, caller_context)]
        |> Expand.expand(
          expand_spec,
          dataset,
          [published_only: anon_pinned?(conn), caller_context: caller_context] ++
            scope_opts(conn)
        )
        |> project_fields(parse_fields(params["fields"]))
        |> hd()

      etag = doc_etag(doc)
      sync_tags = doc_sync_tags(dataset, type, doc.doc_id)
      respond(conn, rendered, dataset, sync_tags, etag, t0)
    end
  end

  defp respond(conn, inner, dataset, sync_tags, etag, t0) do
    elapsed_ms = div(System.monotonic_time(:microsecond) - t0, 1000)

    conn =
      conn
      |> put_resp_header("etag", ~s("#{etag}"))
      |> maybe_vendor_content_type()

    case get_req_header(conn, "if-none-match") do
      [hv | _] ->
        if etag_matches?(hv, etag) do
          conn |> send_resp(304, "") |> halt()
        else
          respond_json(conn, inner, sync_tags, etag, elapsed_ms, dataset)
        end

      _ ->
        respond_json(conn, inner, sync_tags, etag, elapsed_ms, dataset)
    end
  end

  defp respond_json(conn, inner, sync_tags, etag, elapsed_ms, dataset) do
    if Map.get(conn.assigns, :barkpark_filterresponse, true) do
      json(conn, envelope(inner, sync_tags, etag, elapsed_ms, dataset, scope_opts(conn)))
    else
      json(conn, inner)
    end
  end

  defp maybe_vendor_content_type(conn) do
    if conn.assigns[:barkpark_vendor_accept] do
      put_resp_content_type(conn, "application/vnd.barkpark+json", "utf-8")
    else
      conn
    end
  end

  defp envelope(result, sync_tags, etag, ms, dataset, scope) do
    %{
      result: result,
      syncTags: sync_tags,
      ms: ms,
      etag: etag,
      schemaHash: Content.schema_hash_for_dataset(dataset, scope)
    }
  end

  defp etag_matches?(header, etag) do
    header
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&strip_etag/1)
    |> Enum.any?(fn v -> v == etag or v == "*" end)
  end

  defp strip_etag(v) do
    v |> String.trim_leading("W/") |> String.trim() |> String.trim("\"")
  end

  defp list_etag(dataset, type, rendered) do
    ids = Enum.map(rendered, & &1["_id"]) |> Enum.sort()
    payload = "#{dataset}|#{type}|" <> Enum.join(ids, ",")
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower) |> binary_part(0, 32)
  end

  defp doc_etag(%{rev: rev}) when is_binary(rev) and rev != "", do: rev
  defp doc_etag(_), do: "0"

  defp list_sync_tags(dataset, type, rendered) do
    type_tag = "bp:ds:#{dataset}:type:#{type}"
    doc_tags = for d <- rendered, do: "bp:ds:#{dataset}:doc:#{Content.published_id(d["_id"])}"
    [type_tag | doc_tags]
  end

  defp doc_sync_tags(dataset, type, doc_id) do
    [
      "bp:ds:#{dataset}:doc:#{Content.published_id(doc_id)}",
      "bp:ds:#{dataset}:type:#{type}"
    ]
  end

  # Tenancy scope opts come from BarkparkWeb.ScopeHelpers.scope_opts/1, the
  # shared seam over the conn assigns set by ResolveWorkspace / ResolveProject
  # (scoped routes) or AssignDefaultScope (flat back-compat routes). Completes
  # the cross-dataset read-leak fix at the query layer: the route-level
  # membership gate decides WHETHER the caller reaches a workspace; this WHERE
  # workspace_id filter decides WHICH rows come back.

  # Resolve the type's schema (for field-visibility redaction in Envelope.render)
  # under the SAME tenant scope as the document read. Nil on miss — redaction
  # then falls back to the schema-free encrypted-field guard only.
  defp fetch_schema(conn, type, dataset) do
    case Content.get_schema(type, dataset, scope_opts(conn)) do
      {:ok, schema} -> schema
      _ -> nil
    end
  end

  # WS-B MEDIUM-4 guard: the first filter/order field NOT readable by this
  # caller (per the type schema + CallerContext), or nil when every referenced
  # field is allowed. Internal/admin callers and undeclared/promoted fields pass
  # through `Envelope.field_readable?/3` unrestricted.
  defp forbidden_query_field(filter_map, order, schema, caller_context) do
    (Map.keys(filter_map) ++ order_fields(order))
    |> Enum.find(fn field -> not Envelope.field_readable?(schema, field, caller_context) end)
  end

  defp order_fields(specs) when is_list(specs), do: Enum.flat_map(specs, &order_fields/1)
  defp order_fields({:field, field, _dir}), do: [field]
  defp order_fields(_), do: []

  defp reject_forbidden_field(conn, field) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "forbidden_field",
      message: "filter/order references a field you are not authorized to read",
      field: field
    })
  end

  defp preview?(conn), do: is_binary(conn.assigns[:forced_perspective])

  defp authed?(conn), do: not is_nil(conn.assigns[:api_token])

  defp resolve_perspective(conn, params) do
    if anon_pinned?(conn) do
      # EVERY plain anonymous caller is pinned to the published perspective:
      # the `?perspective=drafts|raw` param is IGNORED so a tokenless reader
      # can never pull unpublished/draft content — neither via a read-only
      # public share NOR via an ordinary public-visibility schema read (found
      # live 2026-06-10: `curl …?perspective=drafts` with no token returned
      # every draft). A token, a preview token (forced_perspective) or an
      # `:edit` share falls through to the unchanged forced/param logic.
      :published
    else
      case conn.assigns[:forced_perspective] do
        nil -> parse_perspective(Map.get(params, "perspective", "published"))
        forced -> parse_perspective(forced)
      end
    end
  end

  # True when the caller is pinned to published-only reads: no token, no
  # preview token, and not an `:edit` share. This covers BOTH the read-only
  # public share AND the plain tokenless read of a public-visibility schema —
  # the two anonymous read paths must enforce the same invariant (an anonymous
  # caller can never pull drafts; publish is the act of making content
  # public). An `:edit` share is deliberately exempt: it is an anonymous
  # editing surface, and its draft visibility is part of that contract.
  defp anon_pinned?(conn) do
    not authed?(conn) and not preview?(conn) and
      not (conn.assigns[:share_public] == true and conn.assigns[:share_access] == :edit)
  end

  defp parse_int(nil, d), do: d

  defp parse_int(s, d) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> d
    end
  end

  defp parse_int(n, _) when is_integer(n), do: n

  # Adds the total matching count (the paginator total) only when `?count=true` —
  # it's a second DB query (COUNT over the filtered set), so it stays opt-in.
  defp maybe_put_total(inner, conn, %{"count" => "true"}, type, dataset, perspective, filter_map) do
    total =
      Content.count_documents(
        type,
        dataset,
        [perspective: perspective, filter_map: filter_map] ++ scope_opts(conn)
      )

    Map.put(inner, :total, total)
  end

  defp maybe_put_total(inner, _conn, _params, _type, _dataset, _perspective, _filter_map),
    do: inner

  # Comma-separated specs → multi-field sort (`title:asc,price:desc` sorts by title,
  # then price as a tiebreak). A single spec stays a single parsed value (back-compat).
  defp parse_order_param(s) when is_binary(s) do
    case String.split(s, ",", trim: true) do
      [single] -> parse_order(single)
      [_ | _] = multi -> Enum.map(multi, &parse_order/1)
      [] -> :updated_at_desc
    end
  end

  defp parse_order_param(other), do: parse_order(other)

  defp parse_order("_updatedAt:asc"), do: :updated_at_asc
  defp parse_order("_updatedAt:desc"), do: :updated_at_desc
  defp parse_order("_createdAt:asc"), do: :created_at_asc
  defp parse_order("_createdAt:desc"), do: :created_at_desc

  # `<field>:asc` / `<field>:desc` — order by any document field, including a
  # dot-path into JSONB content (`price.amount:desc`). apply_order in
  # Content.Query resolves it against the promoted columns / nested JSONB content
  # (it already dot-splits via nested_segments). The dot-path group MUST match
  # the SDK's order validator — without it, `price.amount:desc` failed this regex
  # and silently fell back to :updated_at_desc, so nested-field sorts the SDK
  # advertised + sent were ignored.
  defp parse_order(spec) when is_binary(spec) do
    case Regex.run(~r/^([a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)*):(asc|desc)$/, spec) do
      [_, field, "asc"] -> {:field, field, :asc}
      [_, field, "desc"] -> {:field, field, :desc}
      _ -> :updated_at_desc
    end
  end

  defp parse_order(_), do: :updated_at_desc

  defp parse_perspective("drafts"), do: :drafts
  defp parse_perspective("raw"), do: :raw
  defp parse_perspective(_), do: :published

  defp parse_expand(nil), do: []
  defp parse_expand(""), do: []
  defp parse_expand("false"), do: []
  defp parse_expand("true"), do: :all

  defp parse_expand(fields) when is_binary(fields) do
    fields
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # `?fields=title,slug` — projection. Returns the requested content field names, or
  # nil (no projection → whole document) when the param is absent/blank.
  defp parse_fields(s) when is_binary(s) do
    case s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      fields -> fields
    end
  end

  defp parse_fields(_), do: nil

  # Keep each rendered doc's system keys (`_id`, `_type`, `_rev`, …) plus the
  # selected content fields; drop the rest. nil/empty → no projection (pass through).
  defp project_fields(rendered, nil), do: rendered

  defp project_fields(rendered, fields) do
    # Match on the TOP-LEVEL segment of each selected field, so a dotted path
    # (`meta.seo`) keeps its parent object (`meta`) rather than silently dropping it.
    # Projection is top-level — a dotted select yields the whole parent, not a sub-slice.
    keep = fields |> Enum.map(&(&1 |> String.split(".") |> hd())) |> MapSet.new()

    Enum.map(rendered, fn doc ->
      Map.filter(doc, fn {k, _v} -> String.starts_with?(k, "_") or MapSet.member?(keep, k) end)
    end)
  end

  defp normalize_filter_map(map) when is_map(map) do
    Enum.into(map, %{}, fn
      {field, %{} = ops} -> {field, Enum.into(ops, %{}, &normalize_filter_op/1)}
      {field, value} -> {field, value}
    end)
  end

  # Accept a flat scalar string as a filter — the form both the CLI (`--filter
  # 'status=draft'`) and the TUI use without Plug's nested bracket syntax. Two
  # families, tried in order:
  #   1. operator forms — `=`/`==`/`!=`/`>`/`>=`/`<`/`<=` plus the CSS-selector
  #      shorthands `^=`/`$=`/`*=` (starts/ends/contains).
  #   2. keyword forms — `is null` / `is not null`, and `in` / `not in`.
  # Operators are tried FIRST so a value that itself contains ` is `/` in ` after
  # an operator is preserved (`notes=a in b` → eq value `a in b`, NOT an `in`
  # filter). Keyword forms only apply to an operator-less string.
  defp normalize_filter_map(s) when is_binary(s) and byte_size(s) > 0 do
    trimmed = String.trim(s)
    parse_scalar_op(trimmed) || parse_scalar_keyword(trimmed) || %{}
  end

  defp normalize_filter_map(_), do: %{}

  # Split on the LEFTMOST operator (2-char ops `^=`/`$=`/`*=`/`>=`/`<=`/`!=`/`==`
  # take precedence at a given index). The non-greedy field capture keeps the split
  # at the first operator, so a value that itself contains an operator char is
  # preserved (`notes=a>b` → field `notes`, eq, value `a>b`). `=`/`==` mean equality;
  # `^=`/`$=`/`*=` are prefix/suffix/substring; the rest map to the corresponding
  # nested op (`status!=archived` → `%{"status" => %{"neq" => "archived"}}`). Value
  # whitespace-trimmed, one pair of quotes stripped. Returns nil when no operator.
  defp parse_scalar_op(trimmed) do
    case Regex.run(~r/^(.+?)\s*(\^=|\$=|\*=|>=|<=|!=|==|>|<|=)\s*(.*)$/, trimmed) do
      [_, field, sym, value] ->
        v = unquote_filter_value(value)

        case scalar_op(sym) do
          "eq" -> %{String.trim(field) => v}
          op -> %{String.trim(field) => %{op => v}}
        end

      _ ->
        nil
    end
  end

  # Keyword forms (only reached for operator-less strings): `<field> is null` /
  # `is not null` (the scalar form of the SDK's eq/neq null), then `in` / `not in`.
  defp parse_scalar_keyword(trimmed) do
    case Regex.run(~r/^(.+?)\s+is\s+(not\s+)?null$/i, trimmed) do
      [_, field | rest] ->
        not? = String.trim(List.first(rest) || "") != ""
        %{String.trim(field) => %{"is" => if(not?, do: "notnull", else: "null")}}

      nil ->
        parse_scalar_in(trimmed)
    end
  end

  # `<field> in a,b,c` / `<field> not in a,b,c` — membership against a comma list
  # (the scalar form of the SDK's `.in` / `.nin`). `not in` is matched first so the
  # leading `not` isn't folded into the field capture.
  defp parse_scalar_in(trimmed) do
    case Regex.run(~r/^(.+?)\s+not\s+in\s+(.+)$/i, trimmed) do
      [_, field, csv] ->
        %{String.trim(field) => %{"nin" => split_csv(csv)}}

      nil ->
        case Regex.run(~r/^(.+?)\s+in\s+(.+)$/i, trimmed) do
          [_, field, csv] -> %{String.trim(field) => %{"in" => split_csv(csv)}}
          nil -> nil
        end
    end
  end

  defp split_csv(s), do: s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp scalar_op(">="), do: "gte"
  defp scalar_op("<="), do: "lte"
  defp scalar_op("!="), do: "neq"
  defp scalar_op(">"), do: "gt"
  defp scalar_op("<"), do: "lt"
  defp scalar_op("^="), do: "startsWith"
  defp scalar_op("$="), do: "endsWith"
  defp scalar_op("*="), do: "contains"
  defp scalar_op(_), do: "eq"

  # Trim whitespace, then strip exactly ONE pair of surrounding double-quotes
  # when both ends carry one (`"published"` → `published`). Inner quotes are
  # kept (`say "hi"` unchanged); a lone quote char is not stripped.
  defp unquote_filter_value(v) do
    trimmed = String.trim(v)

    with <<?", rest::binary>> when byte_size(rest) >= 1 <- trimmed,
         true <- String.ends_with?(rest, "\"") do
      binary_part(rest, 0, byte_size(rest) - 1)
    else
      _ -> trimmed
    end
  end

  defp normalize_filter_op({op, csv}) when op in ["in", "nin"] and is_binary(csv) do
    {op, csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)}
  end

  defp normalize_filter_op(pair), do: pair
end
