defmodule BarkparkWeb.QueryController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
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
        Envelope.render_many(docs)
        |> Expand.expand(
          expand_spec,
          dataset,
          [published_only: anon_pinned?(conn)] ++ scope_opts(conn)
        )

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
      rendered =
        [Envelope.render(doc)]
        |> Expand.expand(
          expand_spec,
          dataset,
          [published_only: anon_pinned?(conn)] ++ scope_opts(conn)
        )
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

  # `<field>:asc` / `<field>:desc` — order by any document field. apply_order in
  # Content.Query resolves it against the promoted columns / JSONB content.
  defp parse_order(spec) when is_binary(spec) do
    case Regex.run(~r/^([a-zA-Z][a-zA-Z0-9_]*):(asc|desc)$/, spec) do
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

  defp normalize_filter_map(map) when is_map(map) do
    Enum.into(map, %{}, fn
      {field, %{} = ops} -> {field, Enum.into(ops, %{}, &normalize_filter_op/1)}
      {field, value} -> {field, value}
    end)
  end

  # Accept a flat scalar string as a simple equality filter.
  # Supports `field=value`, `field==value`, and the TUI apiclient's GROQ-ish
  # `field == "value"` wire form (Client.Query has shipped that for months and
  # is authoritative for it) — so both the CLI (`--filter 'status=draft'`) and
  # the TUI work without needing Plug's nested bracket syntax.
  # Only the first `==`/`=` is split on so values that contain `=` are
  # preserved. After the split both sides are whitespace-trimmed and ONE pair
  # of surrounding double-quotes is stripped from the value
  # (`status == "published"` → %{"status" => "published"}); a bare value or a
  # value with only inner quotes is left untouched.
  defp normalize_filter_map(s) when is_binary(s) and byte_size(s) > 0 do
    trimmed = String.trim(s)

    # `<field> is null` / `<field> is not null` — null/absence checks (the scalar
    # form of the SDK's eq/neq null → the `is` op). Matched before the operator
    # split since `is` is a keyword, not an operator char.
    case Regex.run(~r/^(.+?)\s+is\s+(not\s+)?null$/i, trimmed) do
      [_, field | rest] ->
        not? = String.trim(List.first(rest) || "") != ""
        %{String.trim(field) => %{"is" => if(not?, do: "notnull", else: "null")}}

      nil ->
        # Split on the LEFTMOST operator (2-char ops `^=`/`$=`/`>=`/`<=`/`!=`/`==`
        # take precedence at a given index). The non-greedy field capture keeps the
        # split at the first operator, so a value that itself contains an operator
        # char is preserved (`notes=a>b` → field `notes`, eq, value `a>b`). `=`/`==`
        # mean equality; `^=`/`$=` are prefix/suffix (CSS-selector style); the rest
        # map to the corresponding nested op (`status!=archived` → `%{"status" =>
        # %{"neq" => "archived"}}`). Value whitespace-trimmed, one pair of quotes stripped.
        case Regex.run(~r/^(.+?)\s*(\^=|\$=|>=|<=|!=|==|>|<|=)\s*(.*)$/, trimmed) do
          [_, field, sym, value] ->
            v = unquote_filter_value(value)

            case scalar_op(sym) do
              "eq" -> %{String.trim(field) => v}
              op -> %{String.trim(field) => %{op => v}}
            end

          _ ->
            %{}
        end
    end
  end

  defp normalize_filter_map(_), do: %{}

  defp scalar_op(">="), do: "gte"
  defp scalar_op("<="), do: "lte"
  defp scalar_op("!="), do: "neq"
  defp scalar_op(">"), do: "gt"
  defp scalar_op("<"), do: "lt"
  defp scalar_op("^="), do: "startsWith"
  defp scalar_op("$="), do: "endsWith"
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
