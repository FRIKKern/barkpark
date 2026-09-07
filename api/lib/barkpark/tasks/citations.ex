defmodule Barkpark.Tasks.Citations do
  @moduledoc """
  THE SECOND-CITATION GRAMMAR — `Discharges:` — and nothing else.

  WHY IT EXISTS (task-29781d0921e5a885, measured FIVE times on 2026-09-06).
  A PR carries exactly ONE `Task:` trailer, so a merge credits exactly one row.
  When that same merge also discharged a criterion on a SIBLING row, the sibling
  never learned: it kept advertising `met: false` with nothing on it hinting
  that origin/main already holds the fix. Five times in one day a lead re-triaged
  or a builder was dispatched to re-derive a finished thing. The failure runs in
  the expensive direction — a stale UNMET reads as work, and refuting it costs a
  full re-derivation.

  WHY A SECOND WORD AND NOT A SECOND `Task:` LINE. `scripts/pr-task-gate.sh`
  reads every column-0 `Task:` line and REFUSES two distinct ids (exit 4,
  "ambiguous task reference") — deliberately, because a gate that picks by
  position is guessing permissively. That refusal is correct and is not being
  weakened here. So the second citation gets its own keyword, which the gate's
  `^task:` regex cannot match at all: adding `Discharges:` lines to a PR body
  cannot change what the gate extracts, and `pr-task-gate.test.sh` asserts it.

  THE FORM, at column 0, case-insensitive, one citation per line:

      Discharges: task-29781d0921e5a885 c2
      Discharges: `task-29781d0921e5a885`
      discharges:   some-row-slug

  * the id character class is `pr-task-gate.sh`'s, verbatim (`a-z 0-9 . _ / -`,
    first character alphanumeric), and surrounding backticks are stripped —
    the house idiom wraps ids in backticks and #5290 went red over exactly that;
  * `c<N>` is the OPTIONAL zero-based criterion index the citation names. No
    `c<N>` means the citation is about the row, not about one criterion;
  * anything else on the line yields NO citation. `Discharges: the old
    behaviour` must not resolve to a row called `the`, so the line is anchored
    at both ends and trailing prose is a non-match, not a prefix match;
  * TWO DISTINCT IDS IS THE POINT, not an ambiguity. Unlike `Task:`, more than
    one `Discharges:` line is the normal shape — one PR, several sibling rows.
    Exact duplicates (same id AND same index) are collapsed so a body may
    restate its own citation.

  Pure. No IO, no repo, no conn — the whole grammar is one function over a
  string, so the non-vacuity proof (a body citing two rows yields two, one
  yields one) is a plain unit test.
  """

  # Anchored at BOTH ends on purpose — see the moduledoc. `\r?` so a CRLF body
  # (a PR description pasted from a Windows editor) parses identically.
  @citation ~r/^discharges:[ \t]*`?([a-z0-9][a-z0-9._\/-]*)`?(?:[ \t]+c([0-9]{1,4}))?[ \t]*\r?$/i

  @typedoc "One parsed citation: the row named, and the criterion index it names (or nil)."
  @type citation :: %{task_id: String.t(), criterion: non_neg_integer() | nil}

  @doc """
  Every DISTINCT `Discharges:` citation in a PR body, in the order written.

  Returns `[]` for a body with none — the common case, and never an error: a PR
  that cites no sibling row is the normal PR.

      iex> Barkpark.Tasks.Citations.discharges("Task: task-a\\nDischarges: task-b c2\\n")
      [%{task_id: "task-b", criterion: 2}]
  """
  @spec discharges(term()) :: [citation()]
  def discharges(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.flat_map(&parse_line/1)
    |> Enum.uniq()
  end

  def discharges(_), do: []

  # CASE IS PRESERVED, not normalised — `pr-task-gate.sh` matches its trailer
  # case-insensitively and emits the id exactly as written, and a second
  # normalisation here would be a second grammar (the #5290 failure mode).
  defp parse_line(line) do
    case Regex.run(@citation, line) do
      [_, id] -> [%{task_id: id, criterion: nil}]
      [_, id, ""] -> [%{task_id: id, criterion: nil}]
      [_, id, n] -> [%{task_id: id, criterion: String.to_integer(n)}]
      _ -> []
    end
  end
end
