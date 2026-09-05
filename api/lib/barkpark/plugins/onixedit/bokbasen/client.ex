defmodule Barkpark.Plugins.OnixEdit.Bokbasen.Client do
  @moduledoc """
  HTTP client for Bokbasen's metadata-import API.

  See `docs/spec/bokbasen-api-contract.md` for the wire-level contract.

  ## Lifecycle — single-phase async-poll (NOT two-phase claim)

  Boss resolved Q-A: Bokbasen exposes a **single-phase asynchronous
  ingestion** model. The earlier "two-phase claim" framing in the task
  brief is superseded.

      stage(xml)              POST  /metadata/import/onix/v2
        → {:ok, %{submission_id, poll_url}}

      poll(submission_id)     GET   /metadata/import/onix/v2/status/<id>
        → {:ok, %{status: :pending | :accepted | :rejected, details: map}}

      cancel(submission_id)   DELETE /metadata/import/onix/v2/<id>
        → :ok | {:error, %HTTPError{}}

  Note that Bokbasen's *real* metadata-import service has no abort
  endpoint — see contract §4.3. `cancel/2` is included so the WI4
  worker can express the intent against any Bokbasen-side cancel route
  that exists in a future iteration; today it surfaces 4xx as
  `%HTTPError{}` for the worker to handle semantically.
  CONTRACT_GAP: Bokbasen public docs do not specify a cancel endpoint;
  this implementation will return whatever Bokbasen actually responds
  with, and downstream code must treat 404/4xx as "cannot cancel,
  proceed to fail-or-resubmit per `<NotificationType>05`".

  ## Onix-Block-access scope (Q-J)

  Per the contract spec for the **publisher** sender role, the
  `Onix-Block-access` header advertises the blocks this client may
  write. We send `0,1,2,3,4,5,6,7,8,9,10,11,12` for the publisher role
  by default (overridden per-request via `:onix_block_access` opt).

  ## Rate limit (Q-G)

  Bokbasen does not publish a rate limit. We rely on Bokbasen's own
  `429 + Retry-After` and a config-gated, per-request floor:

    * `BOKBASEN_RATE_LIMIT_MS` env var, or
    * `:bokbasen_rate_limit_ms` Application env

  Default 0 (off) so test suites do not pay sleep cost. Production
  may set 1000 (1 req/sec). When > 0, the client `Process.sleep(N)`s
  at the START of each request; this blocks only the calling process,
  never the Auth GenServer.

  Concurrent cap of 10 in-flight requests is enforced by the WI4
  Oban worker queue, NOT here.

  ## Timeouts

  Default per-request receive timeout 30 s. Override via:

    * `BOKBASEN_HTTP_TIMEOUT_MS` env var (parsed at request time)
    * `:bokbasen_http_timeout_ms` Application env
    * `:timeout` opt on the call

  ## Error mapping

  Returns one of these structs (see `Errors` module):

    * `%HTTPError{}`           — 4xx/5xx not specialised
    * `%AuthError{}`           — 401 (after refresh) or 403
    * `%SchemaRejectionError{}`— 422 with parsed details
    * `%NetworkError{}`        — transport (timeout, refused, closed)
    * `%RateLimitError{}`      — 429 with Retry-After exceeding budget
  """

  alias Barkpark.Net.RetrySafety
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Auth

  alias Barkpark.Plugins.OnixEdit.Bokbasen.Errors.{
    AuthError,
    HTTPError,
    NetworkError,
    RateLimitError,
    SchemaRejectionError
  }

  alias Barkpark.Plugins.OnixEdit.Bokbasen.Settings

  @default_timeout_ms 30_000
  @default_max_retries 3
  @default_retry_delay_ms 200
  @rate_limit_budget_seconds 5
  @publisher_block_access "0,1,2,3,4,5,6,7,8,9,10,11,12"
  @stage_path "/metadata/import/onix/v2"
  @cancel_path "/metadata/import/onix/v2"
  @poll_path "/metadata/import/onix/v2/status"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Stage an ONIX submission. Returns `{:ok, %{submission_id, poll_url}}`
  on 201/202, or an error struct.
  """
  @spec stage(String.t(), keyword()) ::
          {:ok, %{submission_id: String.t(), poll_url: String.t()}}
          | {:error, struct()}
  def stage(onix_xml, opts \\ []) when is_binary(onix_xml) do
    base = base_url(opts)
    url = base <> @stage_path

    headers = [
      {"content-type", "application/xml"},
      {"user-agent", user_agent()},
      {"onix-block-access", block_access(opts)}
    ]

    case request(:post, url, headers, onix_xml, opts) do
      {:ok, %{status: status} = resp} when status in [200, 201, 202] ->
        {:ok, parse_stage_response(resp, base)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Poll a submission's status. Returns
  `{:ok, %{status: :pending | :accepted | :rejected, details: map}}` or
  an error struct.
  """
  @spec poll(String.t(), keyword()) ::
          {:ok, %{status: :pending | :accepted | :rejected, details: map()}}
          | {:error, struct()}
  def poll(submission_id, opts \\ []) when is_binary(submission_id) do
    base = base_url(opts)
    url = Keyword.get(opts, :poll_url) || "#{base}#{@poll_path}/#{submission_id}"

    headers = [
      {"accept", "application/json"},
      {"user-agent", user_agent()}
    ]

    case request(:get, url, headers, nil, opts) do
      {:ok, %{status: status, body: body}} when status in [200, 202] ->
        case parse_poll_body(body) do
          {:ok, _} = ok ->
            ok

          {:error, raw} ->
            {:error, %HTTPError{status: status, body: raw, headers: nil, endpoint: url}}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Cancel a pending submission. Returns `:ok` on 200/204, otherwise an
  error struct.
  """
  @spec cancel(String.t(), keyword()) :: :ok | {:error, struct()}
  def cancel(submission_id, opts \\ []) when is_binary(submission_id) do
    base = base_url(opts)
    url = "#{base}#{@cancel_path}/#{submission_id}"

    headers = [
      {"user-agent", user_agent()}
    ]

    case request(:delete, url, headers, nil, opts) do
      {:ok, %{status: status}} when status in [200, 204] -> :ok
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Internal request pipeline
  # ---------------------------------------------------------------------------

  defp request(method, url, headers, body, opts) do
    apply_rate_limit()
    do_request(method, url, headers, body, opts, 0, 0)
  end

  # attempt = total request count, auth_retries = number of 401 refreshes
  defp do_request(method, url, headers, body, opts, attempt, auth_retries) do
    with {:ok, bearer} <- Auth.token(),
         auth_headers = [{"authorization", "Bearer " <> bearer} | headers],
         {:request, response} <- {:request, perform(method, url, auth_headers, body, opts)} do
      handle_response(response, method, url, headers, body, opts, attempt, auth_retries)
    else
      {:error, %AuthError{} = err} -> {:error, err}
    end
  end

  defp perform(method, url, headers, body, opts) do
    timeout = timeout_ms(opts)

    req_opts =
      [
        url: url,
        headers: headers,
        method: method,
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

  defp handle_response({:ok, %{status: 401}}, method, url, headers, body, opts, _attempt, 0) do
    Auth.invalidate()
    do_request(method, url, headers, body, opts, 1, 1)
  end

  defp handle_response({:ok, %{status: 401}}, _method, url, _h, _b, _opts, _attempt, _) do
    {:error, %AuthError{status: 401, endpoint: url, message: "Token refresh failed"}}
  end

  defp handle_response({:ok, %{status: 403}}, _method, url, _h, _b, _opts, _attempt, _) do
    {:error, %AuthError{status: 403, endpoint: url, message: "Forbidden"}}
  end

  defp handle_response({:ok, %{status: 422} = resp}, _method, url, _h, _b, _opts, _a, _ar) do
    raw = resp.body
    details = parse_rejection_details(raw)

    {:error, %SchemaRejectionError{rejection_details: details, raw_body: raw, endpoint: url}}
  end

  defp handle_response(
         {:ok, %{status: 429} = resp},
         method,
         url,
         headers,
         body,
         opts,
         attempt,
         ar
       ) do
    retry_after = parse_retry_after(resp.headers)
    max = max_retries(opts)

    cond do
      attempt >= max ->
        {:error, %RateLimitError{retry_after_seconds: retry_after, endpoint: url}}

      retry_after > @rate_limit_budget_seconds ->
        {:error, %RateLimitError{retry_after_seconds: retry_after, endpoint: url}}

      true ->
        Process.sleep(retry_after * 1000)
        do_request(method, url, headers, body, opts, attempt + 1, ar)
    end
  end

  defp handle_response(
         {:ok, %{status: status} = resp},
         method,
         url,
         headers,
         body,
         opts,
         attempt,
         ar
       )
       when status >= 500 and status < 600 do
    max = max_retries(opts)

    # A 502/504 is authored by an intermediary about an ALREADY-FORWARDED
    # request, so a replay can duplicate a POST the origin already accepted.
    # `RetrySafety` lets 500/503 (origin-authored) keep retrying for any method.
    if attempt < max and RetrySafety.retry_after_status?(method, status, opts) do
      Process.sleep(retry_delay(attempt, opts))
      do_request(method, url, headers, body, opts, attempt + 1, ar)
    else
      {:error,
       %HTTPError{
         status: status,
         body: resp.body,
         headers: header_map(resp.headers),
         endpoint: url
       }}
    end
  end

  defp handle_response({:ok, %{status: status} = resp}, _method, _url, _h, _b, _opts, _a, _ar)
       when status >= 200 and status < 400 do
    {:ok, resp}
  end

  defp handle_response({:ok, %{status: status} = resp}, _method, url, _h, _b, _opts, _a, _ar) do
    {:error,
     %HTTPError{status: status, body: resp.body, headers: header_map(resp.headers), endpoint: url}}
  end

  defp handle_response({:error, exception}, method, url, headers, body, opts, attempt, ar) do
    reason = exception_reason(exception)
    max = max_retries(opts)

    # `:timeout` is the one reason under which the request may ALREADY have
    # been accepted — only the response was lost. Replaying a POST there mints
    # a second ONIX submission. `RetrySafety` allows the replay only for an
    # idempotent method or a reason that proves nothing was ever sent.
    if attempt < max and transient_reason?(reason) and
         RetrySafety.retry_after_transport_error?(method, reason, opts) do
      Process.sleep(retry_delay(attempt, opts))
      do_request(method, url, headers, body, opts, attempt + 1, ar)
    else
      {:error, %NetworkError{reason: reason, endpoint: url}}
    end
  end

  # ---------------------------------------------------------------------------
  # Response parsing
  # ---------------------------------------------------------------------------

  defp parse_stage_response(%{status: status, headers: headers, body: body}, base) do
    location = get_header(headers, "location")
    json = decode_json(body)

    submission_id =
      cond do
        is_map(json) and is_binary(json["submission_id"]) -> json["submission_id"]
        is_binary(location) -> location |> String.split("/") |> List.last()
        true -> nil
      end

    poll_url =
      cond do
        is_map(json) and is_binary(json["poll_url"]) -> json["poll_url"]
        is_binary(location) -> location
        is_binary(submission_id) -> "#{base}#{@poll_path}/#{submission_id}"
        true -> nil
      end

    %{submission_id: submission_id, poll_url: poll_url, status: status}
    |> Map.delete(:status)
  end

  defp parse_poll_body(body) do
    case decode_json(body) do
      %{"status" => status_str} = m ->
        case atomize_status(status_str) do
          {:ok, atom} -> {:ok, %{status: atom, details: m}}
          :error -> {:error, body}
        end

      _ ->
        case parse_xml_state(body) do
          {:ok, atom, details} -> {:ok, %{status: atom, details: details}}
          :error -> {:error, body}
        end
    end
  end

  defp parse_rejection_details(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp parse_rejection_details(body) when is_map(body), do: body
  defp parse_rejection_details(body), do: body

  defp atomize_status("pending"), do: {:ok, :pending}
  defp atomize_status("accepted"), do: {:ok, :accepted}
  defp atomize_status("rejected"), do: {:ok, :rejected}
  defp atomize_status("UNPROCESSED"), do: {:ok, :pending}
  defp atomize_status("COMPLETED"), do: {:ok, :accepted}
  defp atomize_status("FAILED"), do: {:ok, :rejected}
  defp atomize_status(_), do: :error

  defp parse_xml_state(body) when is_binary(body) do
    case Regex.run(~r/<state>([^<]+)<\/state>/, body) do
      [_, state] ->
        case atomize_status(state) do
          {:ok, atom} -> {:ok, atom, %{"state" => state, "raw" => body}}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_xml_state(_), do: :error

  defp decode_json(body) when is_map(body) and not is_struct(body), do: body

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, m} -> m
      _ -> nil
    end
  end

  defp decode_json(_), do: nil

  # ---------------------------------------------------------------------------
  # Header utilities
  # ---------------------------------------------------------------------------

  defp get_header(headers, name) when is_map(headers) and not is_struct(headers) do
    name_lc = String.downcase(name)

    Enum.find_value(headers, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == name_lc, do: extract_first(v)

      _ ->
        nil
    end)
  end

  defp get_header(headers, name) when is_list(headers) do
    name_lc = String.downcase(name)

    Enum.find_value(headers, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == name_lc, do: extract_first(v)

      _ ->
        nil
    end)
  end

  defp get_header(_, _), do: nil

  defp extract_first(v) when is_list(v), do: List.first(v)
  defp extract_first(v), do: v

  defp header_map(headers) when is_list(headers) do
    Enum.into(headers, %{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp header_map(headers) when is_map(headers), do: headers
  defp header_map(_), do: %{}

  defp parse_retry_after(headers) do
    case get_header(headers, "retry-after") do
      nil ->
        0

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, _} -> n
          :error -> 0
        end

      v when is_integer(v) ->
        v

      _ ->
        0
    end
  end

  # ---------------------------------------------------------------------------
  # Configuration helpers
  # ---------------------------------------------------------------------------

  defp base_url(opts) do
    case Keyword.get(opts, :base_url) do
      url when is_binary(url) and url != "" ->
        trim_trailing_slash(url)

      _ ->
        case Settings.get_credentials().api_base do
          url when is_binary(url) and url != "" -> trim_trailing_slash(url)
          _ -> ""
        end
    end
  end

  defp trim_trailing_slash(url), do: String.trim_trailing(url, "/")

  defp block_access(opts) do
    Keyword.get(opts, :onix_block_access, @publisher_block_access)
  end

  defp user_agent do
    "Barkpark/#{Application.spec(:barkpark, :vsn) |> to_string()} (BokbasenClient)"
  end

  defp timeout_ms(opts) do
    cond do
      n = Keyword.get(opts, :timeout) ->
        n

      v = System.get_env("BOKBASEN_HTTP_TIMEOUT_MS") ->
        case Integer.parse(v) do
          {n, _} -> n
          :error -> @default_timeout_ms
        end

      true ->
        Application.get_env(:barkpark, :bokbasen_http_timeout_ms, @default_timeout_ms)
    end
  end

  defp max_retries(opts) do
    Keyword.get(opts, :max_retries, @default_max_retries)
  end

  defp retry_delay(attempt, opts) do
    case Keyword.get(opts, :retry_delay_ms) do
      n when is_integer(n) -> n
      _ -> @default_retry_delay_ms * (attempt + 1)
    end
  end

  defp apply_rate_limit do
    ms =
      cond do
        v = System.get_env("BOKBASEN_RATE_LIMIT_MS") ->
          case Integer.parse(v) do
            {n, _} -> n
            :error -> 0
          end

        true ->
          Application.get_env(:barkpark, :bokbasen_rate_limit_ms, 0)
      end

    if is_integer(ms) and ms > 0, do: Process.sleep(ms), else: :ok
  end

  defp transient_reason?(:timeout), do: true
  defp transient_reason?(:closed), do: true
  defp transient_reason?(:econnrefused), do: true
  defp transient_reason?(:econnreset), do: true
  defp transient_reason?(:nxdomain), do: true
  defp transient_reason?(_), do: false

  defp exception_reason(exception) do
    cond do
      is_map(exception) and Map.has_key?(exception, :reason) -> Map.get(exception, :reason)
      is_exception(exception) -> Exception.message(exception)
      true -> exception
    end
  end
end
