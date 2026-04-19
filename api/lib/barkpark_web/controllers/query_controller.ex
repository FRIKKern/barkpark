defmodule BarkparkWeb.QueryController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.Envelope
  alias Barkpark.Content.Expand

  action_fallback BarkparkWeb.FallbackController

  def index(conn, %{"dataset" => dataset, "type" => type} = params) do
    if preview?(conn) or Content.schema_public?(type, dataset) do
      t0 = System.monotonic_time(:microsecond)
      perspective = resolve_perspective(conn, params)
      limit = parse_int(params["limit"], 100)
      offset = parse_int(params["offset"], 0)
      order = parse_order(params["order"])
      filter_map = params |> Map.get("filter", %{}) |> normalize_filter_map()
      expand_spec = parse_expand(params["expand"])

      docs =
        Content.list_documents(type, dataset,
          perspective: perspective,
          filter_map: filter_map,
          limit: limit,
          offset: offset,
          order: order
        )

      rendered = Envelope.render_many(docs) |> Expand.expand(expand_spec, dataset)

      inner = %{
        perspective: to_string(perspective),
        documents: rendered,
        count: length(docs),
        limit: limit,
        offset: offset
      }

      etag = list_etag(dataset, type, rendered)
      respond(conn, inner, dataset, list_sync_tags(dataset, type, rendered), etag, t0)
    else
      {:error, :not_found}
    end
  end

  def show(conn, %{"dataset" => dataset, "type" => type, "doc_id" => doc_id} = params) do
    if preview?(conn) or Content.schema_public?(type, dataset) do
      t0 = System.monotonic_time(:microsecond)
      expand_spec = parse_expand(params["expand"])

      with {:ok, doc} <- Content.get_document(doc_id, type, dataset) do
        rendered =
          [Envelope.render(doc)]
          |> Expand.expand(expand_spec, dataset)
          |> hd()

        etag = doc_etag(doc)
        sync_tags = doc_sync_tags(dataset, type, doc.doc_id)
        respond(conn, rendered, dataset, sync_tags, etag, t0)
      end
    else
      {:error, :not_found}
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
      json(conn, envelope(inner, sync_tags, etag, elapsed_ms, dataset))
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

  defp envelope(result, sync_tags, etag, ms, dataset) do
    %{
      result: result,
      syncTags: sync_tags,
      ms: ms,
      etag: etag,
      schemaHash: Content.schema_hash_for_dataset(dataset)
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

  defp preview?(conn), do: is_binary(conn.assigns[:forced_perspective])

  defp resolve_perspective(conn, params) do
    case conn.assigns[:forced_perspective] do
      nil -> parse_perspective(Map.get(params, "perspective", "published"))
      forced -> parse_perspective(forced)
    end
  end

  defp parse_int(nil, d), do: d
  defp parse_int(s, d) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> d
    end
  end
  defp parse_int(n, _) when is_integer(n), do: n

  defp parse_order("_updatedAt:asc"), do: :updated_at_asc
  defp parse_order("_updatedAt:desc"), do: :updated_at_desc
  defp parse_order("_createdAt:asc"), do: :created_at_asc
  defp parse_order("_createdAt:desc"), do: :created_at_desc
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

  defp normalize_filter_map(_), do: %{}

  defp normalize_filter_op({"in", csv}) when is_binary(csv) do
    {"in", csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)}
  end

  defp normalize_filter_op(pair), do: pair
end
