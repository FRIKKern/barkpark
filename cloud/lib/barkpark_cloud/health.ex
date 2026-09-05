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

  ## Clock vocabulary (charter D417)

  One vocabulary across the box and the plane, so a human diffing one against
  the other compares like with like:

  * `serving_sha` — the commit whose code is EXECUTING. Here it is an alias of
    the existing `git_sha`, read from the SAME source in the same call.
  * `serving_since` — RESERVED, on every surface, for the instant this sha was
    FIRST OBSERVED SERVING. Durable; a no-op restart must never move it.
  * `process_since` — when THIS BEAM started. Moves on every restart.

  The plane does not have a durable serving record yet, so `serving_since`
  here is still the process clock (see `serving/0`) and is emitted with an
  explicit basis string saying so. Do NOT diff it against the box's
  `serving_since` until it is durable.
  """

  require Logger

  alias BarkparkCloud.Repo

  # The honest label on a gauge a `docker restart` can IMPROVE. Emitted next to
  # `serving_since` so nobody has to read this module to know what the number
  # is. Its wording is asserted over the wire in health_test.exs — the test is
  # the guard that this label cannot be quietly dropped.
  @serving_since_basis "process-derived: this is when THIS BEAM started, not when this sha was " <>
                         "first observed serving. A bare restart that deploys nothing moves it " <>
                         "FORWARD, which makes any lag measured against it read SMALLER. Use " <>
                         "serving_sha to decide what is deployed; do not read this as a deploy " <>
                         "timestamp and do not compare it to the box's serving_since."

  @type result :: {:ok, map()} | {:error, map()}

  @doc """
  Probe the control plane's own liveness.

  Round-trips `SELECT 1` to the Repo. On success returns
  `{:ok, %{db: :up, checked_at: <utc_datetime>, git_sha: ..., serving_sha: ...,
  serving_since: ..., process_since: ..., serving_since_basis: ...}}`.
  """
  @spec health() :: result()
  def health do
    Repo.query!("SELECT 1")
    {:ok, Map.merge(%{db: :up, checked_at: DateTime.utc_now()}, serving())}
  rescue
    error ->
      # /health is UNAUTHENTICATED (the load-balancer probe). The raw exception
      # text names hosts, users and pool internals, so it goes to the server log
      # only; the wire carries one fixed category string (arpss-classa ruling).
      Logger.warning("cloud health probe: SELECT 1 failed: " <> Exception.message(error))

      {:error,
       Map.merge(
         %{db: :down, checked_at: DateTime.utc_now(), reason: "database_unavailable"},
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
  * `serving_sha` is the SAME value as `git_sha`, read in the same call from
    the same source — the D417 name for "the commit whose code is executing".
    `git_sha` is NOT renamed away: `/health` is anonymous and already live, so
    a bare rename would break an unknown live reader. Both keys, one read.
  * `process_since` is VM-derived (`:erlang.monotonic_time/0` against
    `:erlang.system_info(:start_time)`), never env-derived, so config cannot
    fake it. It answers "how long has this PROCESS been up", NOT "how long has
    this SHA been live".
  * `serving_since` currently carries that SAME process-derived instant, which
    is why `serving_since_basis` ships beside it saying so in plain words.

  D417 PLACEHOLDER — READ THIS BEFORE COMPARING SURFACES. On this surface
  `serving_since` is a PLACEHOLDER for a durable first-observed-serving record
  that the control plane does not keep yet. Proved by run, not by reading: two
  BEAMs running this exact body back to back reported lag 6,334 ms -> 263 ms,
  with `serving_since` moving FORWARD 6.4 s — a 24x "improvement" from changing
  nothing about what is deployed. The box (`ServingMemory`) uses this name for
  the DURABLE instant, and renders an ISO-8601 string where this renders a
  `%DateTime{}`. Do NOT compare the plane's `serving_since` to the box's until
  this one is durable; compare `serving_sha` instead, and use `process_since`
  when you mean uptime. Making it durable is a separate slice.
  """
  @spec serving() :: %{
          git_sha: String.t() | nil,
          serving_sha: String.t() | nil,
          serving_since: DateTime.t(),
          process_since: DateTime.t(),
          serving_since_basis: String.t()
        }
  def serving do
    sha = System.get_env("BARKPARK_GIT_SHA")
    process_since = vm_started_at()

    %{
      git_sha: sha,
      serving_sha: sha,
      serving_since: process_since,
      process_since: process_since,
      serving_since_basis: @serving_since_basis
    }
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
