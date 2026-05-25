defmodule BarkparkWeb.V1.MediaController do
  @moduledoc """
  Versioned media API at `/v1/media/:dataset`.

  Returns unified assets (blob + `mediaAsset` metadata). Binary bytes are
  still served from `/media/files/*path`.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Auth
  alias Barkpark.Content.Errors
  alias Barkpark.Media
  alias Barkpark.Media.{Access, AssetResponse, Checkout, Relations, SearchIntelligence}
  alias Barkpark.Search.{SurfaceConfigs, Synonyms}
  alias BarkparkWeb.{SearchIntel, V1.MediaSearchParams}

  action_fallback BarkparkWeb.FallbackController

  @default_limit 50
  @max_limit 500

  def search(conn, %{"dataset" => dataset} = params) do
    t0 = System.monotonic_time(:microsecond)
    opts = MediaSearchParams.parse(params)
    {files, total, facets, meta} = Media.search_files(dataset, opts)
    docs = Media.asset_docs_for_files(files, dataset)
    render_opts = render_opts(conn, params)

    hits =
      Enum.map(files, fn file ->
        AssetResponse.render(file, Map.get(docs, file.id), render_opts)
      end)

    ms = div(System.monotonic_time(:microsecond) - t0, 1000)

    record_opts = [
      actor_key: SearchIntel.actor_key(conn),
      parent_event_id: SearchIntel.parent_event_id(conn),
      session_key: SearchIntel.session_key(conn),
      source: SearchIntel.source(conn, "explorer"),
      record: SearchIntel.should_record?(conn),
      tags: SearchIntel.tags(conn),
      metadata: search_metadata(meta)
    ]

    record_result =
      SearchIntelligence.record(dataset, params, total, ms, record_opts)

    search_event_id =
      case record_result do
        {:ok, id} -> id
        _ -> nil
      end

    next_cursor = Barkpark.Media.Search.next_cursor(files)
    has_more = next_cursor != nil and length(files) >= opts[:limit]

    json(conn, %{
      result: %{
        hits: hits,
        total: total,
        limit: opts[:limit],
        offset: opts[:offset],
        facets: facets,
        nextCursor: next_cursor,
        hasMore: has_more
      },
      parsedQuery: meta[:parsed],
      highlights: meta[:highlights] || %{},
      recovery: meta[:recovery],
      searchEventId: search_event_id,
      syncTags: ["bp:ds:#{dataset}:media"],
      ms: ms
    })
  end

  def search_insights(conn, %{"dataset" => dataset} = params) do
    period = params["period"] || "week"

    opts = [period: period]

    opts =
      case SearchIntel.parse_period_start(params["periodStart"]) do
        %Date{} = date -> Keyword.put(opts, :period_start, date)
        _ -> opts
      end

    result = SearchIntelligence.insights(dataset, opts)

    json(conn, %{result: result, syncTags: ["bp:ds:#{dataset}:media:search:insights"]})
  end

  def search_synonyms(conn, %{"dataset" => dataset}) do
    json(conn, %{
      result: Synonyms.list("media", dataset),
      syncTags: ["bp:ds:#{dataset}:media:search:synonyms"]
    })
  end

  def create_search_synonym(conn, %{"dataset" => dataset} = params) do
    case Synonyms.create("media", dataset, params) do
      {:ok, row} ->
        json(conn, %{result: row, syncTags: ["bp:ds:#{dataset}:media:search:synonyms"]})

      {:error, %Ecto.Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def promote_search_synonym(conn, %{"dataset" => dataset} = params) do
    case Synonyms.promote("media", dataset, params) do
      {:ok, row} ->
        json(conn, %{result: row, syncTags: ["bp:ds:#{dataset}:media:search:synonyms"]})

      {:error, :missing_fields} ->
        conn |> put_status(422) |> json(%{error: %{message: "from and to are required"}})

      {:error, %Ecto.Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def preview_search_synonym(conn, %{"dataset" => dataset} = params) do
    q = params["q"] || params["from"]
    result = Synonyms.preview("media", dataset, q, params)
    json(conn, %{result: result})
  end

  def search_settings(conn, %{"dataset" => dataset}) do
    json(conn, %{
      result: SurfaceConfigs.get("media", dataset),
      syncTags: ["bp:ds:#{dataset}:media:search:settings"]
    })
  end

  def update_search_settings(conn, %{"dataset" => dataset} = params) do
    case SurfaceConfigs.upsert("media", dataset, params) do
      {:ok, row} ->
        json(conn, %{result: row, syncTags: ["bp:ds:#{dataset}:media:search:settings"]})

      {:error, %Ecto.Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def delete_search_synonym(conn, %{"dataset" => dataset, "id" => id}) do
    case Synonyms.delete(id, "media", dataset) do
      :ok ->
        json(conn, %{ok: true, syncTags: ["bp:ds:#{dataset}:media:search:synonyms"]})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{message: "synonym not found"}})
    end
  end

  def search_suggestions(conn, %{"dataset" => dataset} = params) do
    prefix = params["q"] || params["prefix"]
    limit = parse_int(params["limit"], 8) |> min(20)

    result =
      SearchIntelligence.suggestions(
        dataset,
        SearchIntel.actor_key(conn),
        prefix,
        limit: limit
      )

    json(conn, %{
      result: result,
      syncTags: ["bp:ds:#{dataset}:media:search"]
    })
  end

  def search_interaction(conn, %{"dataset" => dataset} = params) do
    record_opts = [
      actor_key: SearchIntel.actor_key(conn),
      session_key: SearchIntel.session_key(conn),
      source: SearchIntel.source(conn, "explorer"),
      disabled: SearchIntel.recording_disabled?(conn)
    ]

    case SearchIntelligence.record_interaction(dataset, params, record_opts) do
      {:ok, id} -> json(conn, %{ok: true, interactionEventId: id})
      _ -> json(conn, %{ok: true})
    end
  end

  def index(conn, %{"dataset" => dataset} = params) do
    t0 = System.monotonic_time(:microsecond)

    opts = [
      limit: parse_int(params["limit"], @default_limit) |> min(@max_limit),
      offset: parse_int(params["offset"], 0),
      mime_type: blank_to_nil(params["type"] || params["mimeType"]),
      kind: blank_to_nil(params["kind"]),
      q: blank_to_nil(params["q"])
    ]

    {files, total} = Media.query_files(dataset, opts)
    docs = Media.asset_docs_for_files(files, dataset)
    render_opts = render_opts(conn, params)

    assets =
      Enum.map(files, fn file ->
        AssetResponse.render(file, Map.get(docs, file.id), render_opts)
      end)

    ms = div(System.monotonic_time(:microsecond) - t0, 1000)

    json(conn, %{
      result: %{
        assets: assets,
        count: total,
        limit: opts[:limit],
        offset: opts[:offset]
      },
      syncTags: ["bp:ds:#{dataset}:media"],
      ms: ms
    })
  end

  def show(conn, %{"dataset" => dataset, "id" => id} = params) do
    t0 = System.monotonic_time(:microsecond)

    with {:ok, file} <- Media.get_file(id),
         true <- file.dataset == dataset do
      doc = Media.asset_doc_for_file(file, dataset)
      ms = div(System.monotonic_time(:microsecond) - t0, 1000)

      json(conn, %{
        result: AssetResponse.render(file, doc, render_opts(conn, params, dataset: dataset)),
        syncTags: sync_tags(dataset, file.id),
        ms: ms
      })
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def relations(conn, %{"dataset" => dataset, "id" => id} = params) do
    with {:ok, file} <- Media.get_file(id),
         :ok <- ensure_dataset(file, dataset) do
      graph = Relations.graph(file, dataset, render_opts(conn, params, dataset: dataset))

      json(conn, %{
        result: graph,
        syncTags: sync_tags(dataset, file.id)
      })
    end
  end

  def upload(conn, %{"dataset" => dataset, "file" => upload} = params) do
    with :ok <- require_write(conn) do
      case Media.upload(upload, dataset) do
        {:ok, file} ->
          doc = Media.asset_doc_for_file(file, dataset)

          conn
          |> put_status(:created)
          |> json(%{
            result: AssetResponse.render(file, doc, render_opts(conn, params, dataset: dataset)),
            syncTags: sync_tags(dataset, file.id)
          })

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def upload(conn, %{"dataset" => _dataset}) do
    env =
      {:error, :malformed}
      |> Errors.to_envelope(conn)
      |> Map.put(:message, "missing 'file' field in multipart upload")

    conn
    |> put_status(:bad_request)
    |> json(%{error: Map.delete(env, :status)})
  end

  def update(conn, %{"dataset" => dataset, "id" => id} = params) do
    metadata = metadata_params(params)

    with :ok <- require_write(conn),
         {:ok, file} <- Media.get_file(id),
         :ok <- ensure_dataset(file, dataset),
         doc = Media.asset_doc_for_file(file, dataset),
         :ok <- ensure_edit(conn, file, doc),
         {:ok, doc} <- Media.patch_asset_metadata(file, metadata, dataset) do
      json(conn, %{
        result: AssetResponse.render(file, doc, render_opts(conn, params, dataset: dataset)),
        syncTags: sync_tags(dataset, file.id)
      })
    else
      error -> error
    end
  end

  def checkout(conn, %{"dataset" => dataset, "id" => id} = params) do
    with :ok <- require_write(conn),
         {:ok, file} <- Media.get_file(id),
         :ok <- ensure_dataset(file, dataset),
         actor <- actor_label(conn),
         {:ok, doc} <- Checkout.checkout(file, actor, dataset) do
      json(conn, %{
        result: AssetResponse.render(file, doc, render_opts(conn, params, dataset: dataset)),
        syncTags: sync_tags(dataset, file.id)
      })
    else
      {:error, :checked_out} ->
        conflict(conn, "asset is checked out by another editor")

      error ->
        error
    end
  end

  def undo_checkout(conn, %{"dataset" => dataset, "id" => id} = params) do
    with :ok <- require_write(conn),
         {:ok, file} <- Media.get_file(id),
         :ok <- ensure_dataset(file, dataset),
         actor <- actor_label(conn),
         admin? <- admin?(conn),
         {:ok, doc} <- Checkout.undo_checkout(file, actor, dataset, admin?) do
      json(conn, %{
        result: AssetResponse.render(file, doc, render_opts(conn, params, dataset: dataset)),
        syncTags: sync_tags(dataset, file.id)
      })
    else
      {:error, :forbidden} ->
        {:error, :forbidden}

      error ->
        error
    end
  end

  def delete(conn, %{"dataset" => dataset, "id" => id}) do
    with :ok <- require_write(conn),
         {:ok, file} <- Media.get_file(id),
         :ok <- ensure_dataset(file, dataset),
         {:ok, _} <- Media.delete_file(id) do
      json(conn, %{result: %{deleted: id}, syncTags: ["bp:ds:#{dataset}:media"]})
    else
      error -> error
    end
  end

  defp ensure_dataset(%{dataset: ds}, ds), do: :ok
  defp ensure_dataset(_, _), do: {:error, :not_found}

  defp ensure_edit(conn, file, doc) do
    if Access.allowed?(conn, file, doc, :edit_metadata), do: :ok, else: {:error, :forbidden}
  end

  defp require_write(conn) do
    case conn.assigns[:api_token] do
      token when not is_nil(token) ->
        if Auth.has_permission?(token, "write") or Auth.has_permission?(token, "admin") do
          :ok
        else
          {:error, :forbidden}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  defp admin?(conn) do
    token = conn.assigns[:api_token]

    Auth.has_permission?(token, "admin") or Auth.has_permission?(token, "write")
  end

  defp actor_label(conn) do
    case conn.assigns[:api_token] do
      %{label: label} when is_binary(label) and label != "" -> label
      _ -> "api"
    end
  end

  defp render_opts(conn, params, extra \\ []) do
    dataset = Keyword.get(extra, :dataset, Map.get(params, "dataset", "production"))

    [
      conn: conn,
      dataset: dataset,
      sign_urls: params["appendRequestSecret"] in ["true", "1"]
    ]
  end

  defp conflict(conn, message) do
    env =
      {:error, :conflict}
      |> Errors.to_envelope(conn)
      |> Map.put(:message, message)

    conn
    |> put_status(:conflict)
    |> json(%{error: Map.delete(env, :status)})
  end

  defp sync_tags(dataset, file_id) do
    ["bp:ds:#{dataset}:media", "bp:ds:#{dataset}:media:#{file_id}"]
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 0 -> n
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp parse_int(_, default), do: default

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp metadata_params(%{"metadata" => metadata}) when is_map(metadata), do: metadata

  defp metadata_params(params) do
    Map.drop(params, ["dataset", "id"])
  end

  defp search_metadata(meta) when is_map(meta) do
    %{}
    |> maybe_put_meta("recovery", meta[:recovery])
    |> maybe_put_meta("parsed", meta[:parsed])
  end

  defp search_metadata(_), do: %{}

  defp maybe_put_meta(map, _key, nil), do: map
  defp maybe_put_meta(map, key, value), do: Map.put(map, key, value)

  defp validation_error(conn, changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    conn
    |> put_status(422)
    |> json(%{error: %{message: "validation failed", details: errors}})
  end
end
