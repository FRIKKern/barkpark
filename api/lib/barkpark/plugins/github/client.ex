defmodule Barkpark.Plugins.Github.Client do
  @moduledoc """
  Thin `Req` wrapper over the GitHub REST verbs the outbound mirror needs.

  Every verb authenticates with a `Bearer <installation-token>` minted by
  `Barkpark.Plugins.Github.Auth` and targets
  `<github_api_base>/repos/:owner/:repo/...`. `github_api_base` is read
  from `Application.get_env(:barkpark, Barkpark.Plugins.Github)[:github_api_base]`
  (defaults to `https://api.github.com`; tests inject a Bypass base). It
  may be overridden per call with the `:base_url` opt.

  ## Verbs

    * `create_issue/2`  — `POST   /repos/:repo/issues`
    * `update_issue/3`  — `PATCH  /repos/:repo/issues/:n` (a field-set PATCH
      is naturally idempotent — re-applying the same desired state is a no-op)
    * `close_issue/3`   — `PATCH` `state: "closed"` + `state_reason`
    * `add_labels/3`    — `POST   /repos/:repo/issues/:n/labels`
    * `create_comment/3`— `POST   /repos/:repo/issues/:n/comments`

  `:repo` is `"owner/name"`. Each returns `{:ok, decoded_body}` on 2xx or
  an `{:error, struct}` from `Errors`.

  ## Error classification

    * 401 → refresh the token once, then `%AuthError{}`
    * 403/429 with `Retry-After` / `X-RateLimit-*` → `%RateLimitError{}`
      (the client NEVER sleeps — it surfaces `retry_after` so the wave-2
      Oban job can `{:snooze, retry_after}`; charter D9)
    * 403 with no rate headers → `%AuthError{}` (forbidden / bad scope)
    * 404 / 410 → `%NotFound{}` (410 Gone = a detached issue)
    * 5xx → retried up to `:max_retries` then `%NetworkError{reason: {:http, s}}`
    * transport (timeout/refused/closed) → `%NetworkError{}`
    * any other non-2xx → `%NetworkError{reason: {:http, s}}`
  """

  alias Barkpark.Plugins.Github.Auth

  alias Barkpark.Plugins.Github.Errors.{
    AuthError,
    NetworkError,
    NotFound,
    RateLimitError
  }

  @config_key Barkpark.Plugins.Github
  @default_api_base "https://api.github.com"
  @default_timeout_ms 30_000
  @default_max_retries 3
  @default_retry_delay_ms 200
  @github_api_version "2022-11-28"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Create an issue. `params` is a map like
  `%{title: ..., body: ..., labels: [...]}`.
  """
  @spec create_issue(String.t(), map(), keyword()) :: {:ok, map()} | {:error, struct()}
  def create_issue(repo, params, opts \\ []) when is_binary(repo) and is_map(params) do
    request(:post, "/repos/#{repo}/issues", params, opts)
  end

  @doc """
  Update (PATCH) an issue's fields. Idempotent for a desired field-set.
  """
  @spec update_issue(String.t(), integer() | String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, struct()}
  def update_issue(repo, number, params, opts \\ [])
      when is_binary(repo) and is_map(params) do
    request(:patch, "/repos/#{repo}/issues/#{number}", params, opts)
  end

  @doc """
  Close an issue with a lifecycle reason.

  `reason` is `:completed` (done) or `:not_planned` (cancelled) —
  the charter's lifecycle mapping. Strings are accepted verbatim.
  """
  @spec close_issue(String.t(), integer() | String.t(), atom() | String.t(), keyword()) ::
          {:ok, map()} | {:error, struct()}
  def close_issue(repo, number, reason, opts \\ []) when is_binary(repo) do
    body = %{"state" => "closed", "state_reason" => state_reason(reason)}
    request(:patch, "/repos/#{repo}/issues/#{number}", body, opts)
  end

  @doc "Add labels to an issue (additive — GitHub merges, never replaces)."
  @spec add_labels(String.t(), integer() | String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, struct()}
  def add_labels(repo, number, labels, opts \\ [])
      when is_binary(repo) and is_list(labels) do
    request(:post, "/repos/#{repo}/issues/#{number}/labels", %{"labels" => labels}, opts)
  end

  @doc "Post a comment on an issue."
  @spec create_comment(String.t(), integer() | String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, struct()}
  def create_comment(repo, number, body, opts \\ [])
      when is_binary(repo) and is_binary(body) do
    request(:post, "/repos/#{repo}/issues/#{number}/comments", %{"body" => body}, opts)
  end

  defp state_reason(:completed), do: "completed"
  defp state_reason(:not_planned), do: "not_planned"
  defp state_reason(reason) when is_binary(reason), do: reason
  defp state_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  # ---------------------------------------------------------------------------
  # Request pipeline
  # ---------------------------------------------------------------------------

  defp request(method, path, body, opts) do
    url = base_url(opts) <> path
    do_request(method, url, body, opts, 0, 0)
  end

  # attempt = total request count, auth_retries = number of 401 refreshes
  defp do_request(method, url, body, opts, attempt, auth_retries) do
    case Auth.token() do
      {:ok, bearer} ->
        case perform(method, url, bearer, body, opts) do
          {:ok, response} ->
            handle_response(response, method, url, body, opts, attempt, auth_retries)

          {:error, exception} ->
            handle_transport(exception, method, url, body, opts, attempt, auth_retries)
        end

      {:error, %AuthError{} = err} ->
        {:error, err}
    end
  end

  defp perform(method, url, bearer, body, opts) do
    timeout = timeout_ms(opts)

    req_opts =
      [
        url: url,
        method: method,
        headers: [
          {"authorization", "Bearer " <> bearer},
          {"accept", "application/vnd.github+json"},
          {"x-github-api-version", @github_api_version},
          {"user-agent", user_agent()}
        ],
        receive_timeout: timeout,
        connect_options: [timeout: timeout],
        retry: false
      ]
      |> maybe_put_json(body)

    try do
      Req.request(Req.new(req_opts))
    rescue
      e -> {:error, e}
    end
  end

  defp maybe_put_json(req_opts, body) when is_map(body), do: Keyword.put(req_opts, :json, body)
  defp maybe_put_json(req_opts, _), do: req_opts

  # ---------------------------------------------------------------------------
  # Response handling / classification
  # ---------------------------------------------------------------------------

  defp handle_response({:ok, resp}, m, u, b, o, a, ar), do: classify(resp, m, u, b, o, a, ar)
  defp handle_response(%{status: _} = resp, m, u, b, o, a, ar), do: classify(resp, m, u, b, o, a, ar)

  defp classify(%{status: status} = resp, _m, _u, _b, _o, _a, _ar)
       when status >= 200 and status < 300 do
    {:ok, decode_body(resp.body)}
  end

  defp classify(%{status: 401}, method, url, body, opts, _attempt, 0) do
    Auth.invalidate()
    do_request(method, url, body, opts, 1, 1)
  end

  defp classify(%{status: 401}, _method, url, _body, _opts, _attempt, _ar) do
    {:error, %AuthError{status: 401, endpoint: url, message: "token refresh failed"}}
  end

  defp classify(%{status: status} = resp, _method, url, _body, _opts, _attempt, _ar)
       when status in [403, 429] do
    if rate_limited?(resp.headers) do
      {:error, %RateLimitError{retry_after: retry_after_seconds(resp.headers), endpoint: url}}
    else
      {:error, %AuthError{status: status, endpoint: url, message: "forbidden"}}
    end
  end

  defp classify(%{status: status}, _method, url, _body, _opts, _attempt, _ar)
       when status in [404, 410] do
    {:error, %NotFound{status: status, endpoint: url, message: "issue or repo not found"}}
  end

  defp classify(%{status: status}, method, url, body, opts, attempt, ar)
       when status >= 500 and status < 600 do
    max = max_retries(opts)

    if attempt < max do
      Process.sleep(retry_delay(attempt, opts))
      do_request(method, url, body, opts, attempt + 1, ar)
    else
      {:error, %NetworkError{reason: {:http, status}, endpoint: url}}
    end
  end

  defp classify(%{status: status}, _method, url, _body, _opts, _attempt, _ar) do
    {:error, %NetworkError{reason: {:http, status}, endpoint: url}}
  end

  defp handle_transport(exception, method, url, body, opts, attempt, ar) do
    reason = exception_reason(exception)
    max = max_retries(opts)

    if attempt < max and transient_reason?(reason) do
      Process.sleep(retry_delay(attempt, opts))
      do_request(method, url, body, opts, attempt + 1, ar)
    else
      {:error, %NetworkError{reason: reason, endpoint: url}}
    end
  end

  # ---------------------------------------------------------------------------
  # Header / rate-limit helpers
  # ---------------------------------------------------------------------------

  # A 403/429 is a rate limit when GitHub sends a Retry-After OR signals the
  # primary-limit reset with X-RateLimit-Remaining: 0. A bare 403 (bad scope)
  # has neither and is classified as an AuthError instead.
  defp rate_limited?(headers) do
    not is_nil(get_header(headers, "retry-after")) or
      get_header(headers, "x-ratelimit-remaining") == "0"
  end

  defp retry_after_seconds(headers) do
    cond do
      ra = get_header(headers, "retry-after") ->
        parse_int(ra)

      reset = get_header(headers, "x-ratelimit-reset") ->
        max(0, parse_int(reset) - System.system_time(:second))

      true ->
        0
    end
  end

  defp get_header(headers, name) when is_map(headers) and not is_struct(headers) do
    find_header(headers, name)
  end

  defp get_header(headers, name) when is_list(headers), do: find_header(headers, name)
  defp get_header(_, _), do: nil

  defp find_header(headers, name) do
    name_lc = String.downcase(name)

    Enum.find_value(headers, fn
      {k, v} when is_binary(k) -> if String.downcase(k) == name_lc, do: extract_first(v)
      _ -> nil
    end)
  end

  defp extract_first(v) when is_list(v), do: List.first(v)
  defp extract_first(v), do: v

  defp parse_int(v) when is_integer(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_int(_), do: 0

  # ---------------------------------------------------------------------------
  # Body decoding
  # ---------------------------------------------------------------------------

  defp decode_body(body) when is_map(body) and not is_struct(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, m} -> m
      _ -> body
    end
  end

  defp decode_body(other), do: other

  # ---------------------------------------------------------------------------
  # Config helpers
  # ---------------------------------------------------------------------------

  defp base_url(opts) do
    case Keyword.get(opts, :base_url) do
      url when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/")

      _ ->
        case config()[:github_api_base] do
          url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
          _ -> @default_api_base
        end
    end
  end

  defp config, do: Application.get_env(:barkpark, @config_key, [])

  defp user_agent do
    "Barkpark/#{Application.spec(:barkpark, :vsn) |> to_string()} (GithubMirror)"
  end

  defp timeout_ms(opts), do: Keyword.get(opts, :timeout, @default_timeout_ms)

  defp max_retries(opts), do: Keyword.get(opts, :max_retries, @default_max_retries)

  defp retry_delay(attempt, opts) do
    case Keyword.get(opts, :retry_delay_ms) do
      n when is_integer(n) -> n
      _ -> @default_retry_delay_ms * (attempt + 1)
    end
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
