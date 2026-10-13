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
      end
    else
      {:error, :unknown_dataset} ->
        ErrorResponse.emit(conn, {:error, {:not_found, "dataset #{inspect(dataset)} not found"}})

      {:error, :missing_query} ->
        ErrorResponse.emit_fields(conn, 400, %{
          code: "malformed",
          message: "the query parameter is required",
          description: "the query parameter is required",
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
        %{} = map -> map
        _ -> %{}
      end

    conn.query_params
    |> Enum.filter(fn {key, _} -> String.starts_with?(key, "$") end)
    |> Enum.reduce_while({:ok, from_body}, fn {"$" <> name, raw}, {:ok, acc} ->
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

    fields =
      [
        if(return_query?, do: {"query", query}),
        {"result", Jason.Fragment.new(result_json)},
        {"ms", ms},
        {"syncTags", tags}
      ]
      |> Enum.reject(&is_nil/1)
      |> Jason.OrderedObject.new()

    json(conn, fields)
  end

  defp parse_error(conn, query, error) do
    ErrorResponse.emit_fields(conn, 400, %{
      code: "malformed",
      message: "GROQ syntax error at byte #{error.start}: #{error.description}",
      description: error.description,
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
