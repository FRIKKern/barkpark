defmodule Barkpark.ApiTester.Runner do
  @moduledoc """
  Executes v1 API test cases server-side via `Req`.

  Hits `http://localhost:4000` by default — the running Phoenix endpoint.
  Returns the raw status/headers/body plus a timing measurement and a
  predicate-based pass/fail verdict so the UI can colour results.
  """

  @default_base "http://localhost:4000"

  @doc """
  Build a concrete HTTP request from an endpoint spec + form state + config.

  Returns a map: %{method, url, headers, body_text}. Pass this directly to
  run/1 (wrapped as a pseudo test-case map) or use the fields to render a
  curl command.

  - Path params are interpolated into `path_template` via `{name}` tokens.
  - Query params with non-empty values become URL-encoded query string.
  - `:token` / `:admin` endpoints get an Authorization header when
    `config.token` is non-empty.
  - POST endpoints read `form_state["_body_text"]` (the raw JSON the
    playground textarea holds) and attach it as the body with a
    Content-Type: application/json header.
  """
  @spec build_request(map(), map(), %{token: String.t(), base: String.t()}) :: map()
  def build_request(endpoint, form_state, config) do
    base = Map.get(config, :base, @default_base)
    token = Map.get(config, :token, "")

    path = interpolate_path(endpoint.path_template, endpoint.path_params, form_state)
    query = build_query_string(endpoint.query_params || [], form_state)
    url = base <> path <> if(query == "", do: "", else: "?" <> query)

    headers =
      []
      |> maybe_add_auth(endpoint.auth, token)
      |> maybe_add_content_type(endpoint.method)

    body_text =
      if endpoint.method == "POST" do
        Map.get(form_state, "_body_text", "")
      else
        nil
      end

    %{method: endpoint.method, url: url, headers: headers, body_text: body_text}
  end

  defp interpolate_path(template, path_params, form_state) do
    Enum.reduce(path_params, template, fn %{name: name}, acc ->
      value = Map.get(form_state, name, "")
      String.replace(acc, "{#{name}}", URI.encode(value))
    end)
  end

  defp build_query_string(query_params, form_state) do
    query_params
    |> Enum.map(fn %{name: name} -> {name, Map.get(form_state, name, "")} end)
    |> Enum.reject(fn {_, v} -> v == "" end)
    |> URI.encode_query()
  end

  defp maybe_add_auth(headers, auth, token)
       when auth in [:token, :admin] and token not in [nil, ""] do
    [{"Authorization", "Bearer " <> token} | headers]
  end

  defp maybe_add_auth(headers, _, _), do: headers

  defp maybe_add_content_type(headers, "POST"),
    do: [{"Content-Type", "application/json"} | headers]

  defp maybe_add_content_type(headers, _), do: headers

  @doc """
  Run a test case by id (or a test-case map) with an optional body override.

  Returns a map with:
    - `status`      — integer HTTP status
    - `headers`     — list of {name, value}
    - `body_text`   — raw response body
    - `body_json`   — decoded JSON if parseable, else nil
    - `duration_ms` — wall-clock time
    - `verdict`     — :pass | :fail | :error (runtime issue) | :unverified (no
                       expectation was evaluated — NOT a pass, a third state)
    - `verdict_reason` — short human string
    - `request`     — echoed back for display (url/method/headers/body_text)
  """
  @spec run(map(), keyword()) :: map()
  def run(tc, opts \\ [])

  def run(%{} = tc, opts) do
    base = Keyword.get(opts, :base, @default_base)
    body_override = Keyword.get(opts, :body_override)

    body =
      cond do
        is_binary(body_override) and body_override != "" -> body_override
        tc.body == nil -> nil
        true -> Jason.encode!(tc.body)
      end

    url = base <> tc.path
    headers = tc.headers

    started = System.monotonic_time(:millisecond)

    # Tests thread extra Req options (e.g. `req_options: [plug: {Req.Test, Stub}]`)
    # so verdict computation is unit-testable without a live HTTP port — mirrors
    # Barkpark.ApiTestRunner.fire/2's `:req_options` pass-through. Appended last
    # so a caller override wins on overlap.
    req_opts =
      [
        method: method_atom(tc.method),
        url: url,
        headers: headers,
        body: body,
        decode_body: false,
        receive_timeout: 5_000,
        connect_options: [timeout: 2_000],
        retry: false
      ] ++ Keyword.get(opts, :req_options, [])

    req_result =
      try do
        Req.request(req_opts)
      rescue
        e -> {:error, Exception.message(e)}
      end

    duration = System.monotonic_time(:millisecond) - started

    case req_result do
      {:ok, %Req.Response{status: status, headers: resp_headers, body: resp_body}} ->
        body_text = to_string(resp_body)
        body_json = try_decode_json(body_text)

        normalized_headers =
          Enum.flat_map(resp_headers, fn
            {k, v} when is_list(v) -> Enum.map(v, fn val -> {to_string(k), to_string(val)} end)
            {k, v} -> [{to_string(k), to_string(v)}]
          end)

        {verdict, reason} =
          check(tc, %{status: status, body_json: body_json, headers: normalized_headers})

        %{
          status: status,
          headers: normalized_headers,
          body_text: body_text,
          body_json: body_json,
          duration_ms: duration,
          verdict: verdict,
          verdict_reason: reason,
          request: %{
            method: tc.method,
            url: url,
            headers: headers,
            body_text: body || ""
          }
        }

      {:error, reason} ->
        %{
          status: 0,
          headers: [],
          body_text: inspect(reason),
          body_json: nil,
          duration_ms: duration,
          verdict: :error,
          verdict_reason: "req error: #{inspect(reason)}",
          request: %{method: tc.method, url: url, headers: headers, body_text: body || ""}
        }
    end
  end

  # ── Predicate checks ──────────────────────────────────────────────────
  #
  # `:unverified` is a THIRD state, not a passing grade: these two arms
  # never inspect the response at all, so a 500 must not badge the same
  # as a real, checked 200. Do not fold `:unverified` into `:pass` in any
  # caller — see Studio's format layer for the distinct badge mapping.

  defp check(%{expect: nil}, _), do: {:unverified, "no expectation — manual check"}

  defp check(%{expect: {expected_status, predicate}}, %{
         status: status,
         body_json: body,
         headers: headers
       }) do
    if status != expected_status do
      {:fail, "expected HTTP #{expected_status}, got #{status}"}
    else
      case run_predicate(predicate, body, headers) do
        :ok -> {:pass, "#{expected_status} OK"}
        {:fail, why} -> {:fail, why}
      end
    end
  end

  defp check(_, _), do: {:unverified, "no expectation"}

  defp run_predicate(:ok, _, _), do: :ok

  defp run_predicate(:envelope_has_reserved_keys, body, _) do
    case unwrap_result(body) do
      %{"documents" => [first | _]} ->
        required = ~w(_id _type _rev _draft _publishedId _createdAt _updatedAt)
        missing = Enum.reject(required, &Map.has_key?(first, &1))
        if missing == [], do: :ok, else: {:fail, "missing keys: #{inspect(missing)}"}

      _ ->
        {:fail, "no documents in response"}
    end
  end

  # Single-doc response (GET /v1/data/doc/:ds/:type/:id) returns the envelope
  # under the `result` wrapper.
  defp run_predicate(:envelope_top_level, body, _) when is_map(body) do
    case unwrap_result(body) do
      envelope when is_map(envelope) ->
        required = ~w(_id _type _rev _draft _publishedId _createdAt _updatedAt)
        missing = Enum.reject(required, &Map.has_key?(envelope, &1))
        if missing == [], do: :ok, else: {:fail, "missing keys: #{inspect(missing)}"}

      _ ->
        {:fail, "expected a flat envelope object"}
    end
  end

  defp run_predicate(:envelope_top_level, _, _), do: {:fail, "expected a flat envelope object"}

  defp run_predicate(:order_ascending, body, _) do
    case unwrap_result(body) do
      %{"documents" => docs} when length(docs) >= 2 ->
        dates = Enum.map(docs, & &1["_createdAt"])
        if dates == Enum.sort(dates), do: :ok, else: {:fail, "not ascending: #{inspect(dates)}"}

      _ ->
        {:fail, "need at least 2 docs to verify order"}
    end
  end

  defp run_predicate(:error_code_not_found, %{"error" => %{"code" => "not_found"}}, _), do: :ok

  defp run_predicate(:error_code_not_found, body, _),
    do: {:fail, "not a not_found envelope: #{inspect(body)}"}

  defp run_predicate(:error_code_unauthorized, %{"error" => %{"code" => "unauthorized"}}, _),
    do: :ok

  defp run_predicate(:error_code_unauthorized, body, _),
    do: {:fail, "not an unauthorized envelope: #{inspect(body)}"}

  defp run_predicate(:error_code_malformed, %{"error" => %{"code" => "malformed"}}, _), do: :ok

  defp run_predicate(:error_code_malformed, body, _),
    do: {:fail, "not a malformed envelope: #{inspect(body)}"}

  defp run_predicate(:schema_version_1, %{"_schemaVersion" => 1, "schemas" => schemas}, _)
       when is_list(schemas),
       do: :ok

  defp run_predicate(:schema_version_1, body, _),
    do: {:fail, "missing _schemaVersion/schemas: #{inspect(body)}"}

  # Single-schema response wraps under a singular `schema` key, not `schemas`.
  defp run_predicate(
         :schema_version_1_show,
         %{"_schemaVersion" => 1, "schema" => %{"name" => _}},
         _
       ),
       do: :ok

  defp run_predicate(:schema_version_1_show, body, _),
    do: {:fail, "missing _schemaVersion/schema: #{inspect(body)}"}

  defp run_predicate(
         :mutate_result_has_envelope,
         %{"transactionId" => tx, "results" => [r | _]},
         _
       )
       when is_binary(tx) do
    doc = r["document"]

    if is_map(doc) && Map.has_key?(doc, "_id") && Map.has_key?(doc, "_rev") do
      :ok
    else
      {:fail, "result has no envelope document"}
    end
  end

  defp run_predicate(:mutate_result_has_envelope, body, _),
    do: {:fail, "no transactionId/results: #{inspect(body)}"}

  defp run_predicate(:legacy_deprecation_headers, _, headers) do
    has = fn name ->
      Enum.any?(headers, fn {k, _} -> String.downcase(to_string(k)) == name end)
    end

    cond do
      not has.("deprecation") -> {:fail, "missing Deprecation header"}
      not has.("sunset") -> {:fail, "missing Sunset header"}
      not has.("link") -> {:fail, "missing Link header"}
      true -> :ok
    end
  end

  defp run_predicate(:search_has_results, %{"documents" => docs, "count" => c}, _)
       when is_list(docs) and c > 0,
       do: :ok

  defp run_predicate(:search_has_results, _, _), do: {:fail, "expected documents with count > 0"}

  defp run_predicate(:search_empty, %{"documents" => [], "count" => 0}, _), do: :ok
  defp run_predicate(:search_empty, _, _), do: {:fail, "expected empty results"}

  defp run_predicate(:search_type_match, %{"documents" => docs}, _)
       when is_list(docs) and length(docs) > 0,
       do: :ok

  defp run_predicate(:search_type_match, _, _), do: {:fail, "expected documents"}

  defp run_predicate(:analytics_has_types, %{"types" => types, "total_documents" => total}, _)
       when is_list(types) and is_integer(total),
       do: :ok

  defp run_predicate(:analytics_has_types, _, _),
    do: {:fail, "expected types array and total_documents"}

  defp run_predicate(:analytics_empty, %{"total_documents" => 0, "types" => []}, _), do: :ok
  defp run_predicate(:analytics_empty, _, _), do: {:fail, "expected zero documents"}

  defp run_predicate(:has_revisions_list, %{"revisions" => revs}, _) when is_list(revs), do: :ok
  defp run_predicate(:has_revisions_list, _, _), do: {:fail, "expected revisions list"}

  defp run_predicate(:has_webhooks_list, %{"webhooks" => whs}, _) when is_list(whs), do: :ok
  defp run_predicate(:has_webhooks_list, _, _), do: {:fail, "expected webhooks list"}

  defp run_predicate(:ndjson_response, _, _), do: :ok

  defp run_predicate(other, _, _), do: {:fail, "unknown predicate: #{inspect(other)}"}

  # ── Helpers ───────────────────────────────────────────────────────────

  # Query endpoints wrap their payload in {"result": {...}, "schemaHash", "etag", ...}.
  # Predicates that inspect the document envelope must unwrap this layer first.
  # Endpoints that return a flat top-level shape (search, analytics, history,
  # webhooks, schemas) pass through unchanged.
  defp unwrap_result(%{"result" => %{} = inner}), do: inner
  defp unwrap_result(other), do: other

  defp method_atom("GET"), do: :get
  defp method_atom("POST"), do: :post
  defp method_atom("PUT"), do: :put
  defp method_atom("PATCH"), do: :patch
  defp method_atom("DELETE"), do: :delete

  defp try_decode_json(""), do: nil

  defp try_decode_json(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end
end
