defmodule Barkpark.Tasks.QueueGateFragmentPlaceholdersTest do
  @moduledoc """
  `Ecto.Query.fragment/1` counts EVERY `?` in its format string as a bound
  placeholder. It cannot tell an argument slot from a regex quantifier, so a
  pattern inlined into a fragment string is written in a restricted dialect —
  no `?`, no `{n,m}` — that NOTHING at the edit site declares. The failure it
  produces is a compile error naming Ecto and an argument count, three tokens
  away from the character that caused it.

  This file is the thing at the edit site. It counts the `?` in every fragment
  format string inside `QueueGate.executable_query/0` and compares it to that
  fragment's own argument count, so the next editor meets the constraint here
  — with the cause named — instead of meeting it in a mis-directed compiler
  error.

  A check that cannot discriminate is worse than none, so the control below
  feeds the BROKEN form (the inlined `([.][0-9]+)?` pattern that did not
  compile) through the SAME audit and asserts it is reported as 4 against 3.
  """

  use ExUnit.Case, async: true

  @source "lib/barkpark/tasks/queue_gate.ex"

  # The exact fragment that did not compile, from the measurement in
  # task-de481ee75f777d55: the anchored pattern with `([.][0-9]+)?` INLINED.
  # Its trailing `?` is a quantifier; Ecto reads it as a fourth placeholder.
  @broken_form ~S|
    fragment(
      "CASE WHEN ?->'claim'->>'ts_iso' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?Z$' THEN ?->'claim'->>'ts_iso' < to_char((now() at time zone 'UTC') - (? * interval '1 second'), 'YYYY-MM-DD\"T\"HH24:MI:SS') ELSE false END",
      d.content,
      d.content,
      ^lease_ttl_seconds()
    )
  |

  # Every fragment/N call reachable under `ast`, as {question_marks, arg_count}.
  # A fragment whose format string is not a plain binary literal is returned as
  # :undecidable rather than skipped — silence is how this check would go
  # vacuous if somebody interpolated the format string.
  defp fragment_audit(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:fragment, _meta, [format | args]} = node, acc when is_binary(format) ->
          {node, [{format, count_question_marks(format), length(args)} | acc]}

        {:fragment, _meta, [_format | args]} = node, acc ->
          {node, [{:undecidable, :undecidable, length(args)} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp count_question_marks(format),
    do: format |> String.graphemes() |> Enum.count(&(&1 == "?"))

  defp executable_query_ast do
    source = File.read!(Path.join(File.cwd!(), @source))
    {:ok, ast} = Code.string_to_quoted(source)

    found =
      Macro.prewalk(ast, nil, fn
        {:def, _, [{:executable_query, _, _} | _]} = node, nil -> {node, node}
        node, acc -> {node, acc}
      end)
      |> elem(1)

    # AN ABSENCE MUST NOT PASS SILENTLY: a renamed function would leave this
    # test walking an empty AST and reporting a cheerful green over nothing.
    refute is_nil(found),
           "executable_query/0 not found in #{@source} — it was renamed or removed. " <>
             "Repoint this test; do not delete the assertion."

    found
  end

  test "every fragment in executable_query/0 has as many ? as arguments" do
    audit = fragment_audit(executable_query_ast())

    # CONTROL: the walker actually found the fragments. Four claim-side plus the
    # queue_gate arm's five — an empty list would make the assertion below
    # trivially true.
    assert length(audit) >= 4,
           "fragment walker found #{length(audit)} fragments — expected the real query's several"

    mismatched =
      Enum.filter(audit, fn {_format, marks, args} -> marks != args end)

    assert mismatched == [], """
    A fragment's `?` count does not equal its argument count in #{@source}.

    Ecto counts EVERY `?` in a fragment format string as a bound placeholder,
    including one that is a regex quantifier. If you tightened a pattern inside
    a fragment string, bind it as an argument instead — see
    QueueGate.ts_iso_shape_pattern/0, which exists for exactly this reason.

    #{inspect(mismatched, pretty: true, limit: :infinity)}
    """
  end

  test "CONTROL: the audit reports the broken inlined form as 4 against 3" do
    {:ok, ast} = Code.string_to_quoted(@broken_form)

    assert [{_format, 4, 3}] = fragment_audit(ast)
  end

  test "the ts_iso shape guard is a bound parameter, and is the precise pattern" do
    pattern = Barkpark.Tasks.QueueGate.ts_iso_shape_pattern()

    # It is the precise pattern the workaround could not be: a quantifier `?`
    # lives inside it, which is only possible because it is bound, not inlined.
    assert String.contains?(pattern, "([.][0-9]+)?")

    assert Regex.match?(Regex.compile!(pattern), "2026-07-26T18:00:00Z")
    assert Regex.match?(Regex.compile!(pattern), "2026-07-26T18:00:00.123456Z")

    # The shapes `[.0-9]*Z$` used to admit, and no longer does.
    refute Regex.match?(Regex.compile!(pattern), "2026-07-26T18:00:00123Z")
    refute Regex.match?(Regex.compile!(pattern), "2026-07-26T18:00:00.1.2Z")

    source = File.read!(Path.join(File.cwd!(), @source))

    # The pattern reaches the query as `^ts_iso_shape_pattern()`, never as a
    # literal inside the format string.
    assert String.contains?(source, "^ts_iso_shape_pattern()")
    refute String.contains?(source, "~ '^[0-9]{4}")
  end

  test "PR #16954's two settled properties survive: no cast, cutoff rendered in UTC" do
    source = File.read!(Path.join(File.cwd!(), @source))

    [raw_body] =
      Regex.run(~r/def executable_query do\n(.*?)\n  end\n/s, source, capture: :all_but_first)

    # The CODE only. The prose above the query discusses `::timestamptz` by
    # name, and a guard that reads its own explanation as the thing it forbids
    # would fire on the comment that says the cast is absent.
    query_body =
      raw_body
      |> String.split("\n")
      |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
      |> Enum.join("\n")

    # CONTROL: the slice is the real body, not an empty match, and stripping
    # comments did not strip the code.
    assert String.contains?(query_body, "to_char(")
    refute String.contains?(query_body, "SQL TWIN of")

    # A `::timestamptz` cast RAISES on a malformed string and this query gates
    # the whole ready population — one bad ts_iso would take `bp task ready`
    # down for every worker.
    refute String.contains?(query_body, "::timestamptz")

    # The cutoff stays rendered in UTC: a session-local `now()` made the
    # effective lease `ttl - utc_offset`.
    assert String.contains?(query_body, "now() at time zone 'UTC'")
  end
end
