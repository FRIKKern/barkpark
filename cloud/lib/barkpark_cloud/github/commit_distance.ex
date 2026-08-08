defmodule BarkparkCloud.GitHub.CommitDistance do
  @moduledoc """
  deploy-reliability W21 (S2) — how far behind `main` is the commit a box is
  actually serving?

  ONE unauthenticated call answers both halves:

      GET https://api.github.com/repos/<repo>/compare/<served_sha>...main
      → %{"status" => "identical" | "ahead" | "behind" | "diverged",
          "ahead_by" => n, "behind_by" => n}

  The HEAD of the comparison is the BRANCH NAME, not a sha we resolved
  ourselves: GitHub resolves the tip server-side in the same round trip, so the
  answer cannot inherit the staleness of a tip we cached. `base` is the served
  commit, so the API's own answer satisfies the ancestry rule with no local git
  graph.

  ## The verdict

  `verdict/2` returns `%{ancestry: rung, distance: integer | nil}`:

  | compare `status` | ancestry        | distance   | means                                        |
  |------------------|-----------------|------------|----------------------------------------------|
  | `identical`      | `"current"`     | `0`        | serving exactly `main`                       |
  | `ahead`          | `"behind"`      | `ahead_by` | N commits of `main` missing, provably an ancestor |
  | `behind`         | `"ahead_of_main"` | `0`      | serves commits NOT on `main` (missing none)  |
  | `diverged`       | `"diverged"`    | `ahead_by` | both: missing N *and* carrying unknown code  |

  NOTE THE ARGUMENT ORDER, because the sibling leg of this wave uses the other
  one. `compare/<base>...<head>` reports HEAD relative to BASE. Here base is the
  SERVED commit and head is `main`, so the API's `"ahead"` means *main* is ahead
  — i.e. the box is BEHIND, which is why the rung is named for the box and not
  for the API. The deploy-workflow assertion (`.github/workflows/deploy.yml`,
  dr-w21-s1) passes them the other way round — base = the run's sha, head = the
  served sha — so there `"ahead"` means the box is fine. Both are correct; only
  one of them can be read without checking which side is base.

  `distance` has ONE meaning in every rung — **commits of `main` the box does
  not have** — so the column is a single unit and never mixes "behind by" with
  "ahead by". The loudness of `ahead_of_main` / `diverged` lives in `ancestry`,
  which is why the rung exists at all: those rows have no reporter today.

  ## The `unknown` rung is fail-CLOSED and the whole point

  A NULL/empty served sha, an HTTP 404 (GitHub's answer for an unknown or
  garbage sha), a 403 rate-limit refusal, any other non-200, a transport error,
  an undecodable body, an unrecognised status, and an unconfigured client ALL
  return `%{ancestry: "unknown", distance: nil}`. **Never 0.** A zero would
  render as the freshest row in the fleet on exactly the box that is lying
  hardest (muscle-1: agent offline, `git_commit: ""`), which is the unearned
  green this slice exists to kill. Callers must render `nil` as UNMETERED and
  sort it to the top, not as "0 behind".

  This module never raises: `verdict/2` is total over its input.

  ## Why not `BarkparkCloud.GitHub.Real`

  That client is App-JWT credentialed. `config.exs` defaults
  `client: BarkparkCloud.GitHub.Fake` and `runtime.exs` swaps in `Real` only
  when `GITHUB_APP_ID` + `GITHUB_APP_PRIVATE_KEY` are set — a human gate its own
  moduledoc says has never fired, so routing through it would make this verdict
  permanently fake. The repo is PUBLIC, so no credential is needed. The prior
  art is `api/lib/barkpark/self_update/client/github.ex`, which already calls
  this exact unauthenticated endpoint and rules the anonymous budget sufficient
  for an hourly check.

  ## Transport

  `BarkparkCloud.Billing.HttpClient.request/1` (`:httpc`, verified TLS against
  the OS trust store, bounded timeouts, no autoredirect) — the same seam Stripe,
  Hetzner and the instance proxy already ride. It is INJECTED: pass
  `http_client:` (a 1-arity fun or a module exporting `request/1`) or set

      config :barkpark_cloud, BarkparkCloud.GitHub.CommitDistance,
        http_client: &MyFake.request/1, repo: "owner/name", branch: "main"

  The DEFAULT is the real transport, so the hourly sweep works with no config
  change; tests inject and never touch the network.

  ## Honest limits

    * The anonymous budget is **60 requests/hour per SOURCE IP**, shared with
      anything else calling GitHub from that address. A 403 is therefore a
      NORMAL outcome, and it lands `unknown`/`nil` rather than a fabricated
      distance. It is classified by STATUS ALONE: the injected transport
      (`Billing.HttpClient.request/1`) returns only `%{status, body}` and
      DISCARDS response headers, so `x-ratelimit-remaining` and
      `x-ratelimit-reset` are not available here and a budget refusal is
      indistinguishable from any other 403. The safety half of the rule holds
      (a refusal never becomes a 0); the diagnostic half does not, and widening
      the shared transport to carry headers is deliberately not this slice's
      job.
    * EGRESS from the control-plane container to `api.github.com` is UNPROVEN by
      any test — the first real hourly sweep is the proof.
    * This changes NO autoupdate behaviour: `update_state` and every gate that
      reads it are untouched, and nothing consumes these columns yet. The
      distance is not on any human surface — that is dr-w21-s4, round 2.
  """

  require Logger

  @api_base "https://api.github.com"
  @default_repo "FRIKKern/barkpark"
  @default_branch "main"

  @headers [
    {"user-agent", "barkpark-cloud-commit-distance"},
    {"accept", "application/vnd.github+json"}
  ]

  @unknown %{ancestry: "unknown", distance: nil}

  @type verdict :: %{ancestry: String.t(), distance: non_neg_integer() | nil}

  @doc """
  The rungs this module can return, in freshness order. `"unknown"` is first on
  purpose: an unmeasured row is the LOUDEST, not the freshest.
  """
  @spec ancestries() :: [String.t()]
  def ancestries, do: ~w(unknown current behind ahead_of_main diverged)

  @doc """
  Grade one served commit against the tip of `main`.

  Returns `%{ancestry: rung, distance: integer | nil}`. Total — every failure
  mode returns the `"unknown"` rung with `distance: nil`, and this never raises.

  Options: `:http_client` (1-arity fun or a module exporting `request/1`),
  `:repo` (`"owner/name"`), `:branch`.
  """
  @spec verdict(String.t() | nil, keyword()) :: verdict()
  def verdict(served_sha, opts \\ [])

  # The NULL rung, taken before any HTTP: muscle-1's git_commit is "" because
  # its agent is offline. Unmeasured, never 0.
  def verdict(sha, _opts) when not is_binary(sha), do: @unknown
  def verdict("", _opts), do: @unknown

  def verdict(served_sha, opts) do
    served_sha = String.trim(served_sha)

    if served_sha == "" do
      @unknown
    else
      opts
      |> compare(served_sha)
      |> to_verdict(served_sha)
    end
  end

  # ── HTTP ──

  defp compare(opts, served_sha) do
    repo = config(opts, :repo, @default_repo)
    branch = config(opts, :branch, @default_branch)
    url = "#{@api_base}/repos/#{repo}/compare/#{served_sha}...#{branch}"

    case call(opts, %{method: :get, url: url, headers: @headers, body: ""}) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{} = decoded} -> {:ok, decoded}
          _ -> {:error, :undecodable_body}
        end

      # GitHub's answer for a sha it has never seen — a garbage, truncated or
      # force-pushed-away commit FAILS CLOSED here rather than reading as 0.
      {:ok, %{status: 404}} ->
        {:error, :unknown_commit}

      # The shared 60/h anonymous budget, exhausted. A refusal, not a distance.
      {:ok, %{status: 403}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_client_result, other}}
    end
  end

  # A client that raises is a transport failure like any other — this module's
  # contract is that it never raises, and the caller's sweep must not care.
  defp call(opts, request) do
    case client(opts) do
      nil ->
        {:error, :http_client_not_configured}

      fun when is_function(fun, 1) ->
        fun.(request)

      mod when is_atom(mod) ->
        mod.request(request)
    end
  rescue
    e -> {:error, {:client_raised, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:client_threw, kind, reason}}
  end

  # ── Verdict mapping ──

  defp to_verdict({:ok, %{"status" => "identical"}}, _sha),
    do: %{ancestry: "current", distance: 0}

  defp to_verdict({:ok, %{"status" => "ahead", "ahead_by" => n}}, _sha) when is_integer(n),
    do: %{ancestry: "behind", distance: n}

  # `main` is behind the served commit: the box serves commits that are not on
  # main at all. It is missing NO main commits (distance 0) — the problem this
  # row has is the ancestry, and that is where it is said.
  defp to_verdict({:ok, %{"status" => "behind"}}, _sha),
    do: %{ancestry: "ahead_of_main", distance: 0}

  defp to_verdict({:ok, %{"status" => "diverged", "ahead_by" => n}}, _sha) when is_integer(n),
    do: %{ancestry: "diverged", distance: n}

  defp to_verdict({:ok, _body}, sha) do
    Logger.warning("CommitDistance: unusable compare body for #{short(sha)}")
    @unknown
  end

  defp to_verdict({:error, reason}, sha) do
    Logger.info("CommitDistance: #{short(sha)} unmeasured — #{inspect(reason)}")
    @unknown
  end

  # ── Config ──

  defp client(opts), do: config(opts, :http_client, &BarkparkCloud.Billing.HttpClient.request/1)

  defp config(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        :barkpark_cloud
        |> Application.get_env(__MODULE__, [])
        |> Keyword.get(key, default)
    end
  end

  defp short(sha), do: String.slice(sha, 0, 9)
end
