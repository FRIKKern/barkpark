defmodule Barkpark.SelfUpdate do
  @moduledoc """
  Instance self-update — facade over the update Checker.

  Barkpark instances can periodically ask their upstream source (a GitHub
  repo, by default the canonical one) whether a newer RELEASE is available.
  A release is the first three segments of the running version (see
  `Barkpark.BuildInfo` — version `A.B.C.D` belongs to release `A.B.C`,
  carried by git tag `vA.B.C`); "update available" means the latest
  upstream release exceeds the running release as an integer 3-tuple.
  The trailing `.D` (commits since tag) never matters.

  DORMANT by default: config.exs ships `enabled: false`, runtime.exs flips
  it on in prod unless `BARKPARK_SELF_UPDATE_CHECK=off`. When disabled the
  `Barkpark.SelfUpdate.Checker` GenServer is simply absent from the
  supervision tree and `status/0` returns a `state: :disabled` map.

  Fail-closed contract: `status/0` and `check_now/0` NEVER raise — a dead
  or missing Checker degrades to a `:disabled`/`:unknown` status map. This
  feature must never crash an instance.
  """

  alias Barkpark.BuildInfo
  alias Barkpark.SelfUpdate.Checker

  @doc """
  Whether the self-update checker is enabled (config.exs default OFF;
  runtime.exs flips it on in prod). Gates the Checker child in
  `Barkpark.Application`.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Keyword.get(config(), :enabled, false) == true
  end

  @doc """
  The `Barkpark.SelfUpdate` config keyword list (repo, channel, intervals,
  client module — see config.exs for the defaults).
  """
  @spec config() :: keyword()
  def config do
    Application.get_env(:barkpark, __MODULE__, [])
  end

  @doc """
  The last known update status. Never raises: when the Checker process is
  not running (feature disabled) this returns a `state: :disabled` map; a
  Checker that dies mid-call degrades to `state: :unknown`.
  """
  @spec status() :: map()
  def status, do: call_checker(:status)

  @doc """
  Run an upstream check synchronously and return the fresh status map.
  Same never-raises contract as `status/0`.
  """
  @spec check_now() :: map()
  def check_now, do: call_checker(:check_now)

  defp call_checker(msg) do
    case Process.whereis(Checker) do
      nil ->
        base_status(:disabled)

      pid ->
        try do
          GenServer.call(pid, msg, call_timeout(msg))
        catch
          # Checker died between whereis and call (or timed out) — degrade,
          # never propagate the exit to the caller.
          :exit, _reason -> base_status(:unknown)
        end
    end
  end

  # :check_now runs up to two 10s-budget HTTP requests inline — the call
  # timeout must cover the client's own worst case or a merely-slow upstream
  # masquerades as :unknown while the fresh result is thrown away.
  defp call_timeout(:check_now), do: 30_000
  defp call_timeout(_msg), do: 5_000

  # Baseline status map — the shape every status/0 / check_now/0 result has.
  # Shared with the Checker so the disabled/unknown fallbacks and the real
  # check results can never drift apart.
  #
  # canonical_release (isu-7, fork mode only): set ONLY when the configured
  # repo is a fork AND the canonical open-source repo has a newer release
  # than the fork's newest — i.e. non-nil means exactly "advise the operator
  # their fork is behind upstream Barkpark". Renderers need no comparison.
  @doc false
  @spec base_status(:disabled | :unknown | :current | :behind) :: map()
  def base_status(state) do
    %{
      state: state,
      running_version: BuildInfo.version(),
      running_release: BuildInfo.release(),
      latest_release: nil,
      canonical_release: nil,
      digest: [],
      checked_at: nil,
      error: nil
    }
  end
end
