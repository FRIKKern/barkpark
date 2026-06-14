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
      get_user_datasets/1              GET  /api/GetUserDatasets
      create_or_open/2                 PUT  /api/CreateOrOpen/{ds}
      analyze_string/2                 POST /api/AnalyzeString/{ds} (text/plain!)
      set_field_configuration/3        PUT  /api/SetFieldConfiguration/{ds}
      set_searchable_fields/3          PUT  /api/SetSearchableFields/{ds} (v4, DEPRECATED)
      load_string/3                    PUT  /api/LoadString/{ds}     (text/plain!)
      index_dataset/2                  GET  /api/IndexDataSet/{ds}
      get_status/2                     GET  /api/GetStatus/{ds}
      get_number_of_json_records/2     GET  /api/GetNumberOfJsonRecordsInDb/{ds}
      search/3                         POST /api/Search/{ds}
      get_json/3                       POST /api/GetJson/{ds}
      delete_dataset/2                 DELETE /api/DeleteDataSet/{ds}
      insert_json_record/4             POST   /api/{ds}/insert/{key} (text/plain!)
      update_json_record/4             PUT    /api/{ds}/update/{key} (text/plain!)
      update_field/5                   PUT    /api/{ds}/field/{key}  (application/json)
      delete_json_record/3             DELETE /api/{ds}/{key}

  ## Base URL injection

  Every verb takes an `opts` keyword. `:base_url` overrides the configured
  `Settings.get().api_base` so tests can point the client at a Bypass mock.
  The `/api` path segment is appended by this module, NOT stored in the
  base URL.

  ## SetFieldConfiguration (v5) — the rebuild's field setup

  v5 configures searchable fields via `PUT /api/SetFieldConfiguration/{ds}`
  with an `application/json` body that is a JSON array of FieldProxy
  objects (`%{"fieldName" => ..., "fieldType" => "String"|"Number",
  "searchable" => bool, "wordIndexing" => bool, "weight" => 0..2, ...}`).
  The caller builds the FieldProxy maps; this verb just `Jason.encode!`s
  the list. Configured field names MUST exist post-`AnalyzeString` or the
  engine 400s "non existing fieldname".

  CRITICAL (spike 2026-06-03, live v5-alpha): on v5 the DEPRECATED
  `SetSearchableFields` between `AnalyzeString` and `LoadString` leaves the
  engine in a state where `LoadString` returns 200 but STORES EMPTY
  DOCUMENTS (`GetJson` returns ""). `SetFieldConfiguration` is the fix —
  with it, `GetJson` returns real content and title-word search matches.
  The rebuild therefore calls `set_field_configuration/3`, NOT
  `set_searchable_fields/3`.

  ## SetSearchableFields weights (v4, DEPRECATED — no longer used by the rebuild)

  Body is a camelCase ValueTuple array
  `[{"item1": "<field>", "item2": <weight>}]` where weight is 0=High,
  1=Med, 2=Low. Weights MUST be 0..2 — a weight of 3 yields a 500
  IndexOutOfRange on the engine. Callers pass `{field, weight}` tuples;
  `Settings` already clamps the weight defaults to the valid band. KEPT
  for v4 compatibility but the v5 rebuild path uses
  `set_field_configuration/3` instead (see above).

  ## AnalyzeString + LoadString (+ v5 insert/update) are text/plain

  `analyze_string/2`, `load_string/3`, and the v5-alpha per-document
  `insert_json_record/4` / `update_json_record/4` send the JSON document(s)
  as a `text/plain` body, NOT `application/json` — the controller types all
  of these `[FromBody] string jsonData` and relies on the
  `TextPlainInputFormatter` to read the raw JSON-string body. The spike
  confirmed `application/json` is rejected on this body shape. Every OTHER
  `application/json` POST/PUT (`set_field_configuration`,
  `set_searchable_fields`, `search`, `get_json`, `update_field/5`) MUST
  carry a `content-type: application/json` header or Indx answers 415.

  ## AnalyzeString MUST precede SetFieldConfiguration

  Field configuration needs the dataset's `DocumentFields` populated —
  configured names that do not exist post-`AnalyzeString` 400 ("non
  existing fieldname"). `DocumentFields` is populated by `AnalyzeString`
  (`DocumentFields.Analyze` → `SetDocumentFieldsInternal`), NOT by
  `LoadString`. The indexer therefore calls `analyze_string` before
  `set_field_configuration` — see `Barkpark.Plugins.Indx.Indexer`. (The
  deprecated `set_searchable_fields` had the same ordering requirement.)

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

  @doc """
  List the datasets the authenticated Indx user owns.
  `GET /api/GetUserDatasets` → a JSON `string[]` of dataset names. Returns
  `{:ok, [name]}`; an empty/non-list body decodes to `{:ok, []}`.

  Maps non-2xx → `%IndexError{}` through the same `index_request/4`
  pipeline (401 invalidate-and-retry-once auth handling included) as the
  other GET lifecycle verbs. Used by `Indx.Recovery` at boot to rediscover
  the live `<prefix>_<scope>_v<n>` dataset that the `:persistent_term`
  pointer lost on restart.
  """
  @spec get_user_datasets(keyword()) :: {:ok, [String.t()]} | {:error, struct()}
  def get_user_datasets(opts \\ []) do
    case index_request(:get, "#{api_base(opts)}/api/GetUserDatasets", nil, opts) do
      {:ok, resp} -> {:ok, extract_dataset_names(resp.body)}
      {:error, _} = err -> err
    end
  end

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
  Analyze the corpus to populate the dataset's `DocumentFields`.
  `POST /api/AnalyzeString/{ds}`.

  CRITICAL ordering: this MUST run BEFORE `set_searchable_fields/3`.
  `SetSearchableFields` 400s ("SetSearchableFields invalid status") while
  `DocumentFields == null`, and `DocumentFields` is populated by
  `AnalyzeString` (`DocumentFields.Analyze` on the engine), NOT by
  `LoadString`.

  CRITICAL body: like `load_string/3`, the controller types the body
  `[FromBody] string jsonData` and reads it via the `TextPlainInputFormatter`,
  so the corpus JSON is sent as a `text/plain` body — NOT `application/json`.
  `corpus` may be a pre-encoded JSON string or a list/term that gets
  `Jason.encode!`'d.
  """
  @spec analyze_string(String.t(), iodata() | list() | map(), keyword()) ::
          :ok | {:error, struct()}
  def analyze_string(dataset, corpus, opts \\ []) when is_binary(dataset) do
    body = if is_binary(corpus), do: corpus, else: Jason.encode!(corpus)

    case index_request(:post, path("AnalyzeString", dataset, opts), body, opts,
           content_type: "text/plain"
         ) do
      {:ok, _resp} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Configure dataset fields the v5 way.
  `PUT /api/SetFieldConfiguration/{ds}` body = a JSON array of FieldProxy
  objects, sent as `application/json`. `fields` is a list of maps ALREADY
  in FieldProxy shape (the caller builds them — `Indexer.field_proxies/1`);
  this verb just `Jason.encode!`s the list.

  Each FieldProxy names a field (`"fieldName"`) that MUST exist after
  `AnalyzeString` (else 400 "non existing fieldname") and carries
  `"fieldType"`, `"searchable"`, `"wordIndexing"`, `"weight"` (0..2), and
  the BM25 knobs. Use this — NOT `set_searchable_fields/3` — for the v5
  rebuild: the deprecated path stores EMPTY documents on v5 (see moduledoc).
  """
  @spec set_field_configuration(String.t(), [map()], keyword()) ::
          :ok | {:error, struct()}
  def set_field_configuration(dataset, fields, opts \\ [])
      when is_binary(dataset) and is_list(fields) do
    json = Jason.encode!(fields)

    case index_request(:put, path("SetFieldConfiguration", dataset, opts), json, opts,
           content_type: "application/json"
         ) do
      {:ok, _resp} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Declare searchable fields with weights. DEPRECATED on v5 — calling this
  between `AnalyzeString` and `LoadString` leaves the engine storing EMPTY
  documents. Use `set_field_configuration/3` instead. Kept for v4.

  `PUT /api/SetSearchableFields/{ds}` body = camelCase ValueTuple array
  `[{"item1": field, "item2": weight}]` (weight 0..2). Accepts a list of
  `{field, weight}` tuples. Sent as `application/json`.
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

  @doc """
  Delete a SINGLE indexed JSON record from a LIVE dataset by its numeric
  key. `DELETE /api/{ds}/{key}` (the v5-alpha native delete route).

  Maps non-2xx → `%IndexError{}` through the same `index_request/5`
  pipeline as `delete_dataset/2` — same 401 invalidate-and-retry-once
  auth handling, same error mapping.

  Backed by the C# engine method `DeleteJsonRecord(key)`. The v5-alpha
  `IndxCloudApi` (`[Route("api")]` `SearchController.cs`) exposes this
  natively at `DELETE /api/{dataSetName}/{documentKey}` — the older custom
  `/api/DeleteJsonRecord/{ds}/{id}` path is GONE. Until the v5-alpha engine
  is actually deployed this verb's contract is UNPROVEN against a live
  instance (see `Indexer.delete_record/3`).

  `document_key` is the STABLE numeric key from `Indexer.key_for_id/1`.
  """
  @spec delete_json_record(String.t(), integer(), keyword()) :: :ok | {:error, struct()}
  def delete_json_record(dataset, document_key, opts \\ [])
      when is_binary(dataset) and is_integer(document_key) do
    url = "#{api_base(opts)}/api/#{dataset}/#{document_key}"

    case index_request(:delete, url, nil, opts) do
      {:ok, _resp} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Insert a SINGLE new JSON document into a LIVE dataset under
  `document_key`. `POST /api/{ds}/insert/{key}`.

  v5-alpha `SearchController` binds `[FromBody] string jsonData` via the
  `TextPlainInputFormatter` (identical to `analyze_string/2` /
  `load_string/3`), so the body is the document's JSON sent as a
  `text/plain` body — NOT `application/json`. `json` may be a pre-encoded
  JSON string or a list/term that gets `Jason.encode!`'d. Engine side:
  `InsertJsonRecord(json, out err)`.

  CAUTION: this WRITES to a LIVE dataset. The blue/green rule ("never
  re-load an existing key onto a live indexed dataset") still bans a full
  re-LOAD; a single-key insert is the v5 incremental path and is UNPROVEN
  until spiked against a real v5 engine.
  """
  @spec insert_json_record(String.t(), integer(), iodata() | list() | map(), keyword()) ::
          :ok | {:error, struct()}
  def insert_json_record(dataset, document_key, json, opts \\ [])
      when is_binary(dataset) and is_integer(document_key) do
    body = if is_binary(json), do: json, else: Jason.encode!(json)
    url = path_with_key("insert", dataset, document_key, opts)

    case index_request(:post, url, body, opts, content_type: "text/plain") do
      {:ok, _resp} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Replace a SINGLE JSON document on a LIVE dataset by key ("replace by
  key"). `PUT /api/{ds}/update/{key}`.

  Same `text/plain` body contract as `insert_json_record/4` — the
  `[FromBody] string jsonData` binding reads the raw JSON string. `json`
  may be a pre-encoded JSON string or a list/term that gets
  `Jason.encode!`'d. Engine side: `UpdateJsonRecord(json, out err)`.

  CAUTION: same live-dataset caveat as `insert_json_record/4`.
  """
  @spec update_json_record(String.t(), integer(), iodata() | list() | map(), keyword()) ::
          :ok | {:error, struct()}
  def update_json_record(dataset, document_key, json, opts \\ [])
      when is_binary(dataset) and is_integer(document_key) do
    body = if is_binary(json), do: json, else: Jason.encode!(json)
    url = path_with_key("update", dataset, document_key, opts)

    case index_request(:put, url, body, opts, content_type: "text/plain") do
      {:ok, _resp} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Patch a SINGLE field of a document on a LIVE dataset by key.
  `PUT /api/{ds}/field/{key}` body `{"fieldName": <field>, "value": <value>}`.

  UNLIKE insert/update, the field-patch body is `application/json` (the
  controller binds a typed DTO, not `[FromBody] string`). Engine side:
  `UpdateField(key, field, value, out err)`.

  CAUTION: same live-dataset caveat as `insert_json_record/4`.
  """
  @spec update_field(String.t(), integer(), String.t(), term(), keyword()) ::
          :ok | {:error, struct()}
  def update_field(dataset, document_key, field_name, value, opts \\ [])
      when is_binary(dataset) and is_integer(document_key) and is_binary(field_name) do
    body = Jason.encode!(%{"fieldName" => field_name, "value" => value})
    url = path_with_key("field", dataset, document_key, opts)

    case index_request(:put, url, body, opts, content_type: "application/json") do
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

    case search_request(:post, path("Search", dataset, opts), body, opts,
           content_type: "application/json"
         ) do
      {:ok, resp} -> {:ok, extract_records(resp.body)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Like `search/3` but returns the facet-aware envelope:
  `{:ok, %{records: [...], facets: %{field => [%{"key" => v, "value" => n}]},
  truncation_index: int | nil}}`.

  Sends `"enableFacets" => true` so the engine computes value-counts across the
  WHOLE dataset (not just the returned page) for every `facetable` field. An
  empty `text` is the v5 "enumerate + facet" browse mode. `truncationIndex` is
  the coverage boundary: records before it are coverage-confirmed matches,
  records after are softer pattern-only hits.
  """
  @spec search_full(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, struct()}
  def search_full(dataset, text, opts \\ []) when is_binary(dataset) and is_binary(text) do
    max = Keyword.get(opts, :max, 30)
    body = Jason.encode!(%{"text" => text, "maxNumberOfRecordsToReturn" => max, "enableFacets" => true})

    case search_request(:post, path("Search", dataset, opts), body, opts,
           content_type: "application/json"
         ) do
      {:ok, resp} ->
        decoded = decode_json(resp.body)

        {:ok,
         %{
           records: extract_records(resp.body),
           facets: facets_of(decoded),
           truncation_index: truncation_of(decoded)
         }}

      {:error, _} = err ->
        err
    end
  end

  defp facets_of(%{"facets" => f}) when is_map(f), do: f
  defp facets_of(_), do: %{}
  defp truncation_of(%{"truncationIndex" => i}) when is_integer(i), do: i
  defp truncation_of(_), do: nil

  @doc """
  Hydrate full JSON docs by key. `POST /api/GetJson/{ds}` body `long[]`
  (sent as `application/json`) → a `string[]` where each element is a
  document serialized as a JSON STRING. Returns `{:ok, [doc_map, ...]}` —
  each element is `Jason.decode/1`'d back into a map.
  """
  @spec get_json(String.t(), [integer()], keyword()) :: {:ok, [map()]} | {:error, struct()}
  def get_json(dataset, keys, opts \\ []) when is_binary(dataset) and is_list(keys) do
    body = Jason.encode!(keys)

    case search_request(:post, path("GetJson", dataset, opts), body, opts,
           content_type: "application/json"
         ) do
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

  # Query-path ops map non-2xx → %SearchError{}. Both callers (search,
  # get_json) always send `application/json` — no default req_opts.
  defp search_request(method, url, body, opts, req_opts) do
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

  defp handle_response(
         {:ok, %{status: status} = resp},
         _method,
         url,
         _b,
         _opts,
         _rq,
         _ar,
         error_fun
       ) do
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

  # GetJson returns a `string[]` where each element is a document serialized
  # as a JSON STRING. The outer decode yields a list of strings; each must be
  # decoded a second time into a map. Already-decoded maps (lenient engines /
  # tests) and a lone map are tolerated. Elements that fail to decode to a
  # map are dropped so a single malformed hit never poisons the batch.
  defp extract_docs(body) do
    case decode_json(body) do
      docs when is_list(docs) -> docs |> Enum.map(&decode_doc_element/1) |> Enum.reject(&is_nil/1)
      %{} = doc -> [doc]
      _ -> []
    end
  end

  defp decode_doc_element(%{} = doc) when not is_struct(doc), do: doc

  defp decode_doc_element(elem) when is_binary(elem) do
    case Jason.decode(elem) do
      {:ok, %{} = doc} -> doc
      _ -> nil
    end
  end

  defp decode_doc_element(_), do: nil

  # GetUserDatasets returns a JSON `string[]` of dataset names. Keep only
  # the binary elements (a lenient engine could wrap them); anything else
  # decodes to an empty list.
  defp extract_dataset_names(body) do
    case decode_json(body) do
      names when is_list(names) -> Enum.filter(names, &is_binary/1)
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

  # v5-alpha per-document routes put the DATASET first and carry a trailing
  # `/{key}`: `POST /api/{ds}/insert/{key}`, `PUT /api/{ds}/update/{key}`,
  # `PUT /api/{ds}/field/{key}`. Distinct from `path/3`'s legacy
  # `/api/{verb}/{ds}` shape — do not collapse the two.
  defp path_with_key(verb, dataset, key, opts) do
    "#{api_base(opts)}/api/#{dataset}/#{verb}/#{key}"
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
