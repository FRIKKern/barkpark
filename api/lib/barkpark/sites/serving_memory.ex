defmodule Barkpark.Sites.ServingMemory do
  @moduledoc """
  How long this box has been serving THE CODE IT IS SERVING — a clock a restart
  cannot improve.

  ## The gauge this replaces

  The control plane's `serving_since` is derived from
  `:erlang.monotonic_time/0`: a PROCESS point sample. A bare `docker restart`
  that changes nothing about what is deployed makes that number look BETTER,
  which is the inverse of what an uptime gauge is for (charter D404). A metric a
  no-op can improve is not a metric; it is a reward for restarting.

  So the fact recorded here is not "when did this process start" but "when did
  this box FIRST see the sha it is currently serving". Restart the BEAM a
  hundred times: as long as the sha is unchanged, `first_seen_at` is not
  touched, and the clock keeps running from the deploy that actually changed
  something. Only a CHANGED sha writes a new `first_seen_at`.

  ## Why on disk, and why THIS disk (charter D382, measured)

  The record lives in `DeployRunner.run_state_dir()` —
  `/opt/barkpark/.bp-site-deploy-runs` on the fleet — because that dir is
  bounded by COUNT ONLY (`@default_max_terminal_records 10_000`;
  `prune_terminal_records/2` has no age term) and is NOT wiped: five
  independent disproofs of a wipe, and a ~17.7-day runway at today's record
  rate. journald, the obvious alternative, is 10 days AND volume-bounded at
  3.6 G under ~10k lines/h/slot — strictly worse for a fact whose whole value is
  that it outlives things. There is exactly ONE such dir on the box; blue/green
  slots do not fragment it.

  ## The three honest states

  `read/1` returns `serving_sha` and `serving_since`, and BOTH are `nil`
  together when the sha cannot be established (no `BARKPARK_GIT_SHA`, no
  reachable `git`). A `nil` sha renders as an explicit unknown — NEVER a zero,
  and never a fabricated `now`, either of which would be a fresh instance of the
  bug this module exists to remove.

  A record that cannot be WRITTEN (read-only dir, full disk) degrades in the
  safe direction: every read then reports `serving_since` as the current
  instant, so the clock reads ~0 forever. It understates. It never flatters.
  """

  require Logger

  alias Barkpark.Sites.DeployRunner

  @filename "serving-memory.json"

  # An abbreviated-or-full git object name, lowercase hex. Anything else — a
  # `git` error on stdout, an empty env var, a branch name someone exported by
  # mistake — is NOT a sha and is reported as unknown rather than recorded.
  @sha_re ~r/\A[0-9a-f]{7,40}\z/

  # Resolving the sha can cost a `git` fork; the answer cannot change without a
  # restart, so it is resolved at most once per BEAM.
  @sha_cache_key {__MODULE__, :current_sha}

  @type t :: %{serving_sha: String.t() | nil, serving_since: String.t() | nil}

  @doc """
  The current sha and the instant this box FIRST saw it, as ISO-8601 UTC.

  Options (tests and callers with their own truth):

    * `:dir` — where the record lives; defaults to `DeployRunner.run_state_dir()`
    * `:sha` — the sha to observe; defaults to `current_sha/0`. Passing `nil`
      explicitly asks for the unknown path.

  Reading is idempotent for an UNCHANGED sha: it does not write, and it does not
  move `serving_since` by so much as a byte. That is the entire contract.
  """
  @spec read(keyword()) :: t()
  def read(opts \\ []) do
    dir = Keyword.get(opts, :dir) || DeployRunner.run_state_dir()

    sha =
      if Keyword.has_key?(opts, :sha),
        do: normalize_sha(Keyword.get(opts, :sha)),
        else: current_sha()

    observe(dir, sha)
  end

  @doc """
  The sha this BEAM is running, or `nil` when it cannot be established.

  `BARKPARK_GIT_SHA` first (the deploy sets it and it costs nothing), then
  `git rev-parse HEAD` in the working dir. Resolved at most once per BEAM.
  """
  @spec current_sha() :: String.t() | nil
  def current_sha do
    case :persistent_term.get(@sha_cache_key, :unresolved) do
      :unresolved ->
        sha = resolve_sha()
        :persistent_term.put(@sha_cache_key, sha)
        sha

      cached ->
        cached
    end
  end

  # ── the record ───────────────────────────────────────────────────────────

  # No sha means no honest clock. Two explicit nulls, together, so a reader
  # cannot mistake "we do not know" for "just deployed".
  defp observe(_dir, nil), do: %{serving_sha: nil, serving_since: nil}

  defp observe(dir, sha) do
    case read_record(dir) do
      # THE POINT: same sha, same instant, untouched. A restart cannot move it.
      %{"sha" => ^sha, "first_seen_at" => first_seen_at} when is_binary(first_seen_at) ->
        %{serving_sha: sha, serving_since: first_seen_at}

      # A different sha (a real deploy), no record yet, or an unreadable one —
      # all three mean this box has no earlier honest sighting of THIS sha, so
      # now is the truth and now is what gets written.
      _no_usable_record ->
        first_seen_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        _ = write_record(dir, sha, first_seen_at)
        %{serving_sha: sha, serving_since: first_seen_at}
    end
  end

  # Reachability: `dir` is `DeployRunner.run_state_dir()` (application config or
  # a repo-root join) or a caller-chosen dir in tests. No request value reaches
  # it, and the basename is a module constant.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_record(dir) do
    with {:ok, body} <- File.read(path(dir)),
         {:ok, %{} = record} <- Jason.decode(body) do
      record
    else
      _unreadable -> nil
    end
  end

  # Written via a temp file + rename so a reader can never observe a half-written
  # record: the whole value of this file is that it is believed later.
  #
  # Reachability: same as `read_record/1` — no caller-supplied path component.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_record(dir, sha, first_seen_at) do
    body = Jason.encode!(%{sha: sha, first_seen_at: first_seen_at})
    target = path(dir)
    tmp = target <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, target) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)

        Logger.warning(
          "[serving-memory] could not record #{sha} in #{dir} (#{inspect(reason)}) — " <>
            "serving_since will read as now on every request until this is writable"
        )

        {:error, reason}
    end
  end

  defp path(dir), do: Path.join(dir, @filename)

  # ── the sha ──────────────────────────────────────────────────────────────

  defp resolve_sha do
    normalize_sha(System.get_env("BARKPARK_GIT_SHA")) || git_head_sha()
  end

  defp git_head_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> normalize_sha(out)
      _non_zero -> nil
    end
  rescue
    # `git` is not on PATH at all (a slim container). An unknown sha, honestly.
    ErlangError -> nil
  end

  defp normalize_sha(nil), do: nil

  defp normalize_sha(value) when is_binary(value) do
    candidate = value |> String.trim() |> String.downcase()
    if Regex.match?(@sha_re, candidate), do: candidate, else: nil
  end

  defp normalize_sha(_not_a_string), do: nil
end
