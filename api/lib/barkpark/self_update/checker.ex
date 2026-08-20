defmodule Barkpark.SelfUpdate.Checker do
  @moduledoc """
  Timer GenServer that periodically asks the upstream source (via the
  configured `Barkpark.SelfUpdate.Client`) for the latest release and
  caches a status map (see `Barkpark.SelfUpdate.status/0` for the shape).

  Same `Process.send_after` idiom as `Barkpark.Sync.Worker`: first check
  after `initial_delay_ms` (so boot never waits on the network), then one
  per `check_interval_ms`. Read-only — it only OBSERVES upstream; applying
  an update is a separate, operator-driven concern.

  Comparison rule (versioning contract, 2026-07-02): releases compare as
  integer 3-tuples of `A.B.C`; `:behind` iff latest > running. The running
  version's fourth segment (commits since tag) never matters. A digest
  fetch failure never blocks the `:behind` signal — it degrades to `[]`.

  Fail-closed: `run_check/0` rescues everything, a client error or an
  unknown running release yields `state: :unknown` with `error` set, and
  the process is only ever started when `SelfUpdate.enabled?/0` is true
  (spliced in `Barkpark.Application` like `sync_children`).
  """

  use GenServer

  alias Barkpark.BuildInfo
  alias Barkpark.SelfUpdate

  @default_initial_delay_ms 10_000
  @default_check_interval_ms 3_600_000

  # The most SEQUENTIAL client HTTP calls run_check/0 can make on any single
  # path — the fork-mode :behind path, which fires all four in order:
  #   1. client.latest_release(repo)       — run_check/0
  #   2. client.latest_release(canonical)  — fork_advice/4 (when repo != canonical)
  #   3. fetch_notes -> client.release_notes(repo, tag)
  #   4. fetch_digest -> client.digest(repo, from_tag, to_tag)
  # Keep this constant in lockstep with those four call sites below: adding a
  # fifth sequential request MUST bump it, or the derived :check_now call
  # budget (SelfUpdate.check_now_timeout_ms/0) stops covering the real worst
  # case — the check-timeout test in checker_test.exs fails until it is raised.
  @max_sequential_http_requests 4

  @doc """
  Worst-case wall-clock budget (ms) for the sequential HTTP calls run_check/0
  makes: `@max_sequential_http_requests` × the client's per-request receive
  timeout, read from the client module so the 10s literal lives in exactly
  one place (`Barkpark.SelfUpdate.Client.GitHub.receive_timeout_ms/0`). The
  `:check_now` GenServer.call timeout is derived to cover this — see
  `Barkpark.SelfUpdate.check_now_timeout_ms/0`.
  """
  @spec worst_case_http_budget_ms() :: pos_integer()
  def worst_case_http_budget_ms do
    @max_sequential_http_requests * Barkpark.SelfUpdate.Client.GitHub.receive_timeout_ms()
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    Process.send_after(self(), :check, delay(opts, :initial_delay_ms, @default_initial_delay_ms))
    {:ok, %{status: SelfUpdate.base_status(:unknown), opts: opts}}
  end

  @impl true
  def handle_info(:check, state) do
    # The HTTP check runs in a throwaway task so this GenServer stays
    # instantly callable — :status backs every admin Studio render, and a
    # slow/blackholed api.github.com must never queue those calls behind
    # 10s+ of network. The task posts the result back as {:check_result, _};
    # if it dies, the result simply never arrives and the next tick retries.
    parent = self()
    Task.start(fn -> send(parent, {:check_result, run_check()}) end)

    Process.send_after(
      self(),
      :check,
      delay(state.opts, :check_interval_ms, @default_check_interval_ms)
    )

    {:noreply, state}
  end

  def handle_info({:check_result, status}, state) do
    {:noreply, %{state | status: status}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:check_now, _from, state) do
    # Synchronous on-demand check; the periodic timer keeps its own cadence.
    status = run_check()
    {:reply, status, %{state | status: status}}
  end

  defp run_check do
    cfg = SelfUpdate.config()
    client = Keyword.get(cfg, :client, Barkpark.SelfUpdate.Client.GitHub)
    repo = Keyword.get(cfg, :repo, "FRIKKern/barkpark")
    running_release = BuildInfo.release()
    base = %{SelfUpdate.base_status(:unknown) | checked_at: DateTime.utc_now()}

    with {:running, {:ok, running}} <- {:running, parse_release(running_release)},
         {:latest, {:ok, %{release: latest_release, tag: latest_tag}}} <-
           {:latest, client.latest_release(repo)},
         {:parsed, {:ok, latest}} <- {:parsed, parse_release(latest_release)} do
      base = %{base | canonical_release: fork_advice(cfg, client, repo, latest)}

      if latest > running do
        notes = fetch_notes(client, repo, latest_tag)

        %{
          base
          | state: :behind,
            latest_release: latest_release,
            digest: fetch_digest(client, repo, "v" <> running_release, latest_tag),
            notes_body: notes.body,
            notes_url: notes.url
        }
      else
        %{base | state: :current, latest_release: latest_release}
      end
    else
      {:running, :error} ->
        %{base | error: "running release is #{inspect(running_release)} (no vA.B.C build tag)"}

      {:latest, {:error, reason}} ->
        %{base | error: "upstream check failed: #{inspect(reason)}"}

      {:parsed, :error} ->
        %{base | error: "upstream returned an unparsable release"}
    end
  rescue
    # Never let a checker bug crash the instance — degrade to :unknown.
    error ->
      %{
        SelfUpdate.base_status(:unknown)
        | checked_at: DateTime.utc_now(),
          error: "self-update check crashed: #{Exception.message(error)}"
      }
  catch
    # rescue only sees exceptions; a throw or a linked exit (e.g. from deep
    # inside the HTTP stack) must degrade the same way, never crash.
    kind, reason ->
      %{
        SelfUpdate.base_status(:unknown)
        | checked_at: DateTime.utc_now(),
          error: "self-update check crashed: #{inspect({kind, reason})}"
      }
  end

  # Fork advice (isu-7): when the configured repo is a FORK (differs from the
  # canonical open-source repo), also ask the canonical repo for its newest
  # release. Returns that release ONLY when it exceeds the fork's — non-nil
  # means exactly "your fork is behind upstream Barkpark". Advice-only and
  # fully tolerant: any canonical-side failure is nil, never an error state
  # (the actionable fork comparison above is what matters).
  defp fork_advice(cfg, client, repo, fork_latest) do
    canonical = Keyword.get(cfg, :canonical_repo, "FRIKKern/barkpark")

    with true <- repo != canonical,
         {:ok, %{release: canonical_release}} <- client.latest_release(canonical),
         {:ok, parsed} <- parse_release(canonical_release),
         true <- parsed > fork_latest do
      canonical_release
    else
      _ -> nil
    end
  end

  # Digest failures are tolerated: knowing THAT we are behind matters more
  # than knowing what changed.
  defp fetch_digest(client, repo, from_tag, to_tag) do
    case client.digest(repo, from_tag, to_tag) do
      {:ok, lines} when is_list(lines) -> lines
      _error -> []
    end
  end

  # Curated notes (isu-w2) are best-effort, exactly like the digest: any
  # failure — or a client that predates the callback — degrades to "no
  # notes", and the Studio bar falls back to the commit digest.
  defp fetch_notes(client, repo, tag) do
    with true <- function_exported?(client, :release_notes, 2),
         {:ok, %{body: body, url: url}} <- client.release_notes(repo, tag) do
      %{body: body, url: url}
    else
      _ -> %{body: nil, url: nil}
    end
  end

  defp parse_release(release) when is_binary(release) do
    case Regex.run(~r/^(\d+)\.(\d+)\.(\d+)$/, release) do
      [_, a, b, c] ->
        {:ok, {String.to_integer(a), String.to_integer(b), String.to_integer(c)}}

      _ ->
        :error
    end
  end

  defp parse_release(_release), do: :error

  # start_link opts win (tests push the timers out of the window), else the
  # SelfUpdate config, else the module default.
  defp delay(opts, key, default) do
    Keyword.get(opts, key) || Keyword.get(SelfUpdate.config(), key, default)
  end
end
