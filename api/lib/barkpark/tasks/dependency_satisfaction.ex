defmodule Barkpark.Tasks.DependencySatisfaction do
  @moduledoc """
  ONE definition of "this blocker is finished, so its dependents may proceed" —
  and the reason it is a module rather than three copies of `== "done"`.

  ## The hole this closes

  `create` and `createIfNotExists` on a FRESH id are deliberately exempt from
  the ledger guards (charter D53), and that exemption is structural: a birth has
  no prior revision, so an `ifRevisionID` fence is undefined there.

  Dependency satisfaction used to read exactly one field:

      done.content->>'lifecycle_status' = 'done'

  So ONE forged fresh create, carrying `lifecycle_status: "done"` and nothing
  else, flipped a dependent from not-ready to READY, with no attribution
  anywhere in the ledger. Not a lost field — a MANUFACTURED completion, which
  is the worse direction.

  ## Why the fix is here and not on the birth path

  A birth path is a PERMIT. Guarding it means deciding, at create time, which
  rows are allowed to claim they are finished — and getting that wrong bans
  legitimate imports. This module narrows a permit on the READ side instead: a
  done row must also carry evidence that a close actually happened.

  Nothing about `create` changes. The importer question becomes moot rather than
  answered, which is worth more than answering it.

  ## What counts as provenance

  Any ONE of:

    * `content.claim.closed_by` — the worker the close was fenced against
    * `content.claim.closed_at` — the close timestamp the CAS wrote
    * a non-empty `content.close_reason` — the sentence a close requires

  A forged create carries none of them by accident. `Barkpark.Tasks.close/3`
  writes all three.

  ## Measured before shipping, and stated with its denominator

  Over 8,580 live rows: 4 rows carry dependencies at all, 7 rows are named as a
  dependency, and 7 dependency links are currently satisfied by a done row. All
  7 of those blockers carry `claim.closed_by`, `claim.closed_at` AND a non-empty
  `close_reason`.

  So this rule would un-satisfy **0 of 7** links today. That is measured at zero
  on a population of SEVEN — a fact about how little the dependency feature is
  used, not a licence. It is "no current harm", not "no future harm": a bulk
  import that created done rows without claims, and something depending on them,
  would meet this rule. The `close_reason` arm is what makes that survivable,
  and 7 of 7 is what earns it.

  ## THREE CALL SITES, and they must agree

  This predicate is evaluated in three places, two in Elixir and one in SQL:

    * `Tasks.Queue.ready/1`   — the ready-queue predicate (SQL)
    * `Tasks.Claim`           — `check_deps_satisfied/1` at claim time (Elixir)
    * `Tasks.Close`           — `all_blockers_done?/1` for cascade-unblock (Elixir)

  A change applied to two of the three leaves the hole open in the third, which
  is exactly the shape that produced this repo's merge-gate divergence (three
  verbs, three answers to one question) and its `stage.ex` lock-key drift. The
  SQL cannot literally share code with the Elixir, so `sql_fragment/0` and
  `satisfied?/1` live here side by side and
  `dependency_satisfaction_test.exs` drives BOTH over the same fixtures and
  asserts they agree. That test is the only thing keeping them honest.
  """

  @provenance_keys ~w(closed_by closed_at)

  @doc """
  Is this blocker's content finished AND attributable?

  Takes the blocker's `content` map. Returns false for anything that is not a
  map, because a malformed blocker is not evidence of completion.
  """
  @spec satisfied?(map() | nil) :: boolean()
  def satisfied?(content) when is_map(content) do
    done?(content) and has_provenance?(content)
  end

  def satisfied?(_), do: false

  @doc """
  Does the row claim to be done? The old, forgeable half of the test.
  """
  @spec done?(map()) :: boolean()
  def done?(content) when is_map(content),
    do: Map.get(content, "lifecycle_status") == "done"

  def done?(_), do: false

  @doc """
  Does the row carry evidence that a close actually happened?

  Kept separate from `done?/1` so a refusal can say WHICH half failed — a
  dependent that never becomes ready is the silent-invisibility defect pointed
  at the fleet's own work intake, and "not ready" without a reason is exactly
  that.
  """
  @spec has_provenance?(map()) :: boolean()
  def has_provenance?(content) when is_map(content) do
    claim = Map.get(content, "claim")

    claim_provenance =
      is_map(claim) and
        Enum.any?(@provenance_keys, fn k ->
          case Map.get(claim, k) do
            v when is_binary(v) -> String.trim(v) != ""
            nil -> false
            _ -> true
          end
        end)

    reason =
      case Map.get(content, "close_reason") do
        v when is_binary(v) -> String.trim(v) != ""
        _ -> false
      end

    claim_provenance or reason
  end

  def has_provenance?(_), do: false

  # The ONE SQL text, written against a `?` placeholder for the blocker's
  # `content` jsonb. Both SQL shapes below are DERIVED from it by substitution,
  # so there is no second place to edit:
  #
  #   * `content_sql_fragment/0` — the `?`-placeholder form, for an Ecto
  #     `fragment/n` that binds `b.content` positionally (the ready query's
  #     blocks-EDGE gate, which joins the blocker and has no stable SQL alias).
  #   * `sql_fragment/1`         — the same text with `?` replaced by
  #     `<alias>.content`, for raw SQL that names its own alias (the ready
  #     query's `content.dependencies` gate, aliased `done`).
  @content_sql """
  ?->>'lifecycle_status' = 'done'
  AND (
    COALESCE(NULLIF(BTRIM(?->'claim'->>'closed_by'), ''), '') <> ''
    OR COALESCE(NULLIF(BTRIM(?->'claim'->>'closed_at'), ''), '') <> ''
    OR COALESCE(NULLIF(BTRIM(?->>'close_reason'), ''), '') <> ''
  )
  """

  @doc """
  The SQL half in `?`-placeholder form — FOUR binds, all the same `content`
  jsonb, in order.

  Ecto's `fragment/n` needs a compile-time literal, so a caller reads this into
  a module attribute (`@dep_satisfied_sql DependencySatisfaction.content_sql_fragment()`)
  and interpolates that. That is what makes the ready query's edge gate the
  SAME predicate as `satisfied?/1` rather than a hand-typed neighbour of it.
  """
  @spec content_sql_fragment() :: String.t()
  def content_sql_fragment, do: @content_sql

  @doc """
  How many `?` binds `content_sql_fragment/0` consumes. Pinned by test so a
  future edit to the predicate cannot silently change a caller's arity.
  """
  @spec content_sql_bind_count() :: pos_integer()
  def content_sql_bind_count, do: length(String.split(@content_sql, "?")) - 1

  @doc """
  The SQL half, as one fragment over a row under the given SQL alias (default
  `done`). Derived from `@content_sql` — never typed twice.

  MUST stay equivalent to `satisfied?/1`. `dependency_satisfaction_test.exs`
  drives both over the same fixtures; if you change one and not the other, that
  test is what tells you.
  """
  @spec sql_fragment(String.t()) :: String.t()
  def sql_fragment(alias_name \\ "done") when is_binary(alias_name),
    do: String.replace(@content_sql, "?", alias_name <> ".content")

  @doc """
  Why a specific blocker does not satisfy — the sentence a caller sees.

  A dependency that silently stays unsatisfied is a row that never becomes
  ready with nobody able to say why. This names the blocker, which half it
  failed, and what would fix it.
  """
  @spec explain(String.t(), map() | nil) :: String.t()
  def explain(blocker_id, content) do
    cond do
      not is_map(content) ->
        "#{blocker_id} could not be read as a task, so it cannot satisfy a dependency."

      not done?(content) ->
        status = Map.get(content, "lifecycle_status") || "(none)"
        "#{blocker_id} is #{status}, not done — finish or cancel it first."

      true ->
        "#{blocker_id} reads lifecycle_status=done but carries NO record that a close " <>
          "happened, so it cannot satisfy a dependency: a row can be born claiming to be " <>
          "finished, and one forged create would otherwise unblock this work. It needs ONE " <>
          "of content.claim.closed_by, content.claim.closed_at, or a non-empty " <>
          "content.close_reason. Closing it through the verb writes all three: " <>
          "bp task close #{blocker_id} <worker> <epoch> done \"<what shipped>\". If it is " <>
          "genuinely finished and predates the close verb, give it a close_reason."
    end
  end
end
