defmodule Barkpark.ApiTester.Runner do
  @moduledoc """
  Executes v1 API test cases server-side via `:httpc` (no extra deps).

  Hits `http://localhost:4000` by default — the running Phoenix endpoint.
  Returns the raw status/headers/body plus a timing measurement and a
  predicate-based pass/fail verdict so the UI can colour results.
  """

  alias Barkpark.ApiTester.TestCases

  @default_base "http://localhost:4000"

  @doc """
  Run a test case by id (or a test-case map) with an optional body override.

  Returns a map with:
    - `status`      — integer HTTP status
    - `headers`     — list of {name, value}
    - `body_text`   — raw response body
    - `body_json`   — decoded JSON if parseable, else nil
    - `duration_ms` — wall-clock time
    - `verdict`     — :pass | :fail | :error (runtime issue)
    - `verdict_reason` — short human string
    - `request`     — echoed back for display (url/method/headers/body_text)
  """
  @spec run(String.t() | map(), keyword()) :: map()
  def run(id, opts \\ [])

  def run(id, opts) when is_binary(id) do
    case TestCases.find(id) do
      nil -> %{verdict: :error, verdict_reason: "unknown test id: #{id}"}
      tc -> run(tc, opts)
    end
  end

  def run(%{} = tc, opts) do
    base = Keyword.get(opts, :base, @default_base)
    body_override = Keyword.get(opts, :body_override)
    :inets.start()
    :ssl.start()

    body =
      cond do
        is_binary(body_override) -> body_override
        tc.body == nil -> nil
        true -> Jason.encode!(tc.body)
      end

    url = String.to_charlist(base <> tc.path)
    headers = Enum.map(tc.headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    started = System.monotonic_time(:millisecond)

    request =
      case tc.method do
        "GET" -> {url, headers}
        _ -> {url, headers, ~c"application/json", body || ""}
      end

    http_options = [timeout: 5_000, connect_timeout: 2_000]
    options = [body_format: :binary]

    result =
      try do
        :httpc.request(method_atom(tc.method), request, http_options, options)
      rescue
        e -> {:error, Exception.message(e)}
      end

    duration = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, {{_proto, status, _reason}, resp_headers, resp_body}} ->
        body_text = to_string(resp_body)
        body_json = try_decode_json(body_text)

        {verdict, reason} = check(tc, %{status: status, body_json: body_json, headers: resp_headers})

        %{
          status: status,
          headers: Enum.map(resp_headers, fn {k, v} -> {to_string(k), to_string(v)} end),
          body_text: body_text,
          body_json: body_json,
          duration_ms: duration,
          verdict: verdict,
          verdict_reason: reason,
          request: %{
            method: tc.method,
            url: base <> tc.path,
            headers: tc.headers,
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
          verdict_reason: "httpc error: #{inspect(reason)}",
          request: %{method: tc.method, url: base <> tc.path, headers: tc.headers, body_text: body || ""}
        }
    end
  end

  # ── Predicate checks ──────────────────────────────────────────────────

  defp check(%{expect: nil}, _), do: {:pass, "no expectation — manual check"}
  defp check(%{expect: {expected_status, predicate}}, %{status: status, body_json: body, headers: headers}) do
    cond do
      status != expected_status ->
        {:fail, "expected HTTP #{expected_status}, got #{status}"}

      true ->
        case run_predicate(predicate, body, headers) do
          :ok -> {:pass, "#{expected_status} OK"}
          {:fail, why} -> {:fail, why}
        end
    end
  end

  defp check(_, _), do: {:pass, "no expectation"}

  defp run_predicate(:ok, _, _), do: :ok

  defp run_predicate(:envelope_has_reserved_keys, %{"documents" => [first | _]}, _) do
    required = ~w(_id _type _rev _draft _publishedId _createdAt _updatedAt)
    missing = Enum.reject(required, &Map.has_key?(first, &1))
    if missing == [], do: :ok, else: {:fail, "missing keys: #{inspect(missing)}"}
  end

  defp run_predicate(:envelope_has_reserved_keys, _, _), do: {:fail, "no documents in response"}

  defp run_predicate(:order_ascending, %{"documents" => docs}, _) when length(docs) >= 2 do
    dates = Enum.map(docs, & &1["_createdAt"])
    if dates == Enum.sort(dates), do: :ok, else: {:fail, "not ascending: #{inspect(dates)}"}
  end

  defp run_predicate(:order_ascending, _, _), do: {:fail, "need at least 2 docs to verify order"}

  defp run_predicate(:error_code_not_found, %{"error" => %{"code" => "not_found"}}, _), do: :ok
  defp run_predicate(:error_code_not_found, body, _), do: {:fail, "not a not_found envelope: #{inspect(body)}"}

  defp run_predicate(:error_code_unauthorized, %{"error" => %{"code" => "unauthorized"}}, _), do: :ok
  defp run_predicate(:error_code_unauthorized, body, _), do: {:fail, "not an unauthorized envelope: #{inspect(body)}"}

  defp run_predicate(:error_code_malformed, %{"error" => %{"code" => "malformed"}}, _), do: :ok
  defp run_predicate(:error_code_malformed, body, _), do: {:fail, "not a malformed envelope: #{inspect(body)}"}

  defp run_predicate(:schema_version_1, %{"_schemaVersion" => 1, "schemas" => schemas}, _) when is_list(schemas), do: :ok
  defp run_predicate(:schema_version_1, body, _), do: {:fail, "missing _schemaVersion/schemas: #{inspect(body)}"}

  defp run_predicate(:mutate_result_has_envelope, %{"transactionId" => tx, "results" => [r | _]}, _) when is_binary(tx) do
    doc = r["document"]
    if is_map(doc) && Map.has_key?(doc, "_id") && Map.has_key?(doc, "_rev") do
      :ok
    else
      {:fail, "result has no envelope document"}
    end
  end

  defp run_predicate(:mutate_result_has_envelope, body, _), do: {:fail, "no transactionId/results: #{inspect(body)}"}

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

  defp run_predicate(other, _, _), do: {:fail, "unknown predicate: #{inspect(other)}"}

  # ── Helpers ───────────────────────────────────────────────────────────

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
