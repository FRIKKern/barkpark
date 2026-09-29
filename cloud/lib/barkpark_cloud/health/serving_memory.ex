defmodule BarkparkCloud.Health.ServingMemory do
  @moduledoc """
  How long the control plane has been serving THE CODE IT IS SERVING — a clock
  a restart cannot improve.

  ## The gauge this replaces (charter D404/D417)

  `/health`'s `serving_since` used to be `:erlang.monotonic_time/0` minus
  `:erlang.system_info(:start_time)`: a PROCESS point sample rendered as a
  wall-clock instant. A bare `docker restart` that changes nothing about what is
  deployed moves that number FORWARD, so any lag measured against it reads
  SMALLER — the inverse of what an uptime gauge is for. `Health`'s own moduledoc
  recorded the proof by run: two BEAMs running that body back to back reported
  6,334 ms -> 263 ms, a 24x "improvement" from deploying nothing. A metric a
  no-op can improve is not a metric; it is a reward for restarting.

  So the fact recorded here is not "when did this process start" but "when did
  this PLANE first see the sha it is currently serving".

  ## The semantics, stated so nobody has to infer them

    * **First boot on a sha** — no row for it, so now IS the truth: the row is
      written with `first_seen_at = now` and that instant is returned.
    * **Restart** — same sha, row already there, returned UNTOUCHED. The value
      is older than this BEAM, which is the whole point and is exactly what the
      tests assert.
    * **Redeploy** — a DIFFERENT sha is a different thing being served, so it
      gets its OWN row and its own `first_seen_at`. `serving_since` moving
      forward on a redeploy is not the bug: it is the measurement. The bug was
      it moving forward when NOTHING was deployed. The old sha's row is left
      alone, so a rollback to it resumes that sha's original clock.

  ## The three honest states

  `read/1` returns `serving_sha`, `serving_since` and a `serving_since_basis`
  sentence naming which of the three produced them:

    * `:durable` — a record was read or written. Both values are set.
    * `:unknown_sha` — `BARKPARK_GIT_SHA` is absent, empty, or is not a git
      object name (a branch name someone exported by mistake). BOTH read `nil`,
      TOGETHER. A `serving_since` without a sha would be a fabricated deploy
      timestamp, which is a fresh instance of the bug this module removes.
    * `:unavailable` — the plane's Postgres could not be reached, so the record
      could not be read or written. `serving_since` reads `nil`. It does NOT
      fall back to the boot instant: falling back would silently restore the
      defect in the one state where nobody would notice.

  It understates. It never flatters.

  ## The per-BEAM cache is not a second source of truth

  `/health` is the load-balancer probe, so it is hit constantly, and a sha's
  `first_seen_at` cannot change while the BEAM is up. The first successful read
  is therefore memoised in `:persistent_term`, keyed BY SHA, which also means a
  later Postgres blip cannot make a `serving_since` this plane has already
  published disappear. A NEW BEAM starts with an empty cache — which is
  precisely the restart this module is built to survive, and is how the tests
  simulate one (`forget/0`).
  """

  use Ecto.Schema

  import Ecto.Query

  require Logger

  alias BarkparkCloud.Repo

  @env "BARKPARK_GIT_SHA"

  # An abbreviated-or-full git object name, lowercase hex. Anything else — a
  # `git` error captured onto stdout, an empty env var, a branch name someone
  # exported by mistake — is NOT a sha and is reported as unknown rather than
  # recorded. Mirrors api/'s `Barkpark.Sites.ServingMemory`, widened to 64 so a
  # sha-256 object name is not silently refused.
  @sha_re ~r/\A[0-9a-f]{7,64}\z/

  @primary_key {:sha, :string, autogenerate: false}
  schema "serving_memories" do
    field(:first_seen_at, :utc_datetime_usec)
  end

  @basis %{
    durable:
      "durable: the instant this control plane FIRST observed serving_sha serving, kept in its " <>
        "own Postgres and keyed by that sha. A restart that deploys nothing does NOT move it; " <>
        "only a CHANGED serving_sha starts a new clock, and a rollback resumes the old sha's " <>
        "original one. Safe to diff against a box's serving_since — same meaning, same name.",
    unknown_sha:
      "unknown: BARKPARK_GIT_SHA is absent, empty, or is not a git object name, so this plane " <>
        "cannot say WHICH commit it is serving — and a serving_since with no sha beside it " <>
        "would be a deploy timestamp nobody measured. serving_sha and serving_since read null " <>
        "TOGETHER. Use process_since if you want this VM's uptime.",
    unavailable:
      "unavailable: the durable serving record could not be read or written (this plane's " <>
        "Postgres is unreachable), so serving_since reads null rather than falling back to this " <>
        "BEAM's boot instant — that fallback is a gauge a bare restart IMPROVES. serving_sha " <>
        "still says what is deployed; use process_since if you want this VM's uptime."
  }

  @type t :: %{
          serving_sha: String.t() | nil,
          serving_since: DateTime.t() | nil,
          serving_since_basis: String.t()
        }

  @doc """
  The current sha and the instant this plane FIRST saw it serving.

  Options (tests and callers with their own truth):

    * `:sha` — the sha to observe; defaults to `#{@env}`. Passing `nil`
      explicitly asks for the unknown path.

  Reading is idempotent for an UNCHANGED sha: after the first sighting it does
  not write, and it does not move `serving_since` by so much as a microsecond.
  That is the entire contract.
  """
  @spec read(keyword()) :: t()
  def read(opts \\ []) do
    raw = if Keyword.has_key?(opts, :sha), do: Keyword.get(opts, :sha), else: System.get_env(@env)
    observe(normalize_sha(raw))
  end

  @doc """
  Drop this BEAM's memoised sightings.

  What a real restart does for free. Tests call it to stand a NEW BEAM up over
  the SAME durable record, which is the only way to prove the record — and not
  the process clock — is what `serving_since` comes from.
  """
  @spec forget() :: :ok
  def forget do
    for {{mod, :first_seen_at, _sha} = key, _value} <- :persistent_term.get(),
        mod == __MODULE__,
        do: :persistent_term.erase(key)

    :ok
  end

  # ── the three states ──────────────────────────────────────────────────────

  defp observe(nil),
    do: %{serving_sha: nil, serving_since: nil, serving_since_basis: @basis.unknown_sha}

  defp observe(sha) do
    case cached(sha) do
      %DateTime{} = first_seen_at ->
        durable(sha, first_seen_at)

      nil ->
        case durable_first_seen_at(sha) do
          %DateTime{} = first_seen_at ->
            cache(sha, first_seen_at)
            durable(sha, first_seen_at)

          :unavailable ->
            %{serving_sha: sha, serving_since: nil, serving_since_basis: @basis.unavailable}
        end
    end
  end

  defp durable(sha, first_seen_at),
    do: %{serving_sha: sha, serving_since: first_seen_at, serving_since_basis: @basis.durable}

  # ── the record ────────────────────────────────────────────────────────────

  # Insert-then-read-back, never insert-and-believe-what-I-inserted: two slots
  # racing at a flip must agree, and ON CONFLICT DO NOTHING means the loser's
  # `now` is discarded. The read-back is what tells the loser the EARLIER
  # instant it must publish.
  defp durable_first_seen_at(sha) do
    _ =
      Repo.insert_all(
        __MODULE__,
        [%{sha: sha, first_seen_at: DateTime.utc_now()}],
        on_conflict: :nothing,
        conflict_target: :sha
      )

    case Repo.one(from(m in __MODULE__, where: m.sha == ^sha, select: m.first_seen_at)) do
      %DateTime{} = first_seen_at -> first_seen_at
      nil -> :unavailable
    end
  rescue
    error ->
      # /health is UNAUTHENTICATED and must never raise to the caller: a plane
      # whose DB is down still has to be able to say which commit it is.
      Logger.warning(
        "[serving-memory] could not record #{sha} (#{Exception.message(error)}) — " <>
          "serving_since will read as null until Postgres is reachable"
      )

      :unavailable
  catch
    # A checkout against a dead shared sandbox owner EXITS rather than raising,
    # and `rescue` does not catch that (the same trap health_test.exs's error-arm
    # module documents). The wire must not care which one happened.
    :exit, _reason ->
      :unavailable
  end

  # ── the per-BEAM memo ─────────────────────────────────────────────────────

  defp cached(sha), do: :persistent_term.get(key(sha), nil)
  defp cache(sha, first_seen_at), do: :persistent_term.put(key(sha), first_seen_at)
  defp key(sha), do: {__MODULE__, :first_seen_at, sha}

  # ── the sha ───────────────────────────────────────────────────────────────

  defp normalize_sha(value) when is_binary(value) do
    candidate = value |> String.trim() |> String.downcase()
    if Regex.match?(@sha_re, candidate), do: candidate, else: nil
  end

  defp normalize_sha(_not_a_string), do: nil
end
