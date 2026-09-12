defmodule BarkparkCloud.Web.VerifyRouteProducerExemptionTest do
  @moduledoc """
  THE PRODUCER EXEMPTION, as a test rather than a comment (cch-w58-bl, D706).

  SCOPE, and read this clause before reading anything else: this file exempts
  `POST /v1/barkparks/:id/verify` from REACHABILITY-DERIVED refusals ONLY —
  refusals computed from `verify_reachable` / `last_verified_at`. It says NOTHING
  about any other guard on this route. In particular it does NOT exempt the route
  from a SUSPENSION refusal (filed separately as
  `cch-w58-bl-verify-route-spends-the-credential-on-a-suspended-box`, GH #11092):
  suspension is not circular — nothing about un-suspending a box requires a
  verify run — so that refusal is legitimate here and this census must never be
  read as forbidding it. A blanket "this route refuses nothing" census would kill
  it, which is exactly the mistake this scoping clause exists to prevent.

  WHY THE EXEMPTION IS REAL. `verify_reachable` and `last_verified_at` have
  exactly ONE writer in the whole application — `Registry.record_verify_result/2`
  (registry.ex) — reached from exactly ONE call site: `run_verify/3` in this
  router, reached only from this route. Every changeset in
  `registry/barkpark.ex` was enumerated: only `verify_changeset/2` casts these
  two columns; `health_changeset/2` (the agent-report and provision-success path)
  does not; no `update_all` names them; the migration is add-only, no default and
  no backfill.

  So a reachability-derived refusal placed ON this route would permanently trap
  every never-verified box: the only way to become reachable is to run the route
  that the refusal blocks. Today the exemption holds by ACCIDENT —
  `Verify.run/1` calls `Registry.reveal_admin_token/1` DIRECTLY rather than going
  through the shared `relay_admin/4` seam — and nothing reds if a future edit
  routes it through a helper that has grown a reachability precondition. This
  file makes that edit LOUD.

  HOW IT WORKS. It re-derives two source blocks from `router.ex` on every run —
  the `POST /v1/barkparks/:id/verify` route block and `run_verify/3` — drops the
  ONE allowed producer line (`Registry.record_verify_result(`), and fails if any
  remaining line mentions a reachability symbol from `@forbidden_reads`.

  MEASURED MARGINAL VALUE (not asserted). A subtle
  `if bp.verify_reachable == false, do: 409` planted at the top of `run_verify/3`
  REDS this file — and is INVISIBLE to the entire existing `verify_test.exs`,
  which stays 20/20 because no fixture anywhere in the suite sets
  `verify_reachable` (every one of its six occurrences in the suite is an
  ASSERTION, never a fixture). That blindness is the coverage this file buys.

  THE ONE STANDING MAINTENANCE OBLIGATION. This guard is TEXTUAL and it fails
  OPEN one call deep: a refusal hidden inside a helper the route merely CALLS is
  invisible here. Therefore — any PR that mints a shared reachability helper
  (anything that reads `verify_reachable` or `last_verified_at` on behalf of a
  caller) **or a shared reachability-DERIVED COLUMN READER (a new column whose
  value is computed from whether we could reach the box — `update_unavailable_reason`
  is the third such column, cch-w58/#11102)** adds that helper's or column's NAME
  to `@forbidden_reads` IN THE SAME PR. That is the whole contract; it is cheap,
  and it is the only thing keeping this from decaying into decoration.

  The obligation was HELPER-SHAPED until cch-w60-s7 and the hazard is
  COLUMN-SHAPED: #11102 landed a nine-rung refusal vocabulary on a brand-new
  reachability-derived column and discharged the old obligation completely
  (it minted no helper), walking straight past this guard. The widened trigger
  is what stops the same hole reopening on the fourth column.

  THE THIRD COLUMN IS A REVIEW TRIPWIRE, **NOT** D706'S CIRCULARITY REFUSAL —
  and this file must not be read as claiming otherwise. D706's exemption rests
  on ONE argument: this route is the SOLE WRITER of `verify_reachable` /
  `last_verified_at`, so a refusal derived from them traps the box forever.
  `update_unavailable_reason` is NOT circular in any degree. Its only two
  writers — `persist_update_check/2` (the unconditional
  `force_change(:update_unavailable_reason, nil)` clear) and
  `persist_update_unknown/2`, both in registry.ex — are reached ONLY from
  `Registry.refresh_update_status/1`, whose four callers are
  `workers/update_status_worker.ex`, `workers/autoupdate_rollout_worker.ex`,
  the router's now-live kick, and `internal/cli/cloud/freshen.go` (via its
  route). NONE of them is the verify route. A box refused on this column
  therefore recovers on the next hourly sweep with NO verify run needed.
  So its entry below means: a refusal on this route derived from that column is
  UN-ADJUDICATED and must be ARGUED in review — it is not automatically wrong
  the way a `verify_reachable` refusal is. Writing it in as a silent fourth
  reachability symbol would put a FALSE rationale in this file (the exact defect
  `cch-w53-s3` had to fix in the audit census).

  THE SECOND ARM: `Registry.reveal_admin_token/1` IS A FORBIDDEN HOME FOR ANY
  REFUSAL. `Verify.run/1` calls it DIRECTLY (verify.ex, inside `run/1`) rather
  than through the shared `relay_admin/4` seam — that directness is the whole
  reason the exemption holds by accident today. A refusal planted inside
  `reveal_admin_token/1` traps the verify route AND every other credential
  consumer at once, and the router-block scan above stays GREEN because it fails
  open one call deep and never reads registry.ex.

  Its mentions OUTSIDE registry.ex, re-derived at 839453b706 (#11287, which IS
  origin/main) — SIX mentions, FIVE of them real call sites:

    1. `lib/barkpark_cloud/verify.ex:33`  — @moduledoc prose, NOT a call site.
    2. `lib/barkpark_cloud/verify.ex:131` — `Verify.run/1`, the verify route.
    3. `lib/barkpark_cloud/usage.ex:923`  — the usage meter's instance probe.
    4. `lib/barkpark_cloud/web/router.ex:2367`  — support-instance provisioning.
    5. `lib/barkpark_cloud/web/router.ex:2719`  — owner-facing `/credentials`.
    6. `lib/barkpark_cloud/web/router.ex:11204` — the third router consumer.

  (The brief for cch-w60-s7 said "six callers" and listed five, at line numbers
  that have since drifted; the count above is re-derived, not inherited. Note
  also that `reveal_admin_token/1`'s own @doc in registry.ex still claims
  "the owner-facing `/credentials` route is the only caller" — false since at
  least verify.ex and usage.ex. Fixing registry.ex prose is outside this slice's
  file fence; filed separately.)

  The `reveal_admin_token/1 is refusal-free` test below extracts that function's
  clause group from registry.ex and reds if any reachability symbol appears in
  it, and pins that `Verify.run/1` still reaches it directly. `reveal_admin_token`
  is ALSO in `@forbidden_reads` for the router blocks: `run_verify/3` resolves no
  credential itself ("never seen here", per its own comment), so its appearance
  there is a change of shape that must be argued.

  METHOD NOTES (each one a measured bug, not a preference):

    * The route regex matches both declaration forms (`post "..." do` and
      `post("...", do: …)`). A first draft blind to the space form FAILED LOUDLY
      via the non-vacuity arm below, which is the behaviour you want.
    * The block terminator is the STRICT `^  end` — the same choice
      `router_head_fence_census_test.exs` documents. `^\\s*end$` truncates a body
      at its first nested `end`; scanning to the next route macro overshoots and
      swallows the following route's doc comment.
    * NON-VACUITY: a source-scanning test that extracts NOTHING passes trivially.
      Both blocks are therefore pinned to >10 lines and to a per-block anchor.
      The anchors differ by block because `Verify.run(bp)` textually exists only
      in `run_verify/3`; the route block's anchor is its delegation to
      `run_verify(conn, team, bp)`, which is what makes the pair the whole
      surface.
    * COMMENT-AWARENESS (task-bb7e9bcdeb5cea85). Every textual match here runs
      over the CODE half of a line. Matching raw source was wrong in BOTH
      directions: a comment NAMING a forbidden symbol reddened the census (a
      cch-w58 route comment had to be reworded into vaguer prose), and — the
      half worth having — a comment QUOTING `Verify.run(bp)` satisfied the
      non-vacuity anchor after the real call was deleted, holding the guard
      green by prose. See the `## Comment-awareness` section below the
      derivation helpers for the scanner and its conservative failure mode.
  """
  use ExUnit.Case, async: true

  @router_source Path.expand("../../../lib/barkpark_cloud/web/router.ex", __DIR__)
  @registry_source Path.expand("../../../lib/barkpark_cloud/registry.ex", __DIR__)
  @verify_source Path.expand("../../../lib/barkpark_cloud/verify.ex", __DIR__)

  @route_re ~r/^\s*post[\s(]+"\/v1\/barkparks\/:id\/verify"/
  @run_verify_re ~r/^\s*defp run_verify\(/
  @block_end_re ~r/^  end\s*$/

  # THE ONE PRODUCER LINE. This is the write that makes the exemption necessary
  # in the first place; it is allowed and nothing else is.
  @allowed_producer "Registry.record_verify_result("

  # Every symbol that would make behaviour depend on a box's reachability. Grow
  # this list — see the standing obligation in the moduledoc — whenever a shared
  # reachability helper OR a shared reachability-DERIVED column reader is minted
  # anywhere in the app.
  #
  # The last two are the THIRD column (cch-w58/#11102). They are a REVIEW
  # TRIPWIRE, not D706's circularity refusal — the moduledoc states the
  # difference and why; do not collapse them into the first five.
  # `identity_refused` is the loudest rung of `update_unavailable_reasons/0` and
  # is listed as a bare substring only because it appears NOWHERE in either
  # extracted block today (re-derived at 839453b706; its two occurrences in
  # router.ex, :3411 and :3582, are in an unrelated route far outside both
  # blocks) — so it cannot false-fire on prose here.
  @reachability_reads [
    "verify_reachable",
    "last_verified_at",
    "reachable?(",
    "require_reachable",
    "ensure_reachable",
    "verified_recently?",
    "reachability",
    "update_unavailable_reason",
    "identity_refused"
  ]

  # What the two ROUTER blocks may not mention. `reveal_admin_token` is here on
  # top of the reachability vocabulary: `run_verify/3` resolves no credential
  # itself ("The admin token is resolved + used entirely inside `Verify.run/1` —
  # never seen here"), so its appearance in these blocks is a change of shape.
  # It is deliberately NOT in @reachability_reads, which is also applied to
  # `reveal_admin_token/1`'s own body below, where it would fire trivially.
  @forbidden_reads @reachability_reads ++ ["reveal_admin_token"]

  # The credential-decrypt seam `Verify.run/1` calls DIRECTLY, and the clause
  # heads that must remain the whole of it.
  @reveal_def_re ~r/^  def reveal_admin_token\(/
  @verify_run_re ~r/^  def run\(%Barkpark\{url: url\}/
  @next_toplevel_re ~r/^  (@doc|@spec|@impl|def |defp )/

  ## Derivation

  defp source, do: File.read!(@router_source)

  defp block(start_re), do: block(source(), start_re)

  defp block(source, start_re) do
    lines = String.split(source, "\n")

    case Enum.find_index(lines, &Regex.match?(start_re, &1)) do
      nil ->
        []

      i ->
        body =
          lines
          |> Enum.drop(i + 1)
          |> Enum.take_while(&(not Regex.match?(@block_end_re, &1)))

        [Enum.at(lines, i) | body]
    end
  end

  defp route_block, do: block(@route_re)
  defp run_verify_block, do: block(@run_verify_re)

  # `Verify.run/1`'s FIRST clause — the one that owns a live url. Scoped to the
  # clause, not the file: a helper defined elsewhere in verify.ex that merely
  # wraps the seam would satisfy a whole-file grep while removing the very
  # directness this file's exemption rests on (measured — the first draft of the
  # pin below passed under exactly that mutation).
  defp verify_run_block, do: block(File.read!(@verify_source), @verify_run_re)

  # `reveal_admin_token/1`'s clause group in registry.ex: the first clause head
  # and everything up to the next unrelated top-level form. Later clauses of the
  # SAME function are kept (a planted refusal is exactly a new clause head), so a
  # refusal anywhere in the group is in scope.
  defp reveal_clause_group do
    lines = String.split(File.read!(@registry_source), "\n")

    case Enum.find_index(lines, &Regex.match?(@reveal_def_re, &1)) do
      nil ->
        []

      i ->
        body =
          lines
          |> Enum.drop(i + 1)
          |> Enum.take_while(fn line ->
            Regex.match?(@reveal_def_re, line) or not Regex.match?(@next_toplevel_re, line)
          end)

        [Enum.at(lines, i) | body]
    end
  end

  ## Comment-awareness (task-bb7e9bcdeb5cea85)
  #
  # EVERY textual match in this file runs over the CODE part of a line, never
  # the raw line. Matching raw lines could not tell a comment from a call, and
  # it was wrong in BOTH directions:
  #
  #   * a comment that merely NAMED a `@forbidden_reads` symbol reddened the
  #     census — cch-w58 (#16611) had to reword an accurate route comment into
  #     vaguer prose to get past it; and
  #   * the dangerous half: a comment QUOTING `Verify.run(bp)` satisfied the
  #     non-vacuity anchor after the real call was deleted. The guard could be
  #     held GREEN by prose while the call it exists to pin was gone.
  #
  # The moduledoc already knew the distinction in ONE place — it names a
  # verify.ex hit as "@moduledoc prose, NOT a call site" — and never
  # generalised it to the matcher. This is that generalisation.
  #
  # Elixir has no block comments, so a comment is `#` to end of line — but only
  # a `#` that is outside a string, a charlist, a sigil, a heredoc, or a `?#`
  # character literal. The scanner below tracks exactly those. It is
  # CONSERVATIVE BY CONSTRUCTION: any line it cannot scan to a clean end (an
  # unterminated quote, a triple-quote opened mid-line) is returned WHOLE, so
  # an ambiguous `#` counts as CODE and that line keeps the old behaviour
  # rather than a guess silently blinding the guard.

  defp code_lines(lines) do
    {out, _state} =
      Enum.reduce(lines, {[], :code}, fn line, {acc, state} ->
        {code, next} = strip_comment(line, state)
        {[code | acc], next}
      end)

    Enum.reverse(out)
  end

  defp contains_code?(lines, needle),
    do: Enum.any?(code_lines(lines), &String.contains?(&1, needle))

  defp count_code(lines, needle),
    do: Enum.count(code_lines(lines), &String.contains?(&1, needle))

  # Inside a heredoc body nothing is a comment; the closing delimiter on its own
  # line returns us to code.
  defp strip_comment(line, {:heredoc, delim}) do
    if String.trim(line) == delim, do: {line, :code}, else: {line, {:heredoc, delim}}
  end

  defp strip_comment(line, :code) do
    case scan(String.graphemes(line), []) do
      {:ok, code} -> {code, :code}
      {:heredoc, delim} -> {line, {:heredoc, delim}}
      :unscannable -> {line, :code}
    end
  end

  # Walks a line in CODE context. Returns {:ok, code_before_any_comment},
  # {:heredoc, delim} when the line opens one, or :unscannable when a quote
  # never closes — in which case the caller keeps the raw line.
  defp scan([], acc), do: {:ok, emit(acc)}

  # THE WHOLE POINT: a `#` reached in code context starts a comment.
  defp scan(["#" | _rest], acc), do: {:ok, emit(acc)}

  # `?x` is a character literal — `?#` very much included, and it must not be
  # mistaken for a comment.
  defp scan(["?", c | rest], acc), do: scan(rest, [c, "?" | acc])

  defp scan(["\"", "\"", "\"" | rest], _acc) do
    if blank?(rest), do: {:heredoc, "\"\"\""}, else: :unscannable
  end

  defp scan(["'", "'", "'" | rest], _acc) do
    if blank?(rest), do: {:heredoc, "'''"}, else: :unscannable
  end

  defp scan(["\"" | rest], acc), do: skip_quoted(rest, ["\"" | acc], "\"", true)
  defp scan(["'" | rest], acc), do: skip_quoted(rest, ["'" | acc], "'", true)

  # Sigils: ~s(...), ~S"...", ~r/.../ and friends. An UPPERCASE sigil takes no
  # escapes and no interpolation; a lowercase one takes both.
  defp scan(["~", letter, delim | rest], acc) do
    closer = sigil_closer(delim)

    cond do
      not sigil_letter?(letter) -> scan([letter, delim | rest], ["~" | acc])
      sigil_heredoc?(delim, rest) -> {:heredoc, String.duplicate(delim, 3)}
      closer -> skip_quoted(rest, [delim, letter, "~" | acc], closer, lower?(letter))
      true -> scan([letter, delim | rest], ["~" | acc])
    end
  end

  defp scan([c | rest], acc), do: scan(rest, [c | acc])

  defp skip_quoted([], _acc, _closer, _interp), do: :unscannable

  defp skip_quoted([c | rest], acc, closer, interp) do
    cond do
      c == closer ->
        scan(rest, [c | acc])

      interp and c == "\\" ->
        case rest do
          [n | tail] -> skip_quoted(tail, [n, c | acc], closer, interp)
          [] -> :unscannable
        end

      interp and c == "#" and match?(["{" | _], rest) ->
        ["{" | tail] = rest

        case skip_interp(tail, 1, ["{", "#" | acc]) do
          {:ok, remaining, acc2} -> skip_quoted(remaining, acc2, closer, interp)
          :unscannable -> :unscannable
        end

      true ->
        skip_quoted(rest, [c | acc], closer, interp)
    end
  end

  # `#{...}` is CODE inside a string, so its contents are KEPT: a real
  # `"#{bp.verify_reachable}"` read must still be visible to the vocabulary.
  defp skip_interp([], _depth, _acc), do: :unscannable
  defp skip_interp(["}" | rest], 1, acc), do: {:ok, rest, ["}" | acc]}
  defp skip_interp(["}" | rest], depth, acc), do: skip_interp(rest, depth - 1, ["}" | acc])
  defp skip_interp(["{" | rest], depth, acc), do: skip_interp(rest, depth + 1, ["{" | acc])

  defp skip_interp(["\"" | rest], depth, acc) do
    case skip_plain_string(rest, ["\"" | acc]) do
      {:ok, remaining, acc2} -> skip_interp(remaining, depth, acc2)
      :unscannable -> :unscannable
    end
  end

  defp skip_interp([c | rest], depth, acc), do: skip_interp(rest, depth, [c | acc])

  defp skip_plain_string([], _acc), do: :unscannable
  defp skip_plain_string(["\\", n | rest], acc), do: skip_plain_string(rest, [n, "\\" | acc])
  defp skip_plain_string(["\"" | rest], acc), do: {:ok, rest, ["\"" | acc]}
  defp skip_plain_string([c | rest], acc), do: skip_plain_string(rest, [c | acc])

  defp emit(acc), do: acc |> Enum.reverse() |> Enum.join()
  defp blank?(chars), do: chars |> Enum.join() |> String.trim() == ""
  defp sigil_letter?(l), do: l =~ ~r/^[a-zA-Z]$/
  defp lower?(l), do: l =~ ~r/^[a-z]$/

  defp sigil_heredoc?(d, [d, d | tail]) when d in ["\"", "'"], do: blank?(tail)
  defp sigil_heredoc?(_d, _rest), do: false

  defp sigil_closer("("), do: ")"
  defp sigil_closer("["), do: "]"
  defp sigil_closer("{"), do: "}"
  defp sigil_closer("<"), do: ">"
  defp sigil_closer("/"), do: "/"
  defp sigil_closer("|"), do: "|"
  defp sigil_closer("\""), do: "\""
  defp sigil_closer("'"), do: "'"
  defp sigil_closer(_other), do: nil

  defp offending_lines(lines, vocabulary \\ @forbidden_reads) do
    lines
    |> Enum.zip(code_lines(lines))
    |> Enum.reject(fn {_raw, code} -> String.contains?(code, @allowed_producer) end)
    |> Enum.flat_map(fn {raw, code} ->
      case Enum.filter(vocabulary, &String.contains?(code, &1)) do
        [] -> []
        hits -> [{String.trim(raw), hits}]
      end
    end)
  end

  ## The pins

  test "the extractor still reads the source (guard against a vacuous green)" do
    route = route_block()
    run_verify = run_verify_block()

    assert length(route) > 10,
           "the POST /v1/barkparks/:id/verify block extracted #{length(route)} lines; " <>
             "@route_re or @block_end_re has stopped matching router.ex"

    assert length(run_verify) > 10,
           "run_verify/3 extracted #{length(run_verify)} lines; " <>
             "@run_verify_re or @block_end_re has stopped matching router.ex"

    # Per-block anchors: the route delegates to run_verify/3, and run_verify/3 is
    # where the suite actually runs. If either anchor disappears, the pair below
    # is no longer scanning the surface this file claims to cover.
    assert contains_code?(route, "run_verify(conn, team, bp)"),
           "the verify route no longer delegates to run_verify/3 — re-derive this census"

    assert contains_code?(run_verify, "Verify.run(bp)"),
           "run_verify/3 no longer calls Verify.run(bp) — re-derive this census"

    # The producer line must actually be present, or the allow-list below is
    # exempting nothing and the whole file is scanning a surface it misunderstands.
    assert count_code(run_verify, @allowed_producer) == 1,
           "expected exactly one #{@allowed_producer} line inside run_verify/3"
  end

  test "the verify route reads no reachability state except through its one producer" do
    offenders = offending_lines(route_block() ++ run_verify_block())

    assert offenders == [],
           """
           A REACHABILITY READ appeared on POST /v1/barkparks/:id/verify.

           #{Enum.map_join(offenders, "\n", fn {line, hits} -> "  #{Enum.join(hits, ", ")}\n    #{line}" end)}

           This route is the ONLY writer of `verify_reachable` / `last_verified_at`
           (via Registry.record_verify_result/2 → verify_changeset/2). A refusal
           here that depends on those columns permanently traps every
           never-verified box: the only way to become reachable is to run the
           route the refusal blocks.

           If you need to refuse on this route, refuse on something that is NOT
           derived from reachability (suspension, for example, is fine and is
           filed separately — see this file's moduledoc). If you genuinely intend
           a reachability read, you are changing a decision (D684/D706): say so
           here, next to the change.

           TWO OF THESE SYMBOLS ARE A TRIPWIRE, NOT A PROHIBITION.
           `update_unavailable_reason` / `identity_refused` are NOT circular:
           that column's only writers run from `Registry.refresh_update_status/1`
           (hourly sweep + rollout worker + now-live kick + freshen), never from
           this route, so a box refused on it recovers WITHOUT a verify run. A
           refusal derived from it is un-adjudicated rather than automatically
           wrong — argue it here, in this file's moduledoc, and it may stay.
           `reveal_admin_token` is a third thing again: `run_verify/3` resolves
           no credential itself, so seeing it here is a change of shape.
           """
  end

  test "Registry.reveal_admin_token/1 is a refusal-free seam, reached directly by Verify.run/1" do
    group = reveal_clause_group()

    # Non-vacuity, same discipline as the router blocks: an extractor that reads
    # nothing passes trivially.
    heads = Enum.count(group, &Regex.match?(@reveal_def_re, &1))

    assert heads >= 2,
           "extracted #{heads} clause head(s) for reveal_admin_token/1; " <>
             "@reveal_def_re or @next_toplevel_re has stopped matching registry.ex"

    assert contains_code?(group, "Vault.decrypt(ciphertext)"),
           "reveal_admin_token/1 no longer decrypts the stored ciphertext — re-derive this census"

    # The directness this file's exemption rests on. If Verify.run/1 stops
    # calling the seam itself and goes through a shared helper, the accident
    # that keeps the verify route refusal-free is gone.
    run_clause = verify_run_block()

    assert length(run_clause) > 3,
           "Verify.run/1's live-url clause extracted #{length(run_clause)} lines; " <>
             "@verify_run_re or @block_end_re has stopped matching verify.ex"

    assert contains_code?(run_clause, "Registry.reveal_admin_token(bp)"),
           "Verify.run/1 no longer calls Registry.reveal_admin_token/1 directly — " <>
             "the producer exemption now depends on whatever it calls instead"

    offenders = offending_lines(group, @reachability_reads)

    assert offenders == [],
           """
           A REACHABILITY-DERIVED REFUSAL appeared inside Registry.reveal_admin_token/1.

           #{Enum.map_join(offenders, "\n", fn {line, hits} -> "  #{Enum.join(hits, ", ")}\n    #{line}" end)}

           That function is the credential-decrypt seam. `Verify.run/1` calls it
           DIRECTLY (verify.ex), so a refusal here traps the verify route — and
           the router-block scan above CANNOT see it, because that scan fails
           open one call deep. It also traps every other consumer at once: the
           usage meter (usage.ex) and three router paths (see this file's
           moduledoc for the enumerated list).

           Refuse at the CALLER that should be refused, not in the shared decrypt.
           """
  end

  # The stripper's own pins. Without these, the comment-awareness above is an
  # unmeasured claim — and a stripper that is too EAGER is the worse failure:
  # it deletes code and blinds every match in this file at once.
  test "the matcher reads code, not comments — and a `#` inside a literal is code" do
    # A comment is stripped; the identical text as a call is not.
    assert contains_code?(["    run_verify(conn, team, bp)"], "run_verify(conn, team, bp)")

    refute contains_code?(
             ["    # run_verify(conn, team, bp) — prose, deliberately not a call"],
             "run_verify(conn, team, bp)"
           )

    refute contains_code?(["    # Verify.run(bp) is called below"], "Verify.run(bp)")

    # POSITIVE CONTROL ON THE STRIPPER: a `#` inside a string literal does NOT
    # start a comment, so everything after it stays visible to the vocabulary.
    # If this ever refutes, the stripper has started eating live code.
    assert contains_code?(
             [~S|    detail: "tag #1 for verify_reachable boxes"|],
             "verify_reachable"
           )

    # `#{...}` is code inside a string: a real read there must stay visible.
    assert contains_code?(
             [~S|    Logger.info("state: #{bp.verify_reachable}")|],
             "verify_reachable"
           )

    # `?#` is a character literal, not the start of a comment.
    assert contains_code?(["    hash = ?#, and bp.verify_reachable"], "verify_reachable")

    # A heredoc body carries no comments: a `#` inside one strips nothing.
    assert contains_code?(
             [
               ~S|    @doc """|,
               ~S|    # verify_reachable inside a heredoc is not a comment|,
               ~S|    """|
             ],
             "verify_reachable"
           )

    # And the two directions this row exists for, on offending_lines/2 itself.
    assert offending_lines(["    # names verify_reachable in prose"]) == []
    assert [{_line, ["verify_reachable"]}] = offending_lines(["    if bp.verify_reachable do"])
  end
end
