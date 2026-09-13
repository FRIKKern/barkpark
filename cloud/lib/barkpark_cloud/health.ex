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

  `serving_since` is now DURABLE here too: `BarkparkCloud.Health.ServingMemory`
  keeps one row per sha in the plane's own Postgres, so a restart that deploys
  nothing cannot move it. It IS comparable to a box's `serving_since` — same
  meaning, same name, both surviving a restart. The basis string beside it says
  which of the store's three states produced the value.
  """

  require Logger

  alias BarkparkCloud.Health.ServingMemory
  alias BarkparkCloud.Repo

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
  * `serving_since` is read from `ServingMemory`, NOT from this VM. It is the
    instant this plane first observed `serving_sha` serving, kept in Postgres
    and keyed by that sha, and it is normally OLDER than `process_since` —
    which is the whole point. `nil` is a legal answer (no sha, or the store is
    unreachable) and `serving_since_basis` says which.

  D417 CLOSED — it used to be the process clock, and this is the paragraph that
  used to warn you about it. Proved by run, not by reading: two BEAMs running
  the OLD body back to back reported lag 6,334 ms -> 263 ms, with
  `serving_since` moving FORWARD 6.4 s — a 24x "improvement" from changing
  nothing about what is deployed. That is fixed: the value now comes from a
  durable per-sha record, so a bare restart cannot move it and the plane's
  `serving_since` IS comparable to the box's. `process_since` is still here,
  still boot-local, and is still what you want when you mean uptime.
  """
  @spec serving() :: %{
          git_sha: String.t() | nil,
          serving_sha: String.t() | nil,
          serving_since: DateTime.t() | nil,
          process_since: DateTime.t(),
          serving_since_basis: String.t()
        }
  def serving do
    # The RAW env value is what `git_sha`/`serving_sha` publish — that reader's
    # contract is "absent means nil, present means exactly what you set", and it
    # is asserted against three injected values. ServingMemory validates the
    # same string for its own key and answers `nil` for anything that is not a
    # git object name, so a branch name exported by mistake shows up as a sha
    # you can see and a serving_since that declines to guess.
    sha = System.get_env("BARKPARK_GIT_SHA")
    memory = ServingMemory.read(sha: sha)

    %{
      git_sha: sha,
      serving_sha: sha,
      serving_since: memory.serving_since,
      process_since: vm_started_at(),
      serving_since_basis: memory.serving_since_basis
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
