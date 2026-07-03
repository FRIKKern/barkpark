defmodule BarkparkCloud.EventsContractTest do
  @moduledoc """
  The SSE event-type CONTRACT (pure — no DB, no :pg):

  1. `Events.types/0` equals the shared fixture
     `priv/static/__fixtures__/event_types.json` — the single cross-language
     truth also asserted by the dashboard harness (`__app.test.mjs`) against
     its `TYPE_ACTIONS` dispatch table. A type added on one side without the
     other reds one of the two gates.
  2. A source scan: every broadcast call site under `lib/` passes a literal
     string in the registered set. `broadcast/3` raises on an unregistered
     type at runtime; this scan catches the typo at test time instead of in a
     live request. The router's thin delegates (`push_event/2`,
     `broadcast_barkpark_team/2`, `broadcast_site_team/2`) forward a bare
     `type` variable — those forwarding sites are allowed, and their CALLERS
     are scanned by the same regex, so every literal in the chain is checked.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Events

  @fixture_path Path.expand("../../priv/static/__fixtures__/event_types.json", __DIR__)
  @lib_dir Path.expand("../../lib", __DIR__)

  # Matches a broadcast-chain call and captures its second argument. First arg
  # is comma/paren-free at every current call site (e.g. `team.id`,
  # `conn.assigns.current_team.id`); a future call with a parenthesized first
  # arg would simply not match — the runtime ArgumentError in broadcast/3
  # remains the backstop.
  @call_re ~r/(?:Events\.broadcast|push_event|broadcast_barkpark_team|broadcast_site_team)\(\s*[^,()]+,\s*([^,()]+)/

  test "types/0 equals the shared JSON fixture (sorted, unique)" do
    fixture = @fixture_path |> File.read!() |> Jason.decode!()

    assert is_list(fixture) and fixture != []
    assert Enum.sort(fixture) == fixture, "fixture must be sorted"
    assert Enum.uniq(fixture) == fixture, "fixture must not contain duplicates"
    assert Enum.sort(Events.types()) == fixture
  end

  test "broadcast/3 raises ArgumentError on an unregistered type, even for a nil team" do
    assert_raise ArgumentError, ~r/unregistered SSE event type "bogus"/, fn ->
      Events.broadcast("team-x", "bogus")
    end

    # The nil-team clause stays a no-op ONLY for registered types — a typo'd
    # type fails fast in every env, resolvable team or not.
    assert_raise ArgumentError, ~r/unregistered SSE event type/, fn ->
      Events.broadcast(nil, "bogus")
    end
  end

  test "every broadcast call site under lib/ passes a literal registered type" do
    registered = MapSet.new(Events.types())

    offenses =
      for path <- Path.wildcard(Path.join(@lib_dir, "**/*.ex")),
          source = File.read!(path),
          [_, arg] <- Regex.scan(@call_re, source),
          arg = String.trim(arg),
          # `type` is the delegation idiom inside the router's thin wrappers;
          # the wrappers' callers pass literals and are scanned themselves.
          arg != "type",
          not (match?("\"" <> _, arg) and
                 String.ends_with?(arg, "\"") and
                 MapSet.member?(registered, String.slice(arg, 1..-2//1))) do
        {Path.relative_to(path, @lib_dir), arg}
      end

    assert offenses == [],
           "broadcast call sites with a non-literal or unregistered event type " <>
             "(register the type in Events.@event_types + the shared fixture + " <>
             "app.js TYPE_ACTIONS, in the same PR): #{inspect(offenses)}"
  end
end
