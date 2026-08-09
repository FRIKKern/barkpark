defmodule BarkparkCloud.Repo.Migrations.BackfillAbandonmentDeferralStructure do
  @moduledoc """
  deploy-reliability W32 (S5): THE SEVEN PRODUCTION ABANDONMENTS GET THEIR
  STRUCTURED COLUMNS — BEFORE THE PREDICATE SWAP TURNS THEM INTO A PERMANENT ZERO.

  ## The ordering is the whole point

  `dr-w28-rv-abandonment-predicate-replaces-the-prose-regex` is open: it swaps the
  live prose-anchored abandonment classifier (`failure_reason LIKE '%rebuilds in a
  row for this site%'`) for a `deferral_cause`-based one. Every abandonment
  already on disk carries NULL in all three chain columns, so landing that swap
  FIRST silently drops all of them out of the cohort and hands the epic's
  wind-down a zero it manufactured itself. THIS MIGRATION MERGES FIRST.

  ## What is actually on disk (measured on cloud-db-1, table `public.deployments`)

  The lapse-to-terminal arm has fired SEVEN times, not the four charter D134
  records: 1x `already_running` at 6 rounds (2026-08-05 22:57:53.830161) and 6x
  `box_at_capacity` at 12 rounds (2026-08-07 01:20:14 → 03:41:33) across five
  sites. Every one is `status = 'failed'` with all three chain columns NULL,
  because `fail/2` wrote status / failure_reason / detail and nothing else until
  #11209.

  The structured predicate `deferral_depth = deferral_bound` therefore matches
  ZERO of 32,953 rows — and it is UNSATISFIABLE BY CONSTRUCTION on `deferred`
  rows: `Sites.Deploy.defer/3` takes the abandonment arm at
  `prior >= max_consecutive_deferrals(cause) - 1`, so the bound-th round is
  written `failed` and the deepest a DEFERRED row can carry is bound-1 (the
  corpus maxes at depth 9 against a bound of 12). Only an abandonment can satisfy
  it, and until this runs there is not one abandonment that can.

  The W28 writer (`deploy.ex:1294`) landed 6h31m01s AFTER the last abandonment —
  first stamped triple 2026-08-07 10:12:35.033826 — so all seven predate their own
  marker. #11209 IS merged, so no NEW abandonment is prose-only. The gap is
  exactly these seven historical rows, and it is fully closable.

  ## Every value is DERIVED from the row, and from the code that wrote it

  Nothing here is typed twice. The prose pattern and the depth regex are both
  derived from `Sites.Deploy.abandonment_reason/3` — the single public function
  that writes the sentence — by interpolating a probe integer and splitting the
  result on it. A reword there changes these patterns with it, so this file cannot
  quietly disagree with the sentence it parses.

    * `deferral_depth` — the integer out of the row's OWN sentence
      ("refused 12 rebuilds in a row for this site").
    * `deferral_cause` — from the terminal-verdict clause, which is one-to-one
      with the cause (`terminal_verdict/1`, deploy.ex:1469/1473): a capacity
      abandonment accuses the box's concurrent-build cap, a busy one accuses its
      deploy runner. Two causes, two patterns, one UPDATE each — so a row is
      never guessed into a cause it does not name.
    * `deferral_bound` — SET TO THE DERIVED DEPTH, never to today's constant.
      The arm fires only AT the bound, so the row's own sentence carries the
      bound that was in force when it was written. Reading `@max_consecutive_*`
      here instead would make this backfill retroactively wrong the day a cap
      changes.

  ## Idempotent, and narrow by construction

  The predicate requires all three columns NULL, the cause's own prose pattern,
  and a depth the regex actually extracted. A second run therefore updates zero
  rows, and a failed row that never deferred (no chain sentence) is not touched —
  a migration that stamped every failure would put ordinary build failures into
  the abandonment numerator, which is precisely the lie this column set exists to
  end. `sites_deploy_test.exs` gates that with a fixture holding both shapes.

  ## The down clears exactly what the up set

  A prose-matching abandonment written AFTER the W28 writer landed got its columns
  from `defer/3`, not from here, and a `down/0` that cleared those would destroy
  live producer data. So the down is fenced on `inserted_at < @writer_landed_at`
  — the timestamp of the first triple the writer ever stamped. Rows older than
  that cannot have been stamped by anything but this migration.

  ## Scale

  Seven rows in a 32,953-row / 45 MB table, matched by two sequential scans in one
  transaction. No index is created and none is needed; the slow-data-migration
  precedent (per-row UPDATE loops) does not apply.
  """

  use Ecto.Migration

  alias BarkparkCloud.Sites.Deploy

  # Any integer works; it exists only to locate the interpolation point in
  # `abandonment_reason/3` so the patterns can be DERIVED rather than typed.
  @depth_probe 424_242

  # The two causes whose terminal verdict is NAMED (`terminal_verdict/1`). The
  # third clause — "a cause the ledger cannot name" — is deliberately absent: it
  # has never fired in production, and a row whose cause the WRITER could not name
  # is not one a backfill should name for it.
  @causes ["BOX_AT_CAPACITY_DEFERRED", "BOX_BUSY_DEFERRED"]

  # The first `deferral_depth` / `deferral_bound` / `deferral_cause` triple the
  # W28 writer ever stamped, on cloud-db-1. Everything older got its columns
  # here or nowhere.
  @writer_landed_at ~U[2026-08-07 10:12:35.033826Z]

  def up do
    stamped =
      for {sql, params} <- backfill_statements(), reduce: 0 do
        acc ->
          %Postgrex.Result{num_rows: n} = repo().query!(sql, params)
          acc + n
      end

    IO.puts(
      "BackfillAbandonmentDeferralStructure: stamped deferral_depth/bound/cause on " <>
        "#{stamped} historical abandonment row(s)."
    )
  end

  def down do
    cleared =
      for {sql, params} <- clear_statements(), reduce: 0 do
        acc ->
          %Postgrex.Result{num_rows: n} = repo().query!(sql, params)
          acc + n
      end

    IO.puts(
      "BackfillAbandonmentDeferralStructure: cleared #{cleared} backfilled row(s) " <>
        "(rows stamped by Sites.Deploy after #{@writer_landed_at} are untouched)."
    )
  end

  @doc """
  One `{sql, params}` per named cause — public so the guard test exercises the
  EXACT predicate that ships rather than a paraphrase of it.

  Params are positional: `$1` the cause, `$2` the depth regex, `$3` the prose
  LIKE pattern.
  """
  @spec backfill_statements() :: [{String.t(), [term()]}]
  def backfill_statements do
    for cause <- @causes do
      sql = """
      UPDATE deployments AS d
         SET deferral_depth = (regexp_match(d.failure_reason, $2))[1]::integer,
             deferral_bound = (regexp_match(d.failure_reason, $2))[1]::integer,
             deferral_cause = $1
       WHERE d.deferral_depth IS NULL
         AND d.deferral_bound IS NULL
         AND d.deferral_cause IS NULL
         AND d.failure_reason LIKE $3 ESCAPE '\\'
         AND (regexp_match(d.failure_reason, $2))[1] IS NOT NULL
      """

      {sql, [cause, depth_regex(), prose_like_pattern(cause)]}
    end
  end

  @doc """
  The reverse: clear the three columns on rows this migration could have set —
  the cause's own prose, `deferral_depth = deferral_bound` (which is what the up
  writes), and inserted BEFORE the W28 writer landed.
  """
  @spec clear_statements() :: [{String.t(), [term()]}]
  def clear_statements do
    for cause <- @causes do
      sql = """
      UPDATE deployments AS d
         SET deferral_depth = NULL,
             deferral_bound = NULL,
             deferral_cause = NULL
       WHERE d.deferral_cause = $1
         AND d.deferral_depth = d.deferral_bound
         AND d.inserted_at < $2
         AND d.failure_reason LIKE $3 ESCAPE '\\'
      """

      {sql, [cause, @writer_landed_at, prose_like_pattern(cause)]}
    end
  end

  @doc """
  The POSIX pattern that lifts the round count out of the row's own sentence,
  derived from `Deploy.abandonment_reason/3` rather than re-typed.
  """
  @spec depth_regex() :: String.t()
  def depth_regex do
    {prefix, _suffix} = sentence_parts(hd(@causes))
    Regex.escape(prefix) <> "([0-9]+)"
  end

  @doc """
  The LIKE pattern that identifies an abandonment OF THIS CAUSE: the shared
  "refused N rebuilds in a row for this site" clause plus the cause's own terminal
  verdict, with the interpolated count replaced by a wildcard.
  """
  @spec prose_like_pattern(String.t()) :: String.t()
  def prose_like_pattern(cause) do
    {prefix, suffix} = sentence_parts(cause)
    "%" <> escape_like(prefix) <> "%" <> escape_like(suffix) <> "%"
  end

  @doc "The timestamp fence the down uses — the first triple the W28 writer stamped."
  @spec writer_landed_at() :: DateTime.t()
  def writer_landed_at, do: @writer_landed_at

  # The sentence, split at the round count: everything before it, everything after
  # it (which is the cause's terminal verdict).
  defp sentence_parts(cause) do
    [prefix, suffix] =
      ""
      |> Deploy.abandonment_reason(@depth_probe, cause)
      |> String.split(Integer.to_string(@depth_probe), parts: 2)

    {prefix, suffix}
  end

  defp escape_like(fragment) do
    fragment
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
