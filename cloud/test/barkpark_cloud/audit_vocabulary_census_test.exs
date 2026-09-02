defmodule BarkparkCloud.AuditVocabularyCensusTest do
  @moduledoc """
  cch-w51-s4 — a BIDIRECTIONAL CENSUS over the audit register's verb vocabulary.

  Two obligations, one file:

    * ARM (a) DECLARED → PRODUCED. Every verb the closed `AuditEvent.actions/0`
      allowlist declares must have a producer somewhere in `cloud/lib`, or be
      named — individually, with a rationale — in `@producerless`.
    * ARM (b) PRODUCED → DECLARED. Every action any producer writes must be in
      the allowlist. A verb that is not is a `validate_inclusion` changeset
      error at runtime: the call site believes it wrote an audit row and no row
      exists. That is exactly how `site.rolled_back` shipped (slice
      cch-w51-s3) — nothing in this repo compared the two sides.
    * ARM (c) PRODUCED-SOMEWHERE → PRODUCED-ON-EVERY-LANE, for the ONE verb
      whose lanes this census got caught not seeing. Arms (a) and (b) are
      SET arms: they compare two sets of verbs and are satisfied by a single
      producer anywhere in `cloud/lib`. A verb with two lanes — two different
      code paths that perform the same act — therefore reads GREEN when only
      one of them writes. That is not hypothetical: `barkpark.deleted` was
      produced by the router's NON-live `DELETE /v1/barkparks/:id` arm and by
      nothing on the LIVE deprovision lane, where every box that actually RAN
      is deleted (`Registry.succeed_deprovision_job/2`). Both arms were green
      the whole time, and the console's append-only audit list recorded the
      removal of every box that never ran and none that did (cch-w57).

  ## Why a naive grep is WORSE THAN NOTHING here

  `grep -rhoE 'action: "[a-z0-9_.]+"' cloud/lib` finds 37 literals and would
  miscount in BOTH directions:

    * ONE of the 37 is a FALSE PRODUCER: `action: "advance"` in router.ex is
      prose inside the comment
      `# POST /v1/onboarding {action: "advance"|"ack"|"complete"|"skip", step?}`.
      Un-stripped, arm (b) reds on a verb nobody writes.
    * SEVENTEEN declared verbs are produced through THREE INDIRECTION LAYERS and
      would be reported as zero-producer:
        - `instance_mutation_action/1` mints the six `webhook.*` verbs;
        - `audit_lifecycle_trigger/5` is called with nine `barkpark.*` verbs;
        - `audit_account_security/2` is called with the two `twofa.*` verbs.
      A literals-only guard reports TWENTY-ONE false zero-producers.

  So the census resolves all three layers EXPLICITLY and puts a floor on each
  (`@webhook_layer_size`, `@lifecycle_layer_size`, `@account_security_layer_size`):
  renaming a helper reds the floor instead of silently reopening the miscount.

  The "there is no FURTHER layer" claim is not left as prose either — the last
  test enumerates every non-literal `action:` binding in `cloud/lib` and fails
  on any form not already accounted for. A new indirection helper must either be
  resolved here or be declared inert.

  ## Limits, stated so nobody over-reads a green run

    * It proves a verb HAS a producer, not that the producer is REACHABLE or
      that the row is actually persisted. `Accounts.record_audit/1` errors are
      discarded at 8 of 12 call sites — filed separately as
      `cch-w51-bl-record-audit-errors-are-discarded-at-every-call-site`.
    * It is a SOURCE scan, not a call graph: dead code counts as a producer.
    * ARM (c) IS ONE VERB WIDE, ON PURPOSE, AND THAT IS A LIMIT NOT A DESIGN.
      It pins the lanes of `barkpark.deleted` because that is the pair a wave
      actually found broken. Every OTHER verb in the vocabulary is still held
      to arm (a)'s one-producer-anywhere standard, so a second verb losing a
      second lane would be as invisible tomorrow as this one was yesterday.
      The general shape — enumerate each DESTRUCTIVE call site in `cloud/lib`
      and require an audit producer in its transaction — is a bigger
      instrument than this file, and it is not claimed here.
    * It says nothing about whether a produced action is LABELLED in the
      console. Charter D582 ruled the unlabelled verbs UGLY, NOT FALSE —
      `humanAction(a) { return ACTION_LABELS[a] || a; }` is a documented
      raw-slug fallback that renders them.
    * Global fleet controls (autoupdate halt / resume / channel patch) write no
      audit row at all. They cannot without a migration —
      `audit_events.team_id` is `null: false` and those levers are teamless —
      and `cloud-console-operator-audit-log` owns that design question. Not
      claimed here.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Accounts.AuditEvent

  @lib_root Path.expand("../../lib", __DIR__)
  @router Path.join(@lib_root, "barkpark_cloud/web/router.ex")

  # Floors. A broken extractor must RED, not report a clean tree.
  @declared_floor 50
  @produced_floor 35
  @webhook_layer_size 6
  @lifecycle_layer_size 10
  @account_security_layer_size 2

  # Declared verbs with NO producer anywhere in cloud/lib. Named one by one,
  # never a wildcard: a THIRD zero-producer verb reds this census.
  #
  # EVERY ENTRY IS MECHANICAL, NOT PROSE — cch-w53-s3, and this is the whole
  # point of the shape. Wave 51 shipped this map with FOUR entries whose values
  # were INERT STRINGS: every read of @producerless was `Map.keys/1`, so no
  # assertion ever touched a value. Three of the four were FALSE on the same
  # tree ("2FA enrolment seam is unbuilt — no TOTP enable route exists yet."
  # while `post "/v1/account/two-factor/confirm"` WAS the enable moment), and
  # rewriting one to a deliberate falsehood left the suite green at 11/0. An
  # allowlist entry with a written reason is strictly worse than a bare name: a
  # bare name is an unexplained absence, an excused name is an absence somebody
  # CERTIFIED as intended.
  #
  # So each entry now carries two regexes this census runs against cloud/lib:
  #
  #   * `anchor` — MUST match at least one CODE line. It pins the live code the
  #     rationale is talking about. This is the arm that would have caught wave
  #     51: you cannot write "no such route exists yet" any more, because the
  #     entry has to name the code it is reasoning about and that name has to
  #     resolve.
  #   * `blocker_absent` — MUST match zero code lines. It is the thing whose
  #     ABSENCE is the real reason the verb is unproduced. The day a slice lands
  #     it, this census reds and the rationale has to be re-argued or the verb
  #     produced.
  #
  # WHAT THIS STILL DOES NOT PROVE (say it, or the next surveyor over-reads a
  # green run): a regex pair proves the cited code exists and the cited blocker
  # does not. It does not prove the SENTENCE is a good reason. It catches decay
  # and fabrication, which is exactly the pair of failures wave 51 shipped.
  @producerless %{
    "oauth.linked" => %{
      reason:
        "NOT unbuilt — the OAuth callback (router.ex, `/v1/auth/oauth/:provider/callback`) " <>
          "really does link identities: Accounts.get_or_create_user_from_oauth/1 -> " <>
          "birth_or_link_oauth/3 -> link_external_identity/2 inserts a durable " <>
          "external_identities row. It is unproduced because the callback cannot tell a LINK " <>
          "from a BIRTH: get_or_create_user_from_oauth/1 returns a bare {:ok, user}, so a " <>
          "producer there would stamp oauth.linked on first-ever signups too. Producing it " <>
          "honestly needs a branch-reporting return — " <>
          "cch-w53-bl-oauth-linked-needs-a-branch-reporting-return.",
      anchor: ~r/link_external_identity/,
      blocker_absent: ~r/:linked\b/
    },
    "email.verified" => %{
      reason:
        "NOT unbuilt — `post \"/v1/auth/verify-email\"` exists and is reachable, and " <>
          "Accounts.confirm_user/1 behind it sets confirmed_at. Exactly ONE half of the wave-51 " <>
          "rationale was true: nothing on that path writes an audit row. Wiring one is a " <>
          "call-site change, not a seam.",
      anchor: ~r{"/v1/auth/verify-email"},
      blocker_absent: ~r/action:\s*"email\.verified"/
    }
  }

  # Every NON-LITERAL `action:` binding in cloud/lib, keyed by its trimmed source
  # line, with what it is. This is what makes "there is no third indirection
  # layer" a guard rather than a sentence: a new `action: some_helper(x)` line
  # reds until someone either resolves it into PRODUCED or declares it inert.
  @accounted_indirection %{
    "action: action," =>
      "the own parameter of BOTH call-site-keyed helpers (audit_lifecycle_trigger/5 and " <>
        "audit_account_security/2) — resolved by the lifecycle and account-security layers below.",
    "action: instance_mutation_action(cap)," =>
      "the webhook layer — resolved by instance_mutation_action/1 below.",
    "action: e.action," =>
      "renders a STORED event back out to the console; a reader, not a producer.",
    "{:error, %{changeset | action: :validate}}" =>
      "Ecto.Changeset.action (:validate/:update/:insert), unrelated to the audit vocabulary.",
    "{:error, %{changeset | action: :update}}" =>
      "Ecto.Changeset.action (:validate/:update/:insert), unrelated to the audit vocabulary."
  }

  # `action:` as a whole key, so `censored_fraction:` does not match.
  @action_key ~r/(?<![A-Za-z0-9_])action:/
  @action_literal ~r/(?<![A-Za-z0-9_])action:\s*"([a-z0-9_.]+)"/

  # ── source reading ────────────────────────────────────────────────────────

  defp lib_files, do: Path.wildcard(Path.join(@lib_root, "**/*.ex"))

  @doc false
  # Drops `#` comments and heredoc bodies, leaving code. A `#` inside a string
  # literal is NOT a comment; `?#` is a character literal, not a comment.
  def strip_comments(source) do
    source
    |> String.split("\n")
    |> Enum.map_reduce(false, fn line, in_heredoc? ->
      cond do
        in_heredoc? -> {"", String.contains?(line, ~s(""")) == false}
        odd_heredoc_marker?(line) -> {strip_line(hd(String.split(line, ~s(""")))), true}
        true -> {strip_line(line), false}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  defp odd_heredoc_marker?(line) do
    line |> String.split(~s(""")) |> length() |> Kernel.-(1) |> rem(2) == 1
  end

  defp strip_line(line), do: strip_line(String.graphemes(line), false, [])

  defp strip_line([], _in_string?, acc), do: acc |> Enum.reverse() |> Enum.join()

  defp strip_line(["\\", c | rest], true, acc), do: strip_line(rest, true, [c, "\\" | acc])

  defp strip_line(["\"" | rest], in_string?, acc),
    do: strip_line(rest, not in_string?, ["\"" | acc])

  defp strip_line(["?", "#" | rest], false, acc), do: strip_line(rest, false, ["#", "?" | acc])
  defp strip_line(["#" | _rest], false, acc), do: strip_line([], false, acc)
  defp strip_line([c | rest], in_string?, acc), do: strip_line(rest, in_string?, [c | acc])

  defp code_lines(path) do
    path |> File.read!() |> strip_comments() |> String.split("\n")
  end

  # ── the two sides ─────────────────────────────────────────────────────────

  defp declared, do: MapSet.new(AuditEvent.actions())

  defp literal_producers do
    for path <- lib_files(),
        line <- code_lines(path),
        [_, verb] <- Regex.scan(@action_literal, line),
        into: MapSet.new(),
        do: verb
  end

  # LAYER 1 — `defp instance_mutation_action(:"webhook.create"), do: "webhook.created"`.
  # The atoms are QUOTED; a pattern expecting bare atoms matches zero and
  # undercounts the census by six.
  defp webhook_layer do
    for line <- code_lines(@router),
        [_, verb] <-
          Regex.scan(
            ~r/instance_mutation_action\(:"[a-z0-9_.]+"\),\s*do:\s*"([a-z0-9_.]+)"/,
            line
          ),
        into: MapSet.new(),
        do: verb
  end

  # LAYER 2 — nine call sites of `audit_lifecycle_trigger(conn, team, id, "barkpark.x", %{…})`.
  # The definition line carries no string literal, so it cannot self-satisfy.
  defp lifecycle_layer do
    for line <- code_lines(@router),
        [_, verb] <- Regex.scan(~r/audit_lifecycle_trigger\([^"]*"([a-z0-9_.]+)"/, line),
        into: MapSet.new(),
        do: verb
  end

  # LAYER 3 — `audit_account_security(conn, "twofa.enabled")` (cch-w53-s3). Like
  # layer 2 the verb lives at the CALL site, not the definition, so the `action:`
  # binding inside the helper is the bare parameter `action`. Without this the
  # two 2FA verbs read as zero-producer while their producers sit ten lines from
  # the routes — which is precisely how this layer announced itself: it reds arm
  # (a) the moment it is added and not resolved.
  defp account_security_layer do
    for line <- code_lines(@router),
        [_, verb] <- Regex.scan(~r/audit_account_security\([^"]*"([a-z0-9_.]+)"/, line),
        into: MapSet.new(),
        do: verb
  end

  defp produced do
    literal_producers()
    |> MapSet.union(webhook_layer())
    |> MapSet.union(lifecycle_layer())
    |> MapSet.union(account_security_layer())
  end

  defp sorted(set), do: set |> MapSet.to_list() |> Enum.sort()

  # ARM (c)'s reader: which FILES under cloud/lib literally write `verb`.
  # Comments and heredocs are stripped first (`code_lines/1`), so a doc comment
  # naming the verb can never stand in for a producer — which matters here more
  # than anywhere else in this file, because both lanes' source is thick with
  # prose about the other one.
  defp producer_files(verb) do
    for path <- lib_files(),
        line <- code_lines(path),
        [_, found] <- Regex.scan(@action_literal, line),
        found == verb,
        uniq: true,
        into: MapSet.new(),
        do: Path.relative_to(path, @lib_root)
  end

  # Every CODE line in cloud/lib matching `regex`, as "<relpath>: <line>".
  # Comments and heredocs are stripped first, so an anchor must resolve in code
  # — a rationale cannot be satisfied by a comment repeating its own claim.
  defp lib_lines_matching(regex) do
    for path <- lib_files(),
        line <- code_lines(path),
        Regex.match?(regex, line),
        do: "#{Path.relative_to(path, @lib_root)}: #{String.trim(line)}"
  end

  # ── the census ────────────────────────────────────────────────────────────

  describe "floors (a broken extractor must red, not report a clean tree)" do
    test "the declared vocabulary is still large" do
      assert MapSet.size(declared()) >= @declared_floor,
             "AuditEvent.actions/0 returned #{MapSet.size(declared())} verbs, below the floor " <>
               "of #{@declared_floor}. Either the vocabulary was gutted or the accessor changed " <>
               "shape — either way both arms below have gone vacuous."
    end

    test "the producer scan still finds producers" do
      assert MapSet.size(produced()) >= @produced_floor,
             "The producer scan found only #{MapSet.size(produced())} actions, below the floor " <>
               "of #{@produced_floor}. The extractor (comment/heredoc stripping, the `action:` " <>
               "regex, or the lib path #{@lib_root}) is broken — arm (a) would now report the " <>
               "whole vocabulary as unproduced."
    end

    test "the webhook indirection layer resolves to exactly #{@webhook_layer_size} verbs" do
      layer = webhook_layer()

      assert MapSet.size(layer) == @webhook_layer_size,
             """
             instance_mutation_action/1 resolved to #{MapSet.size(layer)} verbs, expected #{@webhook_layer_size}:

                 #{inspect(sorted(layer))}

             If the helper was renamed or its clauses reshaped, resolve it here — do NOT delete
             this floor. Without it the six webhook.* verbs silently reappear as unproduced.
             """

      assert Enum.all?(layer, &String.starts_with?(&1, "webhook.")),
             "instance_mutation_action/1 now mints non-webhook verbs: #{inspect(sorted(layer))}"
    end

    test "the account-security layer resolves to exactly #{@account_security_layer_size} verbs" do
      layer = account_security_layer()

      assert MapSet.size(layer) == @account_security_layer_size,
             """
             audit_account_security/2 resolved to #{MapSet.size(layer)} verbs, expected #{@account_security_layer_size}:

                 #{inspect(sorted(layer))}

             Deleting a call reds HERE rather than quietly reopening the wave-51 hole, where
             both twofa verbs were declared with no producer and excused by a rationale that
             claimed the routes did not exist.
             """

      assert Enum.all?(layer, &String.starts_with?(&1, "twofa.")),
             "audit_account_security/2 now mints non-twofa verbs: #{inspect(sorted(layer))}. " <>
               "Widen the helper's name or this floor, but do not leave the census guessing."
    end

    test "the lifecycle indirection layer resolves to exactly #{@lifecycle_layer_size} verbs" do
      layer = lifecycle_layer()

      assert MapSet.size(layer) == @lifecycle_layer_size,
             """
             audit_lifecycle_trigger/5 resolved to #{MapSet.size(layer)} verbs, expected #{@lifecycle_layer_size}:

                 #{inspect(sorted(layer))}

             A rename of the helper resolves ZERO and reds HERE, which is the point: otherwise
             the ten barkpark.* verbs would silently appear as zero-producer in arm (a).
             """

      assert Enum.all?(layer, &String.starts_with?(&1, "barkpark.")),
             "audit_lifecycle_trigger/5 now mints non-barkpark verbs: #{inspect(sorted(layer))}"
    end

    # cch-w63-s8 — THE HOLE THE THREE LAYER SIZES ABOVE CANNOT SEE.
    #
    # Each layer size counts DISTINCT VERBS RESOLVED. That reds when someone
    # CONVERTS an existing literal call site to a non-literal — the count drops.
    # It does NOT red when someone ADDS a call site whose verb is a module
    # attribute, a variable or a function call: the resolved set is unchanged, the
    # size still matches, and a verb nobody can see is now being written (or, far
    # likelier, rejected by `validate_inclusion` at runtime while every arm here
    # reports a clean tree — the 0-failures-over-a-broken-producer shape).
    #
    # So count ARITY, not verbs: every call site of a call-site-keyed helper must
    # carry a quoted verb. Equality in both directions — a call site that stops
    # carrying one reds, and a regex that stops matching reds too rather than
    # comparing 0 to 0. The `defp` definition line is excluded by requiring the
    # helper name NOT to be preceded by `defp `.
    for {helper, arity_label} <- [
          {"audit_lifecycle_trigger", "audit_lifecycle_trigger/5"},
          {"audit_account_security", "audit_account_security/2"}
        ] do
      test "every #{arity_label} CALL SITE carries a quoted verb (arity, not verb count)" do
        name = unquote(helper)
        call = Regex.compile!("(?<!defp )" <> Regex.escape(name) <> "\\(")

        with_literal =
          Regex.compile!("(?<!defp )" <> Regex.escape(name) <> "\\([^\"]*\"[a-z0-9_.]+\"")

        calls = for line <- code_lines(@router), Regex.match?(call, line), do: String.trim(line)

        literal =
          for line <- code_lines(@router), Regex.match?(with_literal, line), do: String.trim(line)

        assert calls != [],
               "#{unquote(arity_label)} has no call sites at all in router.ex — the helper was " <>
                 "renamed or removed, and this arm is comparing 0 to 0. Re-point it."

        assert length(calls) == length(literal),
               """
               #{unquote(arity_label)} has #{length(calls)} call sites but only #{length(literal)}
               carry a QUOTED verb. These do not:

                   #{Enum.map_join(calls -- literal, "\n    ", & &1)}

               A call site whose verb is a module attribute, a variable or a function call is
               invisible to EVERY arm of this census at once — the layer regex above needs the
               quoted verb at the call site, so the resolved set (and its size) is unchanged and
               nothing reds. Meanwhile `validate_inclusion` decides at runtime whether the row
               exists. Pass the verb as a literal, or resolve the new form here explicitly.
               """
      end
    end
  end

  describe "the comment stripper (without it, prose invents a producer)" do
    test "a commented action: literal is not a producer" do
      refute MapSet.member?(produced(), "advance"),
             ~s(`action: "advance"` is prose inside router.ex's `# POST /v1/onboarding` comment. ) <>
               "It is being counted as a producer, so the stripper is not running."

      comment = ~S[  # POST /v1/onboarding {action: "advance"|"ack"|"complete"|"skip", step?}]

      assert String.trim(strip_comments(comment)) == "",
             "strip_comments/1 no longer removes a whole-line comment."
    end

    test "a `#` inside a string literal is not a comment" do
      line = ~S[    Accounts.record_audit(%{action: "site.created", note: "a # sign"})]

      assert Regex.scan(@action_literal, strip_comments(line)) == [
               [~s(action: "site.created"), "site.created"]
             ],
             "strip_comments/1 over-strips: a `#` inside a string killed a real producer."
    end

    test "a heredoc body is not code" do
      source = ~s(@moduledoc """\naction: "site.ghosted"\n"""\naction: "site.created")

      assert Regex.scan(@action_literal, strip_comments(source)) == [
               [~s(action: "site.created"), "site.created"]
             ],
             "strip_comments/1 does not drop heredoc bodies — documentation prose is being " <>
               "counted as a producer."
    end
  end

  describe "ARM (a) — every DECLARED verb has a producer" do
    test "no declared verb is silently unproduced" do
      unproduced =
        declared()
        |> MapSet.difference(produced())
        |> MapSet.difference(MapSet.new(Map.keys(@producerless)))
        |> sorted()

      assert unproduced == [],
             """
             These verbs are DECLARED in AuditEvent.actions/0 but nothing in cloud/lib produces them:

                 #{inspect(unproduced)}

             A declared verb with no producer is a promise the audit trail cannot keep: the console
             groups by noun and a reader assumes the category is covered.

             Either wire the call site, or — if the verb genuinely cannot be produced yet — add
             it to @producerless in this file BY NAME with a reason AND both predicates (an
             `anchor` that must resolve in cloud/lib, a `blocker_absent` that must not), then
             file the follow-up. Never a wildcard, and never a bare sentence: an allowlist that
             matches a prefix is a sentence with an exit code, and a prose rationale nothing
             reads is a sentence with no exit code at all.
             """
    end

    test "the @producerless allowlist is honest — no stale entries" do
      undeclared =
        @producerless |> Map.keys() |> Enum.reject(&MapSet.member?(declared(), &1)) |> Enum.sort()

      assert undeclared == [],
             "@producerless names verbs that are no longer declared at all: #{inspect(undeclared)}. " <>
               "Delete them — they are excusing nothing."

      now_produced =
        @producerless |> Map.keys() |> Enum.filter(&MapSet.member?(produced(), &1)) |> Enum.sort()

      assert now_produced == [],
             "These verbs now HAVE producers and no longer need excusing: #{inspect(now_produced)}. " <>
               "Delete their @producerless entries so the next zero-producer verb still reds."
    end
  end

  # THE ARM WAVE 51 DID NOT HAVE. Its @producerless values were read by nothing
  # — `Map.keys/1` at three sites and no more — so three false rationales rode
  # a green suite. These three tests are the assertions that CONSUME the values.
  describe "the @producerless rationales are FALSIFIABLE, not prose" do
    test "every entry is fully shaped — a reason plus both predicates" do
      malformed =
        for {verb, entry} <- @producerless,
            not (is_map(entry) and is_binary(entry[:reason]) and entry[:reason] != "" and
                   is_struct(entry[:anchor], Regex) and is_struct(entry[:blocker_absent], Regex)),
            do: verb

      assert Enum.sort(malformed) == [],
             """
             These @producerless entries are not machine-checkable: #{inspect(Enum.sort(malformed))}

             An entry is %{reason: <non-empty string>, anchor: <Regex>, blocker_absent: <Regex>}.
             A bare string is what wave 51 shipped, and a bare string is read by nothing.
             """
    end

    test "every entry's ANCHOR still resolves in cloud/lib" do
      dangling =
        for {verb, %{anchor: anchor}} <- @producerless,
            lib_lines_matching(anchor) == [],
            do: "#{verb} -> #{inspect(anchor)}"

      assert Enum.sort(dangling) == [],
             """
             These @producerless rationales cite code that does not exist in cloud/lib:

                 #{Enum.map_join(Enum.sort(dangling), "\n    ", & &1)}

             Either the code was renamed (fix the anchor) or the rationale is FABRICATED — the
             wave-51 failure mode, where three entries claimed a route was unbuilt while the
             route sat on the same tree. An excuse that cannot point at the code it excuses is
             not an excuse.
             """
    end

    test "every entry's BLOCKER is still absent from cloud/lib" do
      landed =
        for {verb, %{blocker_absent: blocker}} <- @producerless,
            hits = lib_lines_matching(blocker),
            hits != [],
            do:
              "#{verb} -> #{inspect(blocker)} now matches:\n        #{Enum.join(hits, "\n        ")}"

      assert Enum.sort(landed) == [],
             """
             The reason these verbs are unproduced has EXPIRED — the blocker each rationale
             names is now present in cloud/lib:

                 #{Enum.map_join(Enum.sort(landed), "\n    ", & &1)}

             This is the census WINNING, not breaking. Produce the verb and delete its
             @producerless entry, or — if the blocker is still real in a form this regex does
             not describe — restate the rationale and re-pin the predicate.
             """
    end
  end

  describe "ARM (b) — every PRODUCED action is declared" do
    test "no producer writes an action the changeset would reject" do
      undeclared = produced() |> MapSet.difference(declared()) |> sorted()

      assert undeclared == [],
             """
             These actions are written by a producer in cloud/lib but are NOT in
             AuditEvent.actions/0:

                 #{inspect(undeclared)}

             `changeset/2` runs `validate_inclusion(:action, @actions)`, so each of these is an
             {:error, changeset} at runtime — and record_audit's result is discarded at most call
             sites. The call site believes it wrote an audit row; no row exists. This is exactly
             how `site.rolled_back` shipped.

             Add the verb to @actions in cloud/lib/barkpark_cloud/accounts/audit_event.ex.
             """
    end
  end

  describe "THE THIRD-LAYER GUARD — no unaccounted indirection" do
    test "every non-literal `action:` binding in cloud/lib is accounted for" do
      unaccounted =
        for path <- lib_files(),
            line <- code_lines(path),
            Regex.match?(@action_key, line),
            not Regex.match?(@action_literal, line),
            trimmed = String.trim(line),
            not Map.has_key?(@accounted_indirection, trimmed),
            uniq: true,
            do: "#{Path.relative_to(path, @lib_root)}: #{trimmed}"

      assert Enum.sort(unaccounted) == [],
             """
             These lines bind `action:` to something other than a string literal, and this census
             does not know what they resolve to:

                 #{Enum.map_join(Enum.sort(unaccounted), "\n    ", & &1)}

             This is THE assumption the @producerless residue rests on — that the three layers
             resolved above (instance_mutation_action/1, audit_lifecycle_trigger/5,
             audit_account_security/2) are the ONLY indirection. A FOURTH would make arm (a)
             report verbs as unproduced that are produced.

             Resolve the new layer into `produced/0` above, or — if it is inert (a reader, an
             Ecto.Changeset.action, a parameter) — add its trimmed line to @accounted_indirection
             with a one-line reason.
             """
    end
  end

  # THE LANE ARM (cch-w57). Arms (a) and (b) compare SETS OF VERBS, so both were
  # green while the only lane that deletes a box that actually ran wrote nothing.
  # This arm asks a different question of one verb: not "does it have a
  # producer", but "does EACH LANE THAT PERFORMS THE ACT have one".
  describe "ARM (c) — barkpark.deleted is produced on BOTH lanes that delete the row" do
    @deleted_lanes %{
      "barkpark_cloud/web/router.ex" =>
        "the NON-LIVE arm of DELETE /v1/barkparks/:id — a box that never came up, " <>
          "removed inside Accounts.audit/3.",
      "barkpark_cloud/registry.ex" =>
        "the LIVE lane — succeed_deprovision_job/2 deletes the row the deprovision " <>
          "worker just tore the real box out from under, and stamps the verb in the " <>
          "SAME transaction."
    }

    test "both lanes produce the verb" do
      produced_on = producer_files("barkpark.deleted")
      missing = Enum.reject(Map.keys(@deleted_lanes), &MapSet.member?(produced_on, &1))

      assert missing == [],
             """
             These lanes delete a barkpark row and no longer write `barkpark.deleted`:

                 #{Enum.map_join(Enum.sort(missing), "\n    ", &"#{&1} — #{@deleted_lanes[&1]}")}

             Arms (a) and (b) CANNOT see this: they are satisfied by one producer anywhere in
             cloud/lib, and the other lane still has one. That is exactly the blackout wave 57
             found — the audit list showed the removal of every box that never ran and was
             silent about every box that did.

             If a lane genuinely stopped deleting rows, remove its entry here WITH the diff that
             removed the delete. Do not remove it to make this green.
             """
    end

    test "the arm can lose — a verb produced on only one lane is DETECTED, not waved through" do
      # NON-VACUITY. `producer_files/1` must actually discriminate, or the test
      # above passes because the reader returns everything (or nothing useful).
      files = producer_files("barkpark.deleted")

      assert MapSet.size(files) >= 2,
             "barkpark.deleted resolves to #{MapSet.size(files)} producer file(s): " <>
               "#{inspect(sorted(files))}. The lane arm above needs at least the two."

      refute MapSet.member?(producer_files("barkpark.go_live"), "barkpark_cloud/registry.ex"),
             "producer_files/1 reports registry.ex as a producer of barkpark.go_live, which it " <>
               "is not — the reader is matching something other than the verb, and the arm " <>
               "above would pass for any pair of files."

      assert MapSet.size(producer_files("no.such_verb")) == 0,
             "producer_files/1 found a producer for a verb that does not exist."
    end
  end
end
