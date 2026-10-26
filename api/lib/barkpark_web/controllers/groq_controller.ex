defmodule BarkparkWeb.GroqController do
  @moduledoc """
  Sanity-compatible GROQ reads: `GET` and `POST`
  `/w/:workspace_slug/p/:project_slug/v{apiVersion}/data/query/:dataset`.

  The request and response follow Sanity's HTTP query API, so `@sanity/client`
  configured with this host as `apiHost` (docs/api-v1.md §4a) sends its
  queries here unchanged:

    * `GET ?query=<groq>&$name=<json>&perspective=…&returnQuery=false`
    * `POST {"query": "<groq>", "params": {"name": <json>}}`, with the same
      options in the query string (or the body).

  The response is `{"query", "result", "ms", "syncTags"}`; `query` is left out
  when `returnQuery=false`. Errors carry Barkpark's `{error: {code, message,
  request_id}}` plus Sanity's `description` and `type`, and for a syntax error
  `query`, `start` and `end`, which `@sanity/client` formats into its message.

  Auth and tenancy come from the route's pipeline, as for the other scoped
  document reads. A caller pinned to published reads (no token, a share, a
  `public-read` token) gets `perspective=published` whatever it asks for.
  """
  use BarkparkWeb, :controller

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  alias Barkpark.Content.WriteScope
  alias BarkparkWeb.{AnonPerspective, ErrorResponse, ReadPerspective}

  @perspectives ["published", "drafts", "raw", "previewDrafts"]

  @doc "The POST form: the same read, with the query and params in the body."
  def read_post(conn, params), do: read(conn, params)

  def read(conn, %{"dataset" => dataset} = params) do
    t0 = System.monotonic_time(:microsecond)

    with :ok <- known_dataset(dataset, conn),
         {:ok, query} <- query_text(params),
         {:ok, query_params} <- query_params(conn, params),
         :ok <- perspective_ok(params) do
      result =
        Barkpark.Groq.query(query, query_params,
          dataset: dataset,
          perspective: resolve_perspective(conn, params),
          scope_opts: scope_opts(conn),
          identity: identity(conn),
          project_id: conn.path_params["project_slug"]
        )

      case result do
        {:ok, %{result_json: result_json, sync_tags: tags}} ->
          ms = div(System.monotonic_time(:microsecond) - t0, 1000)
          respond(conn, params, query, result_json, tags, ms)

        {:error, {:parse, error}} ->
          parse_error(conn, query, error)

        {:error, {:limit, message}} ->
          query_error(conn, 422, "queryLimitError", message)

        {:error, {:eval, message}} ->
          query_error(conn, 422, "queryEvaluationError", message)

        {:error, {:busy, message}} ->
          conn
          |> put_resp_header("retry-after", "1")
          |> query_error(503, "queryBusyError", message)
      end
    else
      {:error, :unknown_dataset} ->
        ErrorResponse.emit(conn, {:error, {:not_found, "dataset #{inspect(dataset)} not found"}})

      {:error, :missing_query} ->
        ErrorResponse.emit_fields(conn, 400, %{
          code: "malformed",
          message: "the query parameter is required",
          description: "the query parameter is required",
          hint: "Send the GROQ query in the query parameter: ?query=*[_type == \"post\"]",
          type: "queryParseError"
        })

      {:error, {:bad_param, name}} ->
        ErrorResponse.emit_custom(
          conn,
          400,
          "malformed",
          "parameter $#{name} is not valid JSON",
          %{
            parameter: "$" <> name
          }
        )

      {:error, {:bad_perspective, value}} ->
        ReadPerspective.refuse(conn, value, @perspectives)
    end
  end

  @doc """
  Sanity's document read, `GET …/v{apiVersion}/data/doc/:dataset/:id[,id…]`
  (`client.getDocument` / `getDocuments`): `{"documents": [...], "omitted":
  [{"id", "reason": "existence"}]}`, by `_id` alone. It is the GROQ read
  `*[_id in $ids]` with the same dataset, scope, auth and perspective
  resolution as `read/2`; the default perspective is `raw`, so an id names
  exactly one stored document (a `drafts.` id its draft), as on Sanity. A
  caller pinned to published reads stays pinned. An id the caller cannot see
  is omitted with reason `existence`.
  """
  def documents(conn, %{"dataset" => dataset, "ids" => raw_ids} = params) do
    ids =
      raw_ids
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    params = Map.put_new(params, "perspective", "raw")

    with :ok <- known_dataset(dataset, conn),
         :ok <- perspective_ok(params) do
      result =
        Barkpark.Groq.query("*[_id in $ids]", %{"ids" => ids},
          dataset: dataset,
          perspective: resolve_perspective(conn, params),
          scope_opts: scope_opts(conn),
          identity: identity(conn),
          project_id: conn.path_params["project_slug"]
        )

      case result do
        {:ok, %{result_json: result_json}} ->
          by_id = result_json |> Jason.decode!() |> Map.new(&{&1["_id"], &1})

          json(conn, %{
            documents: for(id <- ids, doc = by_id[id], doc != nil, do: doc),
            omitted:
              for(id <- ids, not Map.has_key?(by_id, id), do: %{id: id, reason: "existence"})
          })

        {:error, {:limit, message}} ->
          query_error(conn, 422, "queryLimitError", message)

        {:error, {:busy, message}} ->
          conn
          |> put_resp_header("retry-after", "1")
          |> query_error(503, "queryBusyError", message)

        {:error, {_kind, message}} ->
          query_error(conn, 422, "queryEvaluationError", to_string(message))
      end
    else
      {:error, :unknown_dataset} ->
        ErrorResponse.emit(conn, {:error, {:not_found, "dataset #{inspect(dataset)} not found"}})

      {:error, {:bad_perspective, value}} ->
        ReadPerspective.refuse(conn, value, @perspectives)
    end
  end

  defp known_dataset(dataset, conn) do
    if WriteScope.read_dataset_known?(dataset, scope_opts(conn)),
      do: :ok,
      else: {:error, :unknown_dataset}
  end

  defp query_text(%{"query" => query}) when is_binary(query) and query != "", do: {:ok, query}
  defp query_text(_params), do: {:error, :missing_query}

  # GET carries `$name=<json>` pairs; POST carries a `params` object whose
  # values are already decoded.
  defp query_params(conn, params) do
    from_body =
      case params["params"] do
        %{} = map ->
          map

        # `bp doc groq --params '{"slug":"x"}'` sends the object as a string.
        json when is_binary(json) ->
          case Jason.decode(json) do
            {:ok, %{} = map} -> map
            _ -> :invalid
          end

        _ ->
          %{}
      end

    start = if from_body == :invalid, do: {:error, {:bad_param, "params"}}, else: {:ok, from_body}

    conn.query_params
    |> Enum.filter(fn {key, _} -> String.starts_with?(key, "$") end)
    |> Enum.reduce_while(start, fn
      _pair, {:error, _} = error ->
        {:halt, error}

      {"$" <> name, raw}, {:ok, acc} ->
        case Jason.decode(raw) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
          {:error, _} -> {:halt, {:error, {:bad_param, name}}}
        end
    end)
  end

  defp perspective_ok(params) do
    case ReadPerspective.unsupported(params, @perspectives) do
      nil -> :ok
      value -> {:error, {:bad_perspective, value}}
    end
  end

  defp resolve_perspective(conn, params) do
    params =
      case params["perspective"] do
        "previewDrafts" -> Map.put(params, "perspective", "drafts")
        _ -> params
      end

    AnonPerspective.resolve(conn, params)
  end

  defp identity(conn) do
    case conn.assigns[:api_token] do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp respond(conn, params, query, result_json, tags, ms) do
    return_query? = params["returnQuery"] not in ["false", false]

    result = Jason.Fragment.new(result_json)

    # Literal maps, so the /v1/data envelope convention can read them
    # (response_envelope_convention_test.exs): `result` plus Sanity's
    # `query`, `ms` and `syncTags`.
    if return_query? do
      json(conn, %{query: query, result: result, ms: ms, syncTags: tags})
    else
      json(conn, %{result: result, ms: ms, syncTags: tags})
    end
  end

  # A query's own hint: `malformed`'s default speaks of a JSON body, which a GROQ read
  # does not have (task-b85cf70ca346260a). A hint in the fields wins over that default.
  defp parse_error(conn, query, error) do
    ErrorResponse.emit_fields(conn, 400, %{
      code: "malformed",
      message: "GROQ syntax error at byte #{error.start}: #{error.description}",
      description: error.description,
      hint:
        "Fix the GROQ query between bytes start and end (the query parameter, URL-encoded); the request has no JSON body to change.",
      type: "queryParseError",
      query: query,
      start: error.start,
      end: error.end
    })
  end

  defp query_error(conn, status, type, message) do
    ErrorResponse.emit_fields(conn, status, %{
      code: "bad_request",
      message: message,
      description: message,
      type: type
    })
  end
end
