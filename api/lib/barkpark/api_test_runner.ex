defmodule Barkpark.ApiTestRunner do
  @moduledoc """
  Fires Plugin api_test_spec specs against the configured base_url and
  returns structured results.

  Per plan §0 (barkpark-bsp):
  - Q1: cleanup steps in spec fire ALWAYS after asserts.
  - Q3: auth modes :none | :admin | {:token, str} | {:plugin_setting, key}.
  - Q5: single-request specs only (no chaining).
  - Q6: per-test try/rescue isolation.
  - Q8: base_url from Application.get_env, default http://localhost:4000.

  ## Result shape

      %{
        name: "...",
        spec: original_spec,
        request: %{method:, path:, url:, headers:, body:},
        response: %{status:, body:, headers:, duration_ms:} | nil,
        asserts: [{tag, :pass | :fail, message}],
        cleanup: [%{method:, path:, status:, duration_ms:} | %{error: msg}],
        duration_ms: total_ms,
        status: :pass | :fail | :error | :unverified,
        error_message: nil | String.t()
      }

  `:unverified` is a THIRD state, not a pass: it fires only when the spec
  carries zero `:asserts` (nothing was actually checked against the
  response), so a 500 can never badge the same as a real, checked pass.
  """

  alias Barkpark.ApiTestRunner.Asserts
  alias Barkpark.Plugin
  require Logger

  @default_base_url "http://localhost:4000"
  @request_timeout_ms 10_000

  @doc """
  Run a list of specs. Returns a list of result maps in the same order.
  """
  @spec run([Plugin.api_test_spec()], keyword()) :: [map()]
  def run(specs, opts \\ []) when is_list(specs) do
    base_url = Keyword.get(opts, :base_url) || configured_base_url()
    Enum.map(specs, &run_one(&1, base_url, opts))
  end

  @doc """
  Run one spec. Wrapped in try/rescue — never raises.
  """
  @spec run_one(Plugin.api_test_spec(), String.t(), keyword()) :: map()
  def run_one(spec, base_url, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)
    request = build_request(spec, base_url)

    {response, asserts} =
      try do
        case fire(request, opts) do
          {:ok, resp} ->
            results =
              Enum.map(Map.get(spec, :asserts, []), fn a ->
                {a, do_evaluate(a, resp)}
              end)

            {resp, Enum.map(results, fn {tag, {kind, msg}} -> {tag, kind, msg} end)}

          {:error, msg} ->
            {nil, [{:request, :error, msg}]}
        end
      rescue
        e -> {nil, [{:exception, :error, Exception.message(e)}]}
      end

    cleanup_results = fire_cleanup(Map.get(spec, :cleanup, []), base_url, opts)

    status = compute_status(response, asserts)

    %{
      name: Map.get(spec, :name, "(unnamed)"),
      spec: spec,
      request: redact_secret(request),
      response: redact_response(response),
      asserts: asserts,
      cleanup: cleanup_results,
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      status: status,
      error_message: status_error_message(asserts)
    }
  end

  # ----- build_request / fire ---------------------------------------------

  defp build_request(spec, base_url) do
    method = Map.fetch!(spec, :method)
    path = Map.fetch!(spec, :path)
    url = base_url <> path

    headers =
      spec
      |> Map.get(:headers, %{})
      |> Map.new()
      |> apply_auth(Map.get(spec, :auth, :none))

    body = Map.get(spec, :body)

    %{method: method, path: path, url: url, headers: headers, body: body}
  end

  defp apply_auth(headers, :none), do: headers

  defp apply_auth(headers, :admin) do
    token = resolve_admin_token()
    Map.put(headers, "authorization", "Bearer #{token}")
  end

  defp apply_auth(headers, {:token, t}) when is_binary(t) do
    Map.put(headers, "authorization", "Bearer #{t}")
  end

  defp apply_auth(headers, {:plugin_setting, key}) when is_binary(key) do
    case resolve_plugin_setting(key) do
      nil -> headers
      val -> Map.put(headers, "authorization", "Bearer #{val}")
    end
  end

  defp apply_auth(headers, _), do: headers

  defp resolve_admin_token do
    System.get_env("BARKPARK_ADMIN_TOKEN") ||
      Application.get_env(:barkpark, :admin_dev_token, "barkpark-dev-token")
  end

  # Read a value from the Cloak-encrypted plugin_settings store. The
  # `key` is dot-namespaced as in `setting_field/0` — leading segment
  # picks the plugin_settings row, remainder is the key inside that map.
  # Example: `"bokbasen.api_token"` reads the `"api_token"` field of the
  # `"bokbasen"` settings row. Returns nil if the row, the key, or the
  # Settings module itself is missing.
  defp resolve_plugin_setting(key) do
    cond do
      not (Code.ensure_loaded?(Barkpark.Plugins.Settings) and
               function_exported?(Barkpark.Plugins.Settings, :get, 1)) ->
        nil

      true ->
        case String.split(key, ".", parts: 2) do
          [plugin_name, field] ->
            case Barkpark.Plugins.Settings.get(plugin_name) do
              {:ok, settings} when is_map(settings) -> Map.get(settings, field)
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  defp fire(%{method: method, url: url, headers: headers, body: body}, opts) do
    started_at = System.monotonic_time(:millisecond)

    req_opts = [
      method: method,
      url: url,
      headers: Enum.into(headers, []),
      receive_timeout: Keyword.get(opts, :timeout_ms, @request_timeout_ms),
      retry: false,
      decode_body: false
    ]

    req_opts =
      case body do
        nil -> req_opts
        b when is_binary(b) -> [{:body, b} | req_opts]
        b when is_map(b) -> [{:json, b} | req_opts]
        b -> [{:body, to_string(b)} | req_opts]
      end

    # Tests may thread extra Req options (e.g. `plug: {Req.Test, MyStub}`)
    # via `:req_options` — appended last so caller opts win on overlap.
    req_opts = req_opts ++ Keyword.get(opts, :req_options, [])

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body_bin, headers: response_headers}} ->
        {:ok,
         %{
           status: status,
           body: ensure_binary_body(body_bin),
           headers: response_headers,
           duration_ms: System.monotonic_time(:millisecond) - started_at
         }}

      {:error, %{__exception__: true} = e} ->
        {:error, Exception.message(e)}

      {:error, other} ->
        {:error, inspect(other)}
    end
  end

  defp ensure_binary_body(nil), do: nil
  defp ensure_binary_body(b) when is_binary(b), do: b
  defp ensure_binary_body(b), do: inspect(b)

  defp do_evaluate(assert, response), do: Asserts.evaluate(assert, response)

  # ----- cleanup ----------------------------------------------------------

  defp fire_cleanup(steps, base_url, opts) when is_list(steps) do
    Enum.map(steps, fn step ->
      method = Map.fetch!(step, :method)
      path = Map.fetch!(step, :path)
      url = base_url <> path

      headers =
        step
        |> Map.get(:headers, %{})
        |> Map.new()
        |> apply_auth(Map.get(step, :auth, :admin))

      result =
        try do
          fire(
            %{
              method: method,
              url: url,
              path: path,
              headers: headers,
              body: Map.get(step, :body)
            },
            opts
          )
        rescue
          e -> {:error, Exception.message(e)}
        end

      case result do
        {:ok, %{status: s, duration_ms: d}} ->
          %{method: method, path: path, status: s, duration_ms: d}

        {:error, msg} ->
          %{method: method, path: path, error: msg}
      end
    end)
  end

  defp fire_cleanup(_, _, _), do: []

  # ----- status / redaction ----------------------------------------------

  defp compute_status(nil, _), do: :error

  # A response landed but the spec checked nothing against it — this is the
  # zero-expectation case the gate-integrity fix targets: :unverified is a
  # THIRD state, never folded into :pass, so a 500 can't badge green.
  defp compute_status(_resp, []), do: :unverified

  defp compute_status(_resp, asserts) do
    cond do
      Enum.any?(asserts, fn {_, kind, _} -> kind == :error end) -> :error
      Enum.any?(asserts, fn {_, kind, _} -> kind == :fail end) -> :fail
      true -> :pass
    end
  end

  defp status_error_message(asserts) do
    Enum.find_value(asserts, fn
      {_, :error, msg} -> msg
      _ -> nil
    end)
  end

  defp redact_secret(%{headers: headers} = request) do
    redacted =
      headers
      |> Map.new()
      |> Map.update("authorization", nil, fn _ -> "[redacted]" end)

    %{request | headers: redacted}
  end

  defp redact_secret(other), do: other

  defp redact_response(nil), do: nil
  defp redact_response(resp), do: resp

  defp configured_base_url do
    Application.get_env(:barkpark, :api_test_runner_base_url, @default_base_url)
  end
end
