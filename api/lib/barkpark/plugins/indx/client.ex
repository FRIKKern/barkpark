defmodule Barkpark.Plugins.Indx.Client do
  @moduledoc """
  HTTP client for the dedicated single-tenant Indx search engine.

  Wire shapes are the empirically-confirmed contract from the 2026-06-01
  spike — do NOT re-discover them. All Indx JSON is camelCase. Every call
  sends `Authorization: Bearer <jwt>` from `Barkpark.Plugins.Indx.Auth`.
  A 401 triggers `Auth.invalidate/0` + one retry, mirroring the
  OnixEdit/Bokbasen HTTP client precedent.

  ## Verbs

      login/1                          (delegates to Auth.token/0)
      create_or_open/2                 PUT  /api/CreateOrOpen/{ds}
      set_searchable_fields/3          PUT  /api/SetSearchableFields/{ds}
      load_string/3                    PUT  /api/LoadString/{ds}     (text/plain!)
      index_dataset/2                  GET  /api/IndexDataSet/{ds}
      get_status/2                     GET  /api/GetStatus/{ds}
      get_number_of_json_records/2     GET  /api/GetNumberOfJsonRecordsInDb/{ds}
      search/3                         POST /api/Search/{ds}
      get_json/3                       POST /api/GetJson/{ds}
      delete_dataset/2                 DELETE /api/DeleteDataSet/{ds}

  ## Base URL injection

  Every verb takes an `opts` keyword. `:base_url` overrides the configured
  `Settings.get().api_base` so tests can point the client at a Bypass mock.
  The `/api` path segment is appended by this module, NOT stored in the
  base URL.

  ## SetSearchableFields weights

  Body is a camelCase ValueTuple array
  `[{"item1": "<field>", "item2": <weight>}]` where weight is 0=High,
  1=Med, 2=Low. Weights MUST be 0..2 — a weight of 3 yields a 500
  IndexOutOfRange on the engine. Callers pass `{field, weight}` tuples;
  `Settings` already clamps the weight defaults to the valid band.

  ## LoadString is text/plain

  `load_string/3` sends the JSON corpus as a `text/plain` body, NOT
  `application/json`. The spike confirmed `application/json` is rejected.

  ## NEVER re-load a live dataset

  The blue/green sync rule lives in `Barkpark.Plugins.Indx.Indexer`, not
  here — but the warning bears repeating: re-loading an existing key onto
  a live indexed dataset HANGS and WEDGES the engine manager. The indexer
  always loads into a fresh `<prefix>_<scope>_v<n>` dataset.
  """

  alias Barkpark.Plugins.Indx.Auth

  alias Barkpark.Plugins.Indx.Errors.{
    AuthError,
    IndexError,
    NetworkError,
    SearchError
  }

  alias Barkpark.Plugins.Indx.Settings

  @default_timeout_ms 30_000

  # ---------------------------------------------------------------------------
  # Login
  # ---------------------------------------------------------------------------

  @doc """
  Obtain a JWT via the Auth cache. Thin pass-through so callers can probe
  reachability without a dataset op.
  """
  @spec login(keyword()) :: {:ok, String.t()} | {:error, AuthError.t()}
  def login(_opts \\ []), do: Auth.token()

  # ---------------------------------------------------------------------------
  # Dataset lifecycle
  # ---------------------------------------------------------------------------

  @doc "Create the dataset if absent, open it otherwise. `PUT /api/CreateOrOpen/{ds}`."
  @spec create_or_open(String.t(), keyword()) :: :ok | {:error, struct()}
  def create_or_open(dataset, opts \\ []) when is_binary(dataset) do
    case index_request(:put, path("CreateOrOpen", dataset, opts), nil, opts) do
      {:ok, _resp} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Declare searchable fields with weights.
  `PUT /api/SetSearchableFields/{ds}` body = camelCase ValueTuple array
  `[{"item1": field, "item2": weight}]` (weight 0..2). Accepts a list of
  `{field, weight}` tuples.
  """
  @spec set_searchable_fields(String.t(), [{String.t(), 0..2}], keyword()) ::
          :ok | {:error, struct()}
  def set_searchable_fields(dataset, fields, opts \\ [])
      when is_binary(dataset) and is_list(fields) do
    body =
      Enum.map(fields, fn {field, weight} ->
        %{"item1" => to_string(field), "item2" => weight}
      end)

    json = Jason.encode!(body)

    case index_request(:put, path("SetSearchableFields", dataset, opts), json, opts,
           content_type: "application/json"
         ) do
      {:ok, _resp} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Load a JSON array of documents into the dataset. `PUT /api/LoadString/{ds}`.

  CRITICAL: the body is sent as `text/plain`, NOT `application/json` —
  Indx rejects `application/json` here. `corpus` may be a pre-encoded JSON
  string or a list/term that gets `Jason.encode!`'d.
  """
  @spec load_string(String.t(), iodata() | list() | map(), keyword()) ::
          :ok | {:error, struct()}
  def load_string(dataset, corpus, opts \\ []) when is_binary(dataset) do
    body = if is_binary(corpus), do: corpus, else: Jason.encode!(corpus)

    case index_request(:put, path("LoadString", dataset, opts), body, opts,
           content_type: "text/plain"
         ) do
      {:ok, _resp} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Kick off indexing of a loaded dataset. `GET /api/IndexDataSet/{ds}`."
  @spec index_dataset(String.t(), keyword()) :: :ok | {:error, struct()}
  def index_dataset(dataset, opts \\ []) when is_binary(dataset) do
    case index_request(:get, path("IndexDataSet", dataset, opts), nil, opts) do
      {:ok, _resp} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Poll a dataset's indexing status. `GET /api/GetStatus/{ds}`. Returns the
  decoded status payload (shape is engine-version-dependent) so the
  indexer can decide when indexing is ready.
  """
  @spec get_status(String.t(), keyword()) :: {:ok, term()} | {:error, struct()}
  def get_status(dataset, opts \\ []) when is_binary(dataset) do
    case index_request(:get, path("GetStatus", dataset, opts), nil, opts) do
      {:ok, resp} -> {:ok, decode_json(resp.body)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Count indexed JSON records. `GET /api/GetNumberOfJsonRecordsInDb/{ds}`.
  Returns `{:ok, integer}` — used to verify a blue/green rebuild loaded the
  full corpus before swapping.
  """
  @spec get_number_of_json_records(String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, struct()}
  def get_number_of_json_records(dataset, opts \\ []) when is_binary(dataset) do
    case index_request(:get, path("GetNumberOfJsonRecordsInDb", dataset, opts), nil, opts) do
      {:ok, resp} -> {:ok, parse_count(resp.body)}
      {:error, _} = err -> err
    end
  end

  @doc "Delete a dataset. `DELETE /api/DeleteDataSet/{ds}`."
  @spec delete_dataset(String.t(), keyword()) :: :ok | {:error, struct()}
  def delete_dataset(dataset, opts \\ []) when is_binary(dataset) do
    case index_request(:delete, path("DeleteDataSet", dataset, opts), nil, opts) do
      {:ok, _resp} -> :ok
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Query path
  # ---------------------------------------------------------------------------

  @doc """
  Run a CloudQuery search. `POST /api/Search/{ds}` body
  `{"text": ..., "maxNumberOfRecordsToReturn": N}` → `{"records":
  [{"documentKey": <long>, "score": <0-255>}], ...}`.

  Returns `{:ok, [%{"documentKey" => long, "score" => int}, ...]}`.
  `opts[:max]` sets `maxNumberOfRecordsToReturn` (default 30).
  """
  @spec search(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, struct()}
  def search(dataset, text, opts \\ []) when is_binary(dataset) and is_binary(text) do
    max = Keyword.get(opts, :max, 30)
    body = Jason.encode!(%{"text" => text, "maxNumberOfRecordsToReturn" => max})

    case search_request(:post, path("Search", dataset, opts), body, opts) do
      {:ok, resp} -> {:ok, extract_records(resp.body)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Hydrate full JSON docs by key. `POST /api/GetJson/{ds}` body `long[]` →
  JSON docs. Returns `{:ok, [doc_map, ...]}`.
  """
  @spec get_json(String.t(), [integer()], keyword()) :: {:ok, [map()]} | {:error, struct()}
  def get_json(dataset, keys, opts \\ []) when is_binary(dataset) and is_list(keys) do
    body = Jason.encode!(keys)

    case search_request(:post, path("GetJson", dataset, opts), body, opts) do
      {:ok, resp} -> {:ok, extract_docs(resp.body)}
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Request pipeline
  # ---------------------------------------------------------------------------

  # Index/lifecycle ops map non-2xx → %IndexError{}.
  defp index_request(method, url, body, opts, req_opts \\ []) do
    do_request(method, url, body, opts, req_opts, 0, &index_error/3)
  end

  # Query-path ops map non-2xx → %SearchError{}.
  defp search_request(method, url, body, opts, req_opts \\ []) do
    do_request(method, url, body, opts, req_opts, 0, &search_error/3)
  end

  # auth_retries: number of 401 token refreshes already attempted (max 1).
  defp do_request(method, url, body, opts, req_opts, auth_retries, error_fun) do
    with {:ok, jwt} <- Auth.token(),
         headers = build_headers(jwt, req_opts),
         response = perform(method, url, headers, body, opts) do
      handle_response(response, method, url, body, opts, req_opts, auth_retries, error_fun)
    else
      {:error, %AuthError{} = err} -> {:error, err}
    end
  end

  defp build_headers(jwt, req_opts) do
    base = [{"authorization", "Bearer " <> jwt}, {"accept", "application/json"}]

    case Keyword.get(req_opts, :content_type) do
      nil -> base
      ct -> [{"content-type", ct} | base]
    end
  end

  defp perform(method, url, headers, body, opts) do
    timeout = timeout_ms(opts)

    req_opts =
      [
        url: url,
        method: method,
        headers: headers,
        receive_timeout: timeout,
        connect_options: [timeout: timeout],
        retry: false,
        decode_body: false
      ]
      |> maybe_put_body(body)

    try do
      Req.request(Req.new(req_opts))
    rescue
      e -> {:error, e}
    end
  end

  defp maybe_put_body(req_opts, nil), do: req_opts
  defp maybe_put_body(req_opts, body), do: Keyword.put(req_opts, :body, body)

  # 401 once → invalidate + retry with a fresh token.
  defp handle_response(
         {:ok, %{status: 401}},
         method,
         url,
         body,
         opts,
         req_opts,
         0,
         error_fun
       ) do
    Auth.invalidate()
    do_request(method, url, body, opts, req_opts, 1, error_fun)
  end

  # 401 after a refresh → surface as AuthError.
  defp handle_response({:ok, %{status: 401}}, _method, url, _b, _opts, _rq, _ar, _ef) do
    {:error, %AuthError{status: 401, endpoint: url, message: "Indx token refresh failed"}}
  end

  defp handle_response({:ok, %{status: 403}}, _method, url, _b, _opts, _rq, _ar, _ef) do
    {:error, %AuthError{status: 403, endpoint: url, message: "Indx forbidden"}}
  end

  defp handle_response({:ok, %{status: status} = resp}, _method, _url, _b, _opts, _rq, _ar, _ef)
       when status >= 200 and status < 300 do
    {:ok, resp}
  end

  defp handle_response({:ok, %{status: status} = resp}, _method, url, _b, _opts, _rq, _ar, error_fun) do
    {:error, error_fun.(status, resp.body, url)}
  end

  defp handle_response({:error, exception}, _method, url, _b, _opts, _rq, _ar, _ef) do
    {:error, %NetworkError{reason: exception_reason(exception), endpoint: url}}
  end

  defp index_error(status, body, url) do
    %IndexError{status: status, body: body, endpoint: url, message: "Indx index op failed"}
  end

  defp search_error(status, body, url) do
    %SearchError{status: status, body: body, endpoint: url, message: "Indx query op failed"}
  end

  # ---------------------------------------------------------------------------
  # Response parsing
  # ---------------------------------------------------------------------------

  defp extract_records(body) do
    case decode_json(body) do
      %{"records" => records} when is_list(records) -> records
      _ -> []
    end
  end

  defp extract_docs(body) do
    case decode_json(body) do
      docs when is_list(docs) -> docs
      %{} = doc -> [doc]
      _ -> []
    end
  end

  defp parse_count(body) do
    case decode_json(body) do
      n when is_integer(n) ->
        n

      %{} = m ->
        # Some engine versions wrap the count in an object.
        m
        |> Map.values()
        |> Enum.find(&is_integer/1)
        |> case do
          n when is_integer(n) -> n
          _ -> 0
        end

      _ ->
        case is_binary(body) and Integer.parse(String.trim(body)) do
          {n, _} -> n
          _ -> 0
        end
    end
  end

  defp decode_json(body) when is_map(body) and not is_struct(body), do: body
  defp decode_json(body) when is_list(body), do: body

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp decode_json(other), do: other

  # ---------------------------------------------------------------------------
  # Configuration helpers
  # ---------------------------------------------------------------------------

  defp path(verb, dataset, opts) do
    "#{api_base(opts)}/api/#{verb}/#{dataset}"
  end

  defp api_base(opts) do
    case Keyword.get(opts, :base_url) do
      url when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/")

      _ ->
        case Settings.get().api_base do
          url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
          _ -> ""
        end
    end
  end

  defp timeout_ms(opts) do
    cond do
      n = Keyword.get(opts, :timeout) ->
        n

      v = System.get_env("INDX_HTTP_TIMEOUT_MS") ->
        case Integer.parse(v) do
          {n, _} -> n
          :error -> @default_timeout_ms
        end

      true ->
        Application.get_env(:barkpark, :indx_http_timeout_ms, @default_timeout_ms)
    end
  end

  defp exception_reason(exception) do
    cond do
      is_map(exception) and Map.has_key?(exception, :reason) -> Map.get(exception, :reason)
      is_exception(exception) -> Exception.message(exception)
      true -> exception
    end
  end
end
