defmodule BarkparkWeb.Studio.ApiTesterLive.Request do
  @moduledoc "Pure request/curl/assertion logic for the API-tester LiveView, extracted from the view shell."

  alias Barkpark.ApiTester.Runner

  def decode_body(nil), do: nil
  def decode_body(""), do: nil

  def decode_body(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  # No asserts = informational spec — nothing was actually checked against
  # the response, so this is NOT a pass. :unverified is a third state (never
  # a failure either): it badges distinctly from :pass so a 500 returned by
  # a zero-expectation spec can't read green. See runner.ex's `check/2` and
  # api_test_runner.ex's `compute_status/2` for the sibling sites.
  def compute_plugin_status([]), do: :unverified

  def compute_plugin_status(asserts_results) do
    if Enum.all?(asserts_results, &(&1.status == :pass)), do: :pass, else: :fail
  end

  def run_plugin_cleanup([], _opts), do: []

  def run_plugin_cleanup(steps, opts) when is_list(steps) do
    base = Keyword.get(opts, :base, "http://localhost:4000")
    token = Keyword.get(opts, :token, "")

    Enum.map(steps, fn step ->
      method = Map.get(step, :method)
      path = Map.get(step, :path)

      base_headers = Map.get(step, :headers, %{}) || %{}

      headers =
        case Map.get(step, :auth, :admin) do
          :none ->
            base_headers

          _ ->
            if token != "" do
              Map.put_new(base_headers, "authorization", "Bearer #{token}")
            else
              base_headers
            end
        end

      body =
        case Map.get(step, :body) do
          nil -> nil
          m when is_map(m) -> Jason.encode!(m)
          s when is_binary(s) -> s
          other -> to_string(other)
        end

      started_at = System.monotonic_time(:millisecond)

      req_opts = [
        method: method,
        url: base <> path,
        headers: Enum.into(headers, []),
        receive_timeout: 10_000,
        retry: false,
        decode_body: false
      ]

      req_opts = if body, do: [{:body, body} | req_opts], else: req_opts

      try do
        case Req.request(req_opts) do
          {:ok, %Req.Response{status: status}} ->
            %{
              method: method,
              path: path,
              status: status,
              duration_ms: System.monotonic_time(:millisecond) - started_at
            }

          {:error, e} ->
            %{method: method, path: path, error: Exception.message(e)}
        end
      rescue
        e -> %{method: method, path: path, error: "cleanup raised: " <> Exception.message(e)}
      end
    end)
  end

  def build_curl(%{kind: :reference}, _form_state, _token, _base), do: ""

  def build_curl(endpoint, form_state, token, base) do
    req =
      Runner.build_request(endpoint, form_state, %{token: token, base: base})

    parts = ["curl -sS"]
    parts = if req.method == "GET", do: parts, else: parts ++ ["-X", req.method]

    header_parts = Enum.flat_map(req.headers, fn {k, v} -> ["-H", shell_escape("#{k}: #{v}")] end)

    parts = parts ++ header_parts

    parts =
      if is_binary(req.body_text) and req.body_text != "" do
        parts ++ ["-d", shell_escape(req.body_text)]
      else
        parts
      end

    parts = parts ++ [shell_escape(req.url)]

    Enum.join(parts, " ")
  end

  def shell_escape(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end
end
