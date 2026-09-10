defmodule BarkparkCloud.RegistryNameClaimSelectCensus.Extract do
  @moduledoc """
  The Side-A extractor for the SELECT that feeds `Registry.claim_leg/2` — the
  keys `provisioning_fqdn_claim/2` computes, and the shape of each computed
  expression, read off the Elixir AST (`Code.string_to_quoted!/1`).

  Why this exists at all. `registry_name_claim_census_test.exs` censuses the
  leg SET, its ORDER and three constants; its own moduledoc names the hole:
  the select that COMPUTES `has_admin_token` / `recent_sample` /
  `live_subscription` is not guarded. A leg can therefore be gutted at its
  source with that whole file green — narrow the `recent_sample` EXISTS
  subquery, or add a conjunct to `has_admin_token`, and the leg still exists,
  still fires for the one fixture that happens to satisfy the new conjunct,
  and reports nothing.

  Bounded on purpose: this reads the ONE `select/3` inside
  `provisioning_fqdn_claim/2` and the `row.<key>` reads inside `claim_leg/2`.
  It does not execute SQL and it does not follow `subquery/1` into another
  function's query.
  """

  @doc """
  The `%{key => expr}` pairs of the ONE `select([b], %{…})` inside
  `provisioning_fqdn_claim/2`, in SOURCE ORDER. Raises if the function, the
  select, or the map is gone — a census that answers `[]` for a deleted
  select would go green on the widest possible edit.
  """
  @spec select_pairs(binary) :: [{atom, Macro.t()}]
  def select_pairs(source) when is_binary(source) do
    body = fun_ast(source, :provisioning_fqdn_claim, 2)

    {_, selects} =
      Macro.prewalk(body, [], fn
        {:select, _, args} = node, acc -> {node, [args | acc]}
        node, acc -> {node, acc}
      end)

    case selects do
      [args] ->
        case List.last(args) do
          {:%{}, _, pairs} when is_list(pairs) and pairs != [] ->
            Enum.map(pairs, fn {k, v} when is_atom(k) -> {k, v} end)

          other ->
            raise "provisioning_fqdn_claim/2's select/3 no longer projects a non-empty map: " <>
                    Macro.to_string(other)
        end

      [] ->
        raise "no select/3 inside provisioning_fqdn_claim/2 — the whole projection is gone"

      many ->
        raise "#{length(many)} select/3 calls inside provisioning_fqdn_claim/2; this census " <>
                "assumes exactly one and must be taught which one feeds claim_leg/2"
    end
  end

  @doc "The select's keys, in SOURCE ORDER."
  @spec select_keys(binary) :: [atom]
  def select_keys(source), do: source |> select_pairs() |> Enum.map(&elem(&1, 0))

  @doc "The expression AST the select binds to `key`. Raises if the key is gone."
  @spec select_value(binary, atom) :: Macro.t()
  def select_value(source, key) when is_atom(key) do
    case List.keyfind(select_pairs(source), key, 0) do
      {^key, value} ->
        value

      nil ->
        raise "provisioning_fqdn_claim/2's select no longer computes #{inspect(key)}; " <>
                "it computes #{inspect(select_keys(source))}"
    end
  end

  @doc """
  The row fields `claim_leg/2` READS (`row.<field>`), sorted and de-duplicated.
  The other side of the same contract: the select is the producer, these are
  the consumers, and neither list is typed into the assertions.
  """
  @spec leg_row_reads(binary) :: [atom]
  def leg_row_reads(source) when is_binary(source) do
    {_, reads} =
      source
      |> fun_ast(:claim_leg, 2)
      |> Macro.prewalk([], fn
        {{:., _, [{:row, _, ctx}, field]}, _, []} = node, acc
        when is_atom(ctx) and is_atom(field) ->
          {node, [field | acc]}

        node, acc ->
          {node, acc}
      end)

    reads |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  The SQL string and the bound argument expressions of the `fragment/N` the
  select binds to `key`. Arguments come back as source text
  (`Macro.to_string/1`) so a swapped bind (`^sample_cutoff` → `^cutoff`) is
  visible. Raises if `key` is no longer computed by a fragment at all.
  """
  @spec fragment_parts(binary, atom) :: {binary, [binary]}
  def fragment_parts(source, key) do
    case select_value(source, key) do
      {:fragment, _, [sql | args]} when is_binary(sql) ->
        {sql, Enum.map(args, &Macro.to_string/1)}

      other ->
        raise "#{inspect(key)} is no longer computed by a fragment/N: " <> Macro.to_string(other)
    end
  end

  @doc """
  Parse an `EXISTS (SELECT 1 FROM <table> <alias> WHERE <conds>)` fragment into
  its parts: `%{table:, alias:, conjuncts:}`, conjuncts split on ` AND ` in
  source order. Raises on any other shape — including a fragment that stopped
  being an EXISTS probe, which is the loudest possible narrowing.
  """
  @spec exists_shape(binary) :: %{table: binary, alias: binary, conjuncts: [binary]}
  def exists_shape(sql) when is_binary(sql) do
    case Regex.run(~r/^EXISTS \(SELECT 1 FROM (\w+) (\w+) WHERE (.+)\)$/s, sql) do
      [_, table, alias_, conds] ->
        conjuncts = conds |> String.split(" AND ") |> Enum.map(&String.trim/1)

        Enum.each(conjuncts, fn c ->
          if balanced?(c) == false do
            raise "conjunct #{inspect(c)} has unbalanced parens — the ` AND ` split cut " <>
                    "inside a parenthesised expression and this parser must be taught it"
          end
        end)

        %{table: table, alias: alias_, conjuncts: conjuncts}

      nil ->
        raise "not an `EXISTS (SELECT 1 FROM <t> <a> WHERE …)` probe: " <> inspect(sql)
    end
  end

  @doc "How many `?` binds the SQL string carries."
  @spec placeholders(binary) :: non_neg_integer
  def placeholders(sql) when is_binary(sql),
    do: sql |> String.graphemes() |> Enum.count(&(&1 == "?"))

  defp balanced?(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while(0, fn
      "(", n -> {:cont, n + 1}
      ")", 0 -> {:halt, :bad}
      ")", n -> {:cont, n - 1}
      _, n -> {:cont, n}
    end)
    |> case do
      0 -> true
      _ -> false
    end
  end

  ## AST plumbing (same contract as RegistryNameClaimCensus.Extract: `when`
  ## heads are unwrapped, and a missing function RAISES rather than answering
  ## an empty population).

  defp fun_ast(source, name, arity) do
    {_, found} =
      source
      |> Code.string_to_quoted!(emit_warnings: false)
      |> Macro.prewalk(nil, fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] ->
          case head_sig(head) do
            {^name, ^arity} -> {node, body}
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    found || raise "#{name}/#{arity} not found — did it get renamed or deleted?"
  end

  defp head_sig({:when, _, [head | _]}), do: head_sig(head)
  defp head_sig({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp head_sig(_), do: nil
end

defmodule BarkparkCloud.RegistryNameClaimSelectCensusTest do
  @moduledoc """
  The rung below `registry_name_claim_census_test.exs`: a name-claim leg cannot
  be weakened AT ITS SOURCE without something reporting it.

  That file censuses the leg SET, its ORDER and three constants, and its own
  moduledoc names what it cannot see: the `select` in
  `provisioning_fqdn_claim/2` that computes `has_admin_token` /
  `recent_sample` / `live_subscription`. Narrow one of those and every leg
  still exists, so rung 1 is fully green; rung 2 reds only if a behavioural
  fixture happens to violate the new conjunct. This file closes that:

    * THE KEY CENSUS — the select's key list is pinned to an exact allowlist,
      so a renamed or dropped key reds. It is bound at BOTH ends: the second
      arm compares the select's keys against the `row.<field>` reads walked out
      of `claim_leg/2`, so neither list can drift alone and neither is a
      restatement of the other.
    * ONE PIN PER COMPUTED KEY — `has_admin_token`, `active_job`,
      `recent_sample`, `live_subscription`, each in its OWN test, so narrowing
      one reds exactly one assertion instead of shadowing the others (the same
      reason the three constants next door are three tests).

  The EXISTS pins are derived, not re-typed: the fragment is parsed into
  `table` / `alias` / `conjuncts` and the CONJUNCT SET is asserted. Re-typing
  the whole SQL string beside the source would be a tautology that reds on a
  whitespace edit and says nothing about meaning; an added conjunct is exactly
  the narrowing this rung exists to catch.

  ## Controls

  Every arm here reads a real population off the real source (the extractor
  RAISES rather than answering `[]` for a deleted function, select or key), and
  the mutation arms re-run the SAME walk over a mutated COPY of the source, so
  a walk that had stopped reading anything would fail its own control.

  ## Mutations RUN against lib/barkpark_cloud/registry.ex, then reverted

      M1 (a key renamed): `has_admin_token:` → `has_admin_token_x:` in the
      select. "the select computes EXACTLY the keys claim_leg/2 reads" reds
      naming the produced-but-unread and read-but-unproduced keys, and the
      has_admin_token pin reds with "no longer computes :has_admin_token".

      M2 (a key dropped): delete the `active_job:` pair. The key list arm and
      the producer/consumer arm both red; the fragment pins stay green.

      M3 (recent_sample narrowed): append ` AND us.envelope IS NOT NULL` to the
      usage_samples fragment. ONLY the recent_sample pin reds — the
      live_subscription pin, the key census and the whole neighbouring census
      file stay green. That is the independence the criterion asks for.

      M4 (live_subscription narrowed): append ` AND s.canceled_at IS NULL` to
      the subscriptions fragment. ONLY the live_subscription pin reds.

  Exact failure output for each is pasted in the PR that added this file.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.RegistryNameClaimSelectCensus.Extract

  @source Path.expand("../../lib/barkpark_cloud/registry.ex", __DIR__)

  # The select's keys, in source order, each with WHAT IT FEEDS — the sentence
  # a failure prints, because the cost of losing a key is which leg goes blind,
  # not which atom stops existing.
  @keys [
    {:id, "the row id every leg's operator sentence opens with"},
    {:team_id, "the team Billing.entitled?/1 is asked about for :active_subscription"},
    {:last_seen_at, "the :agent_reporting leg — has this agent EVER phoned home"},
    {:inserted_at, "the :within_grace leg — is this row younger than the abandonment window"},
    {:has_admin_token, "the :admin_credential HARD BLOCK — a live decryptable credential"},
    {:active_job, "the :active_job leg — a provision job in flight"},
    {:recent_sample,
     "the :recent_usage_sample HARD BLOCK — an in-flight platform→host transmission"},
    {:live_subscription, "the :active_subscription SQL prefilter — a billed customer's name"}
  ]

  @expected_keys Enum.map(@keys, &elem(&1, 0))

  defp source, do: File.read!(@source)

  ## ─────────────────────────────────────────────────────────────────────────
  ## THE KEY CENSUS
  ## ─────────────────────────────────────────────────────────────────────────

  describe "the select that feeds claim_leg/2" do
    test "computes EXACTLY the eight declared keys, in source order" do
      actual = Extract.select_keys(source())

      assert actual != [], "the walk found NO select keys — the extractor is not reading"

      assert MapSet.new(actual) == MapSet.new(@expected_keys), key_set_message(actual)

      assert actual == @expected_keys,
             """
             the select's keys are the right SET but a different ORDER.

               expected: #{inspect(@expected_keys)}
                 actual: #{inspect(actual)}

             Order is not load-bearing for the query, but a reorder here means
             the projection was rewritten — re-read claim_leg/2 before changing
             this list.
             """
    end

    # Both sides walked, neither typed: the select is the PRODUCER, claim_leg/2
    # is the CONSUMER. A renamed key breaks this even if someone updates only
    # one of the two lists above.
    test "computes exactly the row fields claim_leg/2 READS — no more, no less" do
      produced = Extract.select_keys(source()) |> Enum.sort()
      read = Extract.leg_row_reads(source())

      assert read != [], "the walk found NO `row.<field>` reads in claim_leg/2 — not reading"

      assert produced == read,
             """
             the SELECT and claim_leg/2 disagree about the row shape.

               produced by the select: #{inspect(produced)}
                  read by claim_leg/2: #{inspect(read)}

               produced but never read: #{inspect(produced -- read)}
               read but never produced: #{inspect(read -- produced)}

             A read-but-unproduced key is a KeyError at runtime on the claim
             path — the hostname walk crashes, and the caller sees a 500 where
             a refusal belonged. A produced-but-unread key is a leg that stopped
             consulting its own input.
             """
    end

    # CONTROL for both arms above: the walk reads the SOURCE, not a constant.
    # Rename a key in a copy and the census must move with it.
    test "CONTROL: renaming a key in a copy of the source moves the census" do
      mutated = String.replace(source(), "has_admin_token:", "has_admin_token_x:", global: false)

      refute mutated == source(), "the mutation recipe no longer matches the source"

      keys = Extract.select_keys(mutated)

      assert :has_admin_token_x in keys
      refute :has_admin_token in keys
      refute keys == @expected_keys

      # And the producer/consumer arm sees it too: claim_leg/2 still reads the
      # OLD name, so the two walks part company.
      assert :has_admin_token in Extract.leg_row_reads(mutated)
      refute Enum.sort(keys) == Extract.leg_row_reads(mutated)
    end

    test "CONTROL: a deleted select raises rather than answering an empty population" do
      assert_raise RuntimeError, ~r/no select\/3 inside provisioning_fqdn_claim\/2/, fn ->
        Extract.select_keys(delete_select(source()))
      end
    end
  end

  ## ─────────────────────────────────────────────────────────────────────────
  ## ONE PIN PER COMPUTED KEY — separate tests so a narrowing reds ALONE
  ## ─────────────────────────────────────────────────────────────────────────

  describe "pin: has_admin_token (the :admin_credential hard block)" do
    test "is `not is_nil(b.<field>)` on the encrypted token column and NOTHING else" do
      # Derived from the AST, not re-typed: the top node must be the negation
      # itself. `not is_nil(b.x) and <anything>` parses as `and` at the top and
      # reds here — which is the whole point, since an extra conjunct narrows
      # the hard block without touching a leg.
      assert {:not, _, [{:is_nil, _, [field]}]} = Extract.select_value(source(), :has_admin_token),
             """
             has_admin_token is no longer a bare `not is_nil(...)`:

               #{Macro.to_string(Extract.select_value(source(), :has_admin_token))}

             An added conjunct NARROWS the :admin_credential hard block: rows the
             platform can still decrypt a live admin bearer token for start
             answering false, and their hostnames become claimable by the next
             tenant with every leg still present.
             """

      assert Macro.to_string(field) == "b.admin_token_encrypted",
             "the hard block now reads #{Macro.to_string(field)}, not the encrypted admin token"
    end

    test "CONTROL: adding a conjunct in a copy of the source breaks the shape" do
      mutated =
        String.replace(
          source(),
          "has_admin_token: not is_nil(b.admin_token_encrypted)",
          "has_admin_token: not is_nil(b.admin_token_encrypted) and not is_nil(b.last_seen_at)",
          global: false
        )

      refute mutated == source(), "the mutation recipe no longer matches the source"

      refute match?(
               {:not, _, [{:is_nil, _, [_]}]},
               Extract.select_value(mutated, :has_admin_token)
             )
    end
  end

  describe "pin: active_job" do
    test "is membership in the active-job subquery, by name" do
      value = Extract.select_value(source(), :active_job)

      assert {:in, _, [left, {:subquery, _, [{fun, _, []}]}]} = value,
             "active_job is no longer `b.<id> in subquery(<zero-arity call>)`: " <>
               Macro.to_string(value)

      assert Macro.to_string(left) == "b.id"

      assert fun == :active_job_barkpark_ids,
             "active_job now consults #{fun}/0 — the pending/claimed job population is " <>
               "defined somewhere this census has not read"
    end
  end

  describe "pin: the recent_sample EXISTS fragment (the :recent_usage_sample hard block)" do
    test "probes usage_samples on BOTH conjuncts — the row link and the window" do
      {sql, args} = Extract.fragment_parts(source(), :recent_sample)
      shape = Extract.exists_shape(sql)

      assert shape.table == "usage_samples",
             "the :recent_usage_sample hard block now probes #{shape.table}"

      assert shape.conjuncts == [
               "#{shape.alias}.barkpark_id = ?",
               "#{shape.alias}.measured_at >= ?"
             ],
             """
             the recent_sample EXISTS probe changed shape.

               conjuncts now: #{inspect(shape.conjuncts)}

             Two conjuncts, no more: the row link and the window bound. An ADDED
             conjunct narrows the hard block — rows the usage sampler demonstrably
             reached inside the window stop holding their hostname, and the
             platform hands a name to the next tenant while it is still
             transmitting to the old box. A REMOVED conjunct is the opposite bug
             (every row in the table holds every name).
             """

      # The binds, so a swapped cutoff cannot hide behind an unchanged string.
      assert args == ["b.id", "^sample_cutoff"],
             "the fragment's binds are now #{inspect(args)}"

      assert Extract.placeholders(sql) == length(args),
             "#{Extract.placeholders(sql)} `?` binds in the SQL but #{length(args)} arguments"
    end

    test "CONTROL: an added conjunct in a copy reds HERE and leaves live_subscription alone" do
      mutated =
        String.replace(
          source(),
          "us.measured_at >= ?)",
          "us.measured_at >= ? AND us.envelope IS NOT NULL)",
          global: false
        )

      refute mutated == source(), "the mutation recipe no longer matches the source"

      {sql, _} = Extract.fragment_parts(mutated, :recent_sample)
      assert length(Extract.exists_shape(sql).conjuncts) == 3

      # Independence: the other fragment is untouched by this narrowing.
      assert Extract.fragment_parts(mutated, :live_subscription) ==
               Extract.fragment_parts(source(), :live_subscription)
    end
  end

  describe "pin: the live_subscription EXISTS fragment (the :active_subscription prefilter)" do
    test "probes subscriptions on the team link and the live-status set only" do
      {sql, args} = Extract.fragment_parts(source(), :live_subscription)
      shape = Extract.exists_shape(sql)

      assert shape.table == "subscriptions",
             "the :active_subscription prefilter now probes #{shape.table}"

      assert shape.conjuncts == [
               "#{shape.alias}.team_id = ?",
               "#{shape.alias}.status IN ('active','past_due')"
             ],
             """
             the live_subscription EXISTS probe changed shape.

               conjuncts now: #{inspect(shape.conjuncts)}

             This fragment is the NECESSARY half of the :active_subscription leg
             (Billing.entitled?/1 is the sufficient half). An added conjunct
             narrows it, and because it is the SQL prefilter the Elixir half
             never even runs for the rows it excludes — a paying customer's
             hostname is released with the leg, the constant and the entitlement
             check all still in place.
             """

      assert args == ["b.team_id"], "the fragment's binds are now #{inspect(args)}"

      assert Extract.placeholders(sql) == length(args),
             "#{Extract.placeholders(sql)} `?` binds in the SQL but #{length(args)} arguments"
    end

    test "CONTROL: an added conjunct in a copy reds HERE and leaves recent_sample alone" do
      mutated =
        String.replace(
          source(),
          "s.status IN ('active','past_due'))",
          "s.status IN ('active','past_due') AND s.canceled_at IS NULL)",
          global: false
        )

      refute mutated == source(), "the mutation recipe no longer matches the source"

      {sql, _} = Extract.fragment_parts(mutated, :live_subscription)
      assert length(Extract.exists_shape(sql).conjuncts) == 3

      assert Extract.fragment_parts(mutated, :recent_sample) ==
               Extract.fragment_parts(source(), :recent_sample)
    end

    test "CONTROL: a fragment that stops being an EXISTS probe raises, it does not pass" do
      assert_raise RuntimeError, ~r/not an `EXISTS/, fn ->
        Extract.exists_shape("SELECT 1 FROM subscriptions s WHERE s.team_id = ?")
      end
    end
  end

  ## Failure copy

  defp key_set_message(actual) do
    missing = @expected_keys -- actual
    added = actual -- @expected_keys

    """
    the SELECT feeding claim_leg/2 has a different KEY SET.

    #{blinded(missing)}#{unreviewed(added)}
      expected: #{inspect(@expected_keys)}
        actual: #{inspect(actual)}

    A key renamed or dropped here blinds a leg at its SOURCE. The leg census
    next door (registry_name_claim_census_test.exs) stays green for that edit —
    the atom is still written — so this list is the only thing that reports it.
    If the change is intended, change @keys here in the same commit and say in
    the message which leg you are re-wiring.
    """
  end

  defp blinded([]), do: ""

  defp blinded(missing) do
    lines =
      Enum.map_join(missing, "\n", fn key ->
        "      * #{inspect(key)} — fed #{Keyword.fetch!(@keys, key)}"
      end)

    "    KEYS GONE — what stops reaching claim_leg/2:\n#{lines}\n\n"
  end

  defp unreviewed([]), do: ""

  defp unreviewed(added), do: "    KEYS ADDED, unreviewed by this census: #{inspect(added)}\n\n"

  # Remove the whole `|> select([b], %{…})` call, for the empty-population
  # control. Cuts from the pipe to the line that closes the map.
  defp delete_select(source) do
    [before, rest] = String.split(source, "|> select([b], %{", parts: 2)
    [_dropped, after_] = String.split(rest, "\n    })\n", parts: 2)
    before <> "|> exclude([b], :select)\n    " <> after_
  end
end
