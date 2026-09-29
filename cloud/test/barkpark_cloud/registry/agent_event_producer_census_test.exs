defmodule BarkparkCloud.Registry.AgentEventProducerCensusTest do
  @moduledoc """
  A DECLARED TYPE'S PRODUCER-BACKEDNESS IS A DECISION, SO IT IS PINNED PER WORD.

  `agent_event_test.exs` already pins the allowlist in both directions, but it
  pins an OR: a word survives it with a producer OR a consumer. That is the
  right rule for "can this word be reached at all", and it is structurally blind
  to the thing `cch-w55-bl` found — `content` has a live consumer
  (`Accounts.published_doc?/1`, the onboarding checklist's third step) and ZERO
  producers, and it could gain one, or `status` could lose its only one, without
  that test moving a pixel. Both of those are product decisions, not refactors:

    * a `content` producer landing means the onboarding step stops being a
      self-report and starts being an observation, which is precisely the
      "build the actor before deciding the effect" move charter D902 refused;
    * a producer disappearing means a word that used to arrive on the instance
      timeline silently never does again — the console's `TLV_EVENT_TITLES` and
      `__agent_event_vocabulary_census.mjs` would follow it down without anyone
      noticing the capability went.

  So this file carries the EXPECTED producer-backedness of every word in
  `@types` and reds in BOTH directions. It is a decision record with an exit
  code: the way to make it green is to move the decision, not the expectation.

  ## The three assertions, and why each is not the other

    1. FLOORS (the positive control) — the scan can SEE the producers it guards.
       Every expected-producer type is asserted to have at least one NAMED site
       (file:line), and the file count has a floor. A scan stripped to nothing
       would satisfy assertion 3 for the producer-backed words by accident and
       assertion 2 vacuously; this is the arm that refuses to certify silence.
       It also asserts a sentinel that is NOT produced anywhere, so a scan that
       matched everything cannot pass either.
    2. COVERAGE — the expectation map's key set is exactly `AgentEvent.types()`.
       A word added to `@types` with no entry here, or an entry left behind by a
       word that was struck, reds. Without this, assertion 3 would iterate a
       stale list and say nothing about a brand-new type.
    3. THE PER-TYPE VERDICT — for each declared word, "has a producer" equals
       what this file says it should. This is the arm that fires on the gain and
       on the loss.

  ## Limits, inherited on purpose

  The producer regex is the SAME shape `agent_event_test.exs` uses, so the two
  files cannot disagree about what a producer is. It therefore inherits that
  file's LIMIT 1 (a literal 2nd argument only; a wrapper or a variable-bound
  type is invisible) and LIMIT 3 (whole-line `#` comments and heredoc bodies are
  blanked, so this very moduledoc's prose cannot green or red anything). An
  unseen producer fails toward a RED here, which a human resolves by making the
  call site literal — never toward a silent pass.

  No DB: this reads source, so plain `ExUnit.Case`.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Registry.AgentEvent

  @lib_root Path.expand("../../../lib/barkpark_cloud", __DIR__)

  # Same shape as agent_event_test.exs's @producer_re — the `Registry.` prefix
  # keeps registry.ex's own @spec/def out of the call-site set.
  @producer_re ~r/Registry\.record_event\(\s*[^,()]+,\s*"([a-z][a-z0-9_]*)"/

  # THE DECISION, PER WORD. true = this type is written by at least one
  # Registry.record_event/3 call site in cloud/lib; false = declared for a
  # CONSUMER only, deliberately, and the reason is named beside it.
  #
  #   health  — the 60s agent beat (web/router.ex, the agent-report handler)
  #   status  — the offline flip (health/staleness_worker.ex)
  #   space   — the 15-minute disk payload (web/router.ex, D58)
  #   verify  — the control-plane readiness suite (web/router.ex, C8/D53)
  #   content — NO PRODUCER, BY DECISION (charter D902). Consumed by
  #             Accounts.published_doc?/1; the onboarding step it feeds is
  #             reached by the user-ack control instead. Flipping this to true
  #             is not a test fix — it is the decision D902 deferred, and the
  #             console copy, the ack control and both moduledocs move with it.
  @expected_producer %{
    "health" => true,
    "status" => true,
    "space" => true,
    "verify" => true,
    "content" => false
  }

  # A word no call site writes and no allowlist declares. If the scan ever
  # "finds" it, the extractor is matching prose or the wrong thing entirely.
  @never_produced "meltdown"
  @min_lib_files 20

  defp lib_sources, do: @lib_root |> Path.join("**/*.ex") |> Path.wildcard()

  # Blank whole-line `#` comments and heredoc bodies; blank, never drop, so the
  # line numbers this test PRINTS are the real ones.
  defp code_only(source) do
    source
    |> String.split("\n")
    |> Enum.map_reduce(false, fn line, in_heredoc? ->
      trimmed = String.trim_leading(line)

      cond do
        String.contains?(line, ~S(""")) -> {"", not in_heredoc?}
        in_heredoc? -> {"", true}
        String.starts_with?(trimmed, "#") -> {"", false}
        true -> {line, false}
      end
    end)
    |> elem(0)
  end

  # %{type => [\"file:line\", ...]} over every literal record_event call site.
  defp producer_sites do
    for path <- lib_sources(),
        {line, n} <- Enum.with_index(code_only(File.read!(path)), 1),
        [_, type] <- Regex.scan(@producer_re, line) do
      {type, "#{Path.relative_to(path, @lib_root)}:#{n}"}
    end
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  describe "every declared agent-event type's producer-backedness is the one this file records" do
    test "FLOORS: the scan sees the producers it guards, and does not see what is not there" do
      files = lib_sources()

      assert length(files) >= @min_lib_files,
             "scanned only #{length(files)} .ex files under #{@lib_root} — the extractor lost the tree"

      sites = producer_sites()

      # A PATTERN generator (`{type, true}`) — sound, unlike an assignment
      # qualifier: it filters by MATCH, not by truthiness of a binding.
      for {type, true} <- @expected_producer do
        found = Map.get(sites, type, [])

        refute found == [],
               """
               POSITIVE CONTROL FAILED. `#{type}` is recorded here as
               producer-backed and the scan found NO call site for it. Before
               believing the producer is gone, believe the scan is broken: an
               empty producer set would make the per-type verdict below agree
               with an all-false expectation for the wrong reason.

               all sites seen: #{inspect(sites)}
               """
      end

      refute Map.has_key?(sites, @never_produced),
             """
             The scan reports a `#{@never_produced}` producer. Nothing writes
             that type and nothing declares it — the extractor is matching
             something that is not a call site (prose that escaped the comment
             blanking, or a widened regex).

             sites: #{inspect(sites)}
             """
    end

    test "COVERAGE: this file's expectation map covers exactly @types" do
      declared = MapSet.new(AgentEvent.types())
      recorded = MapSet.new(Map.keys(@expected_producer))

      assert MapSet.equal?(declared, recorded),
             """
             The per-type expectation map has drifted from AgentEvent's @types.

             declared but unrecorded: #{inspect(MapSet.to_list(MapSet.difference(declared, recorded)))}
             recorded but undeclared: #{inspect(MapSet.to_list(MapSet.difference(recorded, declared)))}

             A new word needs an entry here stating whether it is producer-backed
             and WHY — that entry is the decision record. A struck word's entry
             goes with it.
             """
    end

    test "PER TYPE: a declared type gaining or losing its producer reds this test" do
      sites = producer_sites()

      # Enum.flat_map, NOT a `for` with `expected = ...` as a qualifier. An
      # assignment used as a comprehension qualifier is a FILTER on its own
      # value, so `expected = false` would DISCARD the consumer-only types —
      # every word this test exists for. That exact defect shipped in this
      # file's first draft and was caught only because the gain-direction
      # mutation below was actually run: the guard was green with a `content`
      # producer in the tree. Bind in the BODY, filter explicitly.
      drift =
        Enum.flat_map(AgentEvent.types(), fn type ->
          expected = Map.fetch!(@expected_producer, type)
          actual = Map.has_key?(sites, type)

          if actual == expected do
            []
          else
            [
              "#{type}: recorded as #{if expected, do: "PRODUCER-BACKED", else: "consumer-only"}, " <>
                "but the scan found #{if actual, do: "producers at " <> Enum.join(sites[type], ", "), else: "NO producer"}"
            ]
          end
        end)

      assert drift == [],
             """
             A declared agent-event type's producer-backedness changed without
             this file — and the decision it records — moving with it.

             #{Enum.join(drift, "\n")}

             A word GAINING a producer is not a refactor. `content` is the live
             case: charter D902 ruled the onboarding "published a doc" step is a
             user SELF-REPORT (the console's "Mark as done" control) and that no
             agent-side observer would be built before anyone decided what the
             agent can honestly see. Landing one flips that step from a claim the
             user makes to a claim the plane makes, and the console copy
             ("We can't see this from here") becomes false in the same commit.

             A word LOSING its producer is the cch-w51-bl shape: the type stays
             declared, the console keeps its title, and the event simply never
             arrives again.

             Either way: move the decision first, then this file.
             """
    end
  end
end
