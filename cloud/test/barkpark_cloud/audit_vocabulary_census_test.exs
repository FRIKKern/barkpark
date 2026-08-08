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

  ## Why a naive grep is WORSE THAN NOTHING here

  `grep -rhoE 'action: "[a-z0-9_.]+"' cloud/lib` finds 37 literals and would
  miscount in BOTH directions:

    * ONE of the 37 is a FALSE PRODUCER: `action: "advance"` in router.ex is
      prose inside the comment
      `# POST /v1/onboarding {action: "advance"|"ack"|"complete"|"skip", step?}`.
      Un-stripped, arm (b) reds on a verb nobody writes.
    * FIFTEEN declared verbs are produced through TWO INDIRECTION LAYERS and
      would be reported as zero-producer:
        - `instance_mutation_action/1` mints the six `webhook.*` verbs;
        - `audit_lifecycle_trigger/5` is called with nine `barkpark.*` verbs.
      A literals-only guard reports NINETEEN false zero-producers.

  So the census resolves both layers EXPLICITLY and puts a floor on each
  (`@webhook_layer_size`, `@lifecycle_layer_size`): renaming either helper reds
  the floor instead of silently reopening the miscount.

  The "there is no THIRD layer" claim is not left as prose either — the last
  test enumerates every non-literal `action:` binding in `cloud/lib` and fails
  on any form not already accounted for. A new indirection helper must either be
  resolved here or be declared inert.

  ## Limits, stated so nobody over-reads a green run

    * It proves a verb HAS a producer, not that the producer is REACHABLE or
      that the row is actually persisted. `Accounts.record_audit/1` errors are
      discarded at 8 of 12 call sites — filed separately as
      `cch-w51-bl-record-audit-errors-are-discarded-at-every-call-site`.
    * It is a SOURCE scan, not a call graph: dead code counts as a producer.
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
  @lifecycle_layer_size 9

  # Declared verbs with NO producer anywhere in cloud/lib. Named one by one,
  # never a wildcard: a fifth zero-producer verb reds this census. All four are
  # reserved-for-a-future-seam verbs from PR #680 and are covered by
  # `cch-w51-bl-two-factor-and-identity-changes-leave-no-audit-trail`.
  @producerless %{
    "twofa.enabled" => "2FA enrolment seam is unbuilt — no TOTP enable route exists yet.",
    "twofa.disabled" => "2FA removal seam is unbuilt — no TOTP disable route exists yet.",
    "oauth.linked" => "SSO identity-linking seam is unbuilt — no OAuth link route exists yet.",
    "email.verified" => "Email-verification seam is unbuilt — confirmation writes no audit row."
  }

  # Every NON-LITERAL `action:` binding in cloud/lib, keyed by its trimmed source
  # line, with what it is. This is what makes "there is no third indirection
  # layer" a guard rather than a sentence: a new `action: some_helper(x)` line
  # reds until someone either resolves it into PRODUCED or declares it inert.
  @accounted_indirection %{
    "action: action," =>
      "audit_lifecycle_trigger/5's own parameter — resolved by the lifecycle layer below.",
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

  defp produced do
    literal_producers()
    |> MapSet.union(webhook_layer())
    |> MapSet.union(lifecycle_layer())
  end

  defp sorted(set), do: set |> MapSet.to_list() |> Enum.sort()

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

    test "the lifecycle indirection layer resolves to exactly #{@lifecycle_layer_size} verbs" do
      layer = lifecycle_layer()

      assert MapSet.size(layer) == @lifecycle_layer_size,
             """
             audit_lifecycle_trigger/5 resolved to #{MapSet.size(layer)} verbs, expected #{@lifecycle_layer_size}:

                 #{inspect(sorted(layer))}

             A rename of the helper resolves ZERO and reds HERE, which is the point: otherwise
             the nine barkpark.* verbs would silently appear as zero-producer in arm (a).
             """

      assert Enum.all?(layer, &String.starts_with?(&1, "barkpark.")),
             "audit_lifecycle_trigger/5 now mints non-barkpark verbs: #{inspect(sorted(layer))}"
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

             Either wire the call site, or — if the seam is genuinely unbuilt — add the verb to
             @producerless in this file BY NAME with a rationale and file the follow-up. Never a
             wildcard: an allowlist that matches a prefix is a sentence with an exit code.
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

             This is THE assumption the four-verb @producerless residue rests on — that
             instance_mutation_action/1 and audit_lifecycle_trigger/5 are the ONLY indirection
             layers. A third one would make arm (a) report verbs as unproduced that are produced.

             Resolve the new layer into `produced/0` above, or — if it is inert (a reader, an
             Ecto.Changeset.action, a parameter) — add its trimmed line to @accounted_indirection
             with a one-line reason.
             """
    end
  end
end
