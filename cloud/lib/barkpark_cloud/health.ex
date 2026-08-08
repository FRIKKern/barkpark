defmodule BarkparkCloud.Health do
  @moduledoc """
  Liveness for the control plane itself — mirrors the spirit of api/'s own
  health probe. The control plane's only hard dependency is
  its Postgres (where it stores metadata about many Barkpark instances), so
  health is "can I round-trip a query to my own DB?".

  Returns `{:ok, %{db: :up, ...}}` when the Repo answers `SELECT 1`, and
  `{:error, %{db: :down, ...}}` otherwise — never raises to the caller.

  Both arms also carry the serving identity from `serving/0` — the commit this
  BEAM is running and when the VM came up. A control plane whose DB is down
  must STILL be able to say which commit it is: that is precisely the state you
  most want a sha for.
  """

  alias BarkparkCloud.Repo

  @type result :: {:ok, map()} | {:error, map()}

  @doc """
  Probe the control plane's own liveness.

  Round-trips `SELECT 1` to the Repo. On success returns
  `{:ok, %{db: :up, checked_at: <utc_datetime>, git_sha: ..., serving_since: ...}}`.
  """
  @spec health() :: result()
  def health do
    Repo.query!("SELECT 1")
    {:ok, Map.merge(%{db: :up, checked_at: DateTime.utc_now()}, serving())}
  rescue
    error ->
      {:error,
       Map.merge(
         %{db: :down, checked_at: DateTime.utc_now(), reason: Exception.message(error)},
         serving()
       )}
  end

  @doc """
  What this BEAM is serving: the deployed commit and when the VM started.

  A CLOCK, not an alarm — it ALWAYS emits, so a future non-zero drift shows up
  as a change in a number already on screen. There is no threshold and no
  verdict arm here on purpose.

  * `git_sha` is read from `BARKPARK_GIT_SHA` **at call time**. ABSENT MEANS
    `nil` — never `"unknown"`, never `0`, never a raise. A box deployed before
    this reader existed (or one started without the passthrough) answers
    honestly rather than inventing a value. That is also why the compose line
    (`cloud/docker-compose.yml`, bare `- BARKPARK_GIT_SHA`) carries no default
    and why `deploy/cp-deploy.sh` exports it AFTER sourcing `cloud/.env` — a
    stale `.env` value must not be able to win.
  * `serving_since` is VM-derived (`:erlang.monotonic_time/0` against
    `:erlang.system_info(:start_time)`), never env-derived, so config cannot
    fake it. It answers "how long has this PROCESS been up", NOT "how long has
    this SHA been live" — in a container those coincide because the VM starts
    when the slot boots, but do not read it as a deploy timestamp.
  """
  @spec serving() :: %{git_sha: String.t() | nil, serving_since: DateTime.t()}
  def serving do
    %{git_sha: System.get_env("BARKPARK_GIT_SHA"), serving_since: vm_started_at()}
  end

  defp vm_started_at do
    uptime_ms =
      System.convert_time_unit(
        :erlang.monotonic_time() - :erlang.system_info(:start_time),
        :native,
        :millisecond
      )

    DateTime.utc_now() |> DateTime.add(-uptime_ms, :millisecond)
  end
end
