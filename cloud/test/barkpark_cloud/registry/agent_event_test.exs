defmodule BarkparkCloud.Registry.AgentEventTest do
  @moduledoc """
  THE ALLOWLIST IS A DECLARED CAPABILITY, SO EVERY WORD IN IT MUST BE REACHABLE.

  `AgentEvent`'s `@types` is the closed vocabulary of the instance event stream.
  Wave 51 fixed the CONSOLE half of this — the Timeline no longer titles an
  event nothing can write (`__agent_event_vocabulary_census.mjs`) — and
  deliberately left the SERVER half alone under charter D576: `@types` still
  declared `backup`, `tls` and `content`, of which the first two had neither a
  producer nor a consumer anywhere in `cloud/lib`, and by repo-wide pickaxe
  never had a production producer in the history of main. A vocabulary entry
  nothing can reach is a promise the plane cannot keep: a reader of this module
  believed the control plane reported on backup runs and TLS renewals. It never
  has.

  This is the server-side census, and it is the DIFFERENCE OF DERIVED SETS, not
  a snapshot of the list — a commit that drops one word and adds another cannot
  hold it green. Both sides are read out of `cloud/lib/**/*.ex`:

    * PRODUCED — the literal 2nd argument of every `Registry.record_event(`
      call site. That call is the only way an `agent_events` row is ever
      written.
    * CONSUMED — every `<binding>.type == "<t>"` read. A type with no producer
      but a live consumer is FORWARD-COMPAT, not dead: the consumer is what
      makes the word mean something the day a producer lands. `content` is
      exactly that — `Accounts.published_doc?/1` reads it for the onboarding
      checklist, and the step degrades to the user-ack path until an agent
      posts one.

  A type in `@types` that is in NEITHER set can never be written and, if it
  somehow were, nothing would read it. That is the orphan this test names.

  ## Why this is not the .mjs census

  `__agent_event_vocabulary_census.mjs` (charter D341/D575) reads the CONSOLE's
  `TLV_EVENT_TITLES` against the producer set, and its own LIMIT 4 says outright
  that `@types` is not one of its arms — DECLARED is not PRODUCED, and it is
  PRODUCED that a title promises. This test is the missing server-side side, and
  it belongs in Elixir because the thing it guards is an Elixir changeset.

  ## Stated limits, because an unstated limit is the same lie

    * LIMIT 1 — the producer arm matches a LITERAL 2nd argument. A producer
      emitted through a wrapper, or with the type bound one hop back in a
      variable, is invisible to it. That direction fails SAFE: an unseen
      producer can only cause a red, which a human resolves by making the call
      site literal or teaching this file the new shape.
    * LIMIT 2 — the consumer arm matches any `.type == "..."` in `cloud/lib`, so
      a NON-AgentEvent struct carrying a `type` field could widen the set. That
      also fails safe for reds: a too-wide consumer set can only ever EXCUSE a
      declared word, never falsely accuse one. `billing.ex`'s bare
      `type == "customer.subscription.updated"` (no leading dot, a Stripe event
      name) is already outside it.
    * LIMIT 3 — whole-line `#` comments and heredoc bodies are blanked first, so
      a stale sentence cannot green this test. `telemetry.ex`'s `@moduledoc`
      quotes a real call site as prose and would otherwise count as a producer.
      Blanking preserves line numbers, so the sites this test names are real.
    * LIMIT 4 — it proves a word is REACHABLE, not that the word is the right
      one. Whether the console's title for it is good is pinned elsewhere.

  No DB: this reads source, so plain `ExUnit.Case`.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Registry.AgentEvent

  @lib_root Path.expand("../../../lib/barkpark_cloud", __DIR__)

  # The 2nd positional argument of a `Registry.record_event(` call, when literal.
  # The `Registry.` prefix is load-bearing: registry.ex's own `@spec` and `def
  # record_event` carry no prefix, so the DEFINITION never counts as a call.
  @producer_re ~r/Registry\.record_event\(\s*[^,()]+,\s*"([a-z][a-z0-9_]*)"/
  # A read of an event's type. The leading `.` is load-bearing (see LIMIT 2).
  @consumer_re ~r/\.type\s*==\s*"([a-z][a-z0-9_]*)"/

  # Extractor floors. These are NOT the property under test — they prove the
  # instrument still reads. A scan stripped to nothing would satisfy the orphan
  # assertion trivially, which is exactly how a census certifies silence.
  @known_producers ~w(health status space verify)
  @min_lib_files 20

  defp lib_sources do
    @lib_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
  end

  # Blank out whole-line `#` comments and heredoc bodies. Conservative on
  # purpose: it never has to be a parser, it only has to stop PROSE from
  # counting as code. Lines are BLANKED, not dropped, so indices stay true.
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

  defp sites(regex) do
    for path <- lib_sources(),
        {line, n} <- Enum.with_index(code_only(File.read!(path)), 1),
        [_, type] <- Regex.scan(regex, line) do
      {type, "#{Path.relative_to(path, @lib_root)}:#{n}"}
    end
  end

  defp scan(regex), do: regex |> sites() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  describe "the @types allowlist is a closed vocabulary of REACHABLE words" do
    test "the extractor still reads cloud/lib (floors — a broken scan reds, never passes)" do
      files = lib_sources()

      assert length(files) >= @min_lib_files,
             "scanned only #{length(files)} .ex files under #{@lib_root} — the extractor lost the tree"

      produced = scan(@producer_re)
      consumed = scan(@consumer_re)

      for t <- @known_producers do
        assert t in produced,
               """
               The producer arm no longer sees the known `#{t}` writer. That is a
               broken extractor, not a clean tree — an empty producer set would
               satisfy the orphan assertion below trivially.

               produced: #{inspect(Enum.sort(produced))}
               """
      end

      assert "health" in consumed,
             """
             The consumer arm no longer sees any `.type == "health"` read, and
             `health` is consumed at three independent sites in cloud/lib. The
             extractor is broken; an empty consumer set can only EXCUSE words.

             consumed: #{inspect(Enum.sort(consumed))}
             """
    end

    test "every declared type has a producer or a consumer in cloud/lib" do
      produced = scan(@producer_re)
      consumed = scan(@consumer_re)
      orphans = AgentEvent.types() -- (produced ++ consumed)

      assert orphans == [],
             """
             AgentEvent's @types declares #{Enum.join(orphans, ", ")}, which
             NOTHING in cloud/lib can write and NOTHING in cloud/lib reads.

             An allowlist is a declared capability. A word in it that no call
             site can reach tells a reader — and anyone deriving a surface from
             it — that the control plane reports on something it does not.
             Either wire a producer in the SAME commit, or drop the word.

             declared: #{inspect(AgentEvent.types())}
             produced (Registry.record_event/3 literals): #{inspect(Enum.sort(produced))}
             consumed (.type == "..." reads):             #{inspect(Enum.sort(consumed))}
             """
    end

    test "every produced type is declared (a producer @types rejects writes nothing)" do
      undeclared =
        @producer_re
        |> sites()
        |> Enum.reject(fn {type, _site} -> type in AgentEvent.types() end)
        |> Enum.map(fn {type, site} -> "#{site}: #{type}" end)

      assert undeclared == [],
             """
             A `Registry.record_event/3` call site writes a type @types does not
             declare. `validate_inclusion` rejects it, so the insert returns
             {:error, changeset} — and the producers in cloud/lib discard that
             return with `_ =`, so the row is silently never written. This is the
             exact shape the `space` payload hit before its type was declared.

             #{Enum.join(undeclared, "\n")}
             declared: #{inspect(AgentEvent.types())}
             """
    end
  end
end
