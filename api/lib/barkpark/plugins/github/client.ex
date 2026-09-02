defmodule Barkpark.Plugins.Github.Client do
  @moduledoc """
  Thin `Req` wrapper over the GitHub REST verbs the outbound mirror needs.

  Every verb authenticates with a `Bearer <installation-token>` minted by
  `Barkpark.Plugins.Github.Auth` and targets
  `<base>/repos/:owner/:repo/...`. The base is read from
  `Application.get_env(:barkpark, Barkpark.Plugins.Github)`, preferring
  `:github_api_base` and falling back to `:api_base` (the key `Auth` reads,
  so one config key drives both the token exchange and the REST verbs) —
  defaulting to `https://api.github.com`; tests inject a Bypass base. It
  may be overridden per call with the `:base_url` opt.

  ## Verbs

    * `create_issue/2`  — `POST   /repos/:repo/issues`
    * `get_issue/2`     — `GET    /repos/:repo/issues/:n` (read the issue's
      CURRENT state so the mirror can fingerprint out-of-band drift; charter D7)
    * `update_issue/3`  — `PATCH  /repos/:repo/issues/:n` (a field-set PATCH
      is naturally idempotent — re-applying the same desired state is a no-op)
    * `close_issue/3`   — `PATCH` `state: "closed"` + `state_reason`
    * `add_labels/3`    — `POST   /repos/:repo/issues/:n/labels`
    * `create_comment/3`— `POST   /repos/:repo/issues/:n/comments`
    * `add_sub_issue/4` — `POST   /repos/:repo/issues/:n/sub_issues` (native
      sub-issue link, keyed on the child's DATABASE id; charter D11)
    * `graphql/3`       — `POST   /graphql` (Projects v2; charter D10). A
      GraphQL `200 OK` carrying a top-level `"errors"` array surfaces as
      `%NetworkError{reason: {:graphql, errors}}`.

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

  alias Barkpark.Net.RetrySafety
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
  # Upper bound on a peer-supplied backoff. The value flows into an Oban
  # {:snooze, n} (Github.MirrorJob), and a snooze never consumes an attempt, so
  # an absurd Retry-After or a skewed clock would park the job effectively
  # forever and leak a scheduled row the Pruner never reclaims. 300s matches the
  # numeric precedent in Barkpark.Webhooks.Dispatcher (@retry_after_max_ms
  # 300_000); it is deliberately NOT wired to that webhooks-namespaced bound,
  # nor to @rate_limit_budget_seconds elsewhere (an in-process sleep budget, far
  # too small to serve as a park ceiling).
  @retry_after_max_seconds 300

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
  Read (GET) a single issue's CURRENT state.

  A thin sibling of `update_issue/3` — same auth, base resolution and error
  classification. The mirror uses it to fingerprint the ledger-owned fields
  (`title`/`body`/`labels`/`state`) BEFORE it PATCHes, so an out-of-band human
  edit is RECORDED as a quarantine conflict before the ledger overwrites it
  (charter D7). A 404/410 → `%NotFound{}`, which the mirror routes to the
  `detached` branch (the issue vanished between drain and reconcile).

  This read is used ONLY to fingerprint for the conflict record — it NEVER
  writes a GitHub value back into a task field (charter D5).
  """
  @spec get_issue(String.t(), integer() | String.t(), keyword()) ::
          {:ok, map()} | {:error, struct()}
  def get_issue(repo, number, opts \\ []) when is_binary(repo) do
    request(:get, "/repos/#{repo}/issues/#{number}", nil, opts)
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

  @doc """
  Execute a GraphQL query/mutation against `<base>/graphql`.

  POSTs `%{"query" => query, "variables" => variables}` through the SAME auth,
  base resolution, timeout and error classification as the REST verbs — the
  Projects v2 dashboard (charter D10) speaks GraphQL, not `/repos/...`.

  One GraphQL-specific wrinkle: a GraphQL response is `200 OK` even when it
  carries a top-level `"errors"` array. So AFTER the normal 2xx decode, a
  non-empty `"errors"` list surfaces as
  `%NetworkError{reason: {:graphql, errors}}` (reusing the existing
  `NetworkError` — D8's 4-type error set is fixed, GraphQL errors ride it).
  A clean 2xx returns `{:ok, data}` (the `"data"` value), falling back to the
  whole decoded body when a response carries no `"data"` key.

  Transport failures, `401`, `403`/`429` rate limits and `5xx` classify
  EXACTLY as the REST verbs do (charter D9) — only the 2xx path differs.
  """
  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, struct()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) do
    body = %{"query" => query, "variables" => variables}

    case request(:post, "/graphql", body, opts) do
      {:ok, %{"errors" => [_ | _] = errors}} ->
        {:error,
         %NetworkError{reason: {:graphql, errors}, endpoint: base_url(opts) <> "/graphql"}}

      {:ok, %{"data" => data}} ->
        {:ok, data}

      {:ok, other} ->
        {:ok, other}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Link an existing issue as a NATIVE sub-issue of `parent_number`.

  `POST /repos/:repo/issues/:parent_number/sub_issues` with
  `%{"sub_issue_id" => child_issue_id}`. GitHub's sub-issues API keys on the
  child's DATABASE id (the `"id"` field from `get_issue/3`), NOT its number —
  the caller resolves it. A thin sibling of `add_labels/3`: same auth, base
  resolution and error classification.

  A `422` ("already a sub-issue") surfaces as `%NetworkError{reason: {:http,
  422}}` like any other 4xx — it is NOT special-cased here; the Relations
  caller maps `422 → :ok`.
  """
  @spec add_sub_issue(String.t(), integer() | String.t(), integer() | String.t(), keyword()) ::
          {:ok, map()} | {:error, struct()}
  def add_sub_issue(repo, parent_number, child_issue_id, opts \\ [])
      when is_binary(repo) do
    request(
      :post,
      "/repos/#{repo}/issues/#{parent_number}/sub_issues",
      %{"sub_issue_id" => child_issue_id},
      opts
    )
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

  defp handle_response(%{status: _} = resp, m, u, b, o, a, ar),
    do: classify(resp, m, u, b, o, a, ar)

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

    # A 502/504 is authored by an intermediary about an ALREADY-FORWARDED
    # request, so a replay can duplicate a POST the origin already accepted.
    # `RetrySafety` lets 500/503 (origin-authored) keep retrying for any method.
    if attempt < max and RetrySafety.retry_after_status?(method, status, opts) do
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

    # `:timeout` is the one reason under which the request may ALREADY have
    # been accepted — only the response was lost. Replaying a POST there mints
    # a second GitHub issue for one task. `RetrySafety` allows the replay only
    # for an idempotent method or a reason that proves nothing was ever sent.
    if attempt < max and transient_reason?(reason) and
         RetrySafety.retry_after_transport_error?(method, reason, opts) do
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

  # X-RateLimit-Reset is an ABSOLUTE epoch instant transmitted by the peer, so
  # subtracting local wall clock is the only correct computation — a monotonic
  # read is meaningless against GitHub's epoch. What is guarded here is the
  # missing UPPER bound on an externally supplied value, not the clock source.
  # `now` is injectable so the clamp is provable without sleeps (same shape as
  # Github.DrainWorker.backoff_ms/1); the production call site stays arity-1.
  @doc false
  @spec retry_after_seconds(term(), integer()) :: non_neg_integer()
  def retry_after_seconds(headers, now \\ System.system_time(:second)) do
    seconds =
      cond do
        ra = get_header(headers, "retry-after") ->
          parse_int(ra)

        reset = get_header(headers, "x-ratelimit-reset") ->
          max(0, parse_int(reset) - now)

        true ->
          0
      end

    seconds |> max(0) |> min(@retry_after_max_seconds)
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

  # Base resolution order: explicit `:base_url` opt (tests) → configured
  # `:github_api_base` → `:api_base` (the key `Auth` reads — accepting it here
  # too means a single config key drives BOTH the token exchange and the REST
  # verbs, so an operator can't silently split them) → api.github.com.
  defp base_url(opts) do
    cfg = config()

    with :error <- opt_base(opts),
         :error <- cfg_base(cfg[:github_api_base]),
         :error <- cfg_base(cfg[:api_base]) do
      @default_api_base
    else
      url -> url
    end
  end

  defp opt_base(opts), do: cfg_base(Keyword.get(opts, :base_url))

  defp cfg_base(url) when is_binary(url) and url != "", do: String.trim_trailing(url, "/")
  defp cfg_base(_), do: :error

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
