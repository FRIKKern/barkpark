defmodule BarkparkCloud.Sites.BuildLogBytesProducerLockTest do
  @moduledoc """
  A DECODER MUST NOT OUTLIVE ITS PRODUCER — the Elixir half of the law
  `internal/cloudclient/producer_contract_test.go` states for the Go client.

  THE DEFECT CLASS. `FakeBoxRelay.build_log_bytes_payload/5` is a hand-typed copy
  of what the box's door emits, and `Sites.BuildLogBytes.@bytes_keys` is a
  hand-typed list of what this end will read out of it. Three hand-typed lists on
  two sides of a process boundary stay perfectly self-consistent while the wire
  moves underneath them: every cloud test goes green against a fixture the real
  box stopped sending. No hand-written fixture can catch that; only a comparison
  against the REAL producer can.

  WHAT THIS DOES. Reads the api controller's own `render_build_log_bytes/2` out of
  SOURCE — the only place the box's byte payload is built — and asserts:

    1. the fake's payload keys are exactly the producer's keys (no fixture richer
       than reality, and none poorer);
    2. every key `BuildLogBytes` will render is a key the producer can emit.

  The read is at RUNTIME, inside the test, and deliberately not an
  `@external_resource` — this is an assertion about another tree, not a
  compile-time dependency on it (`scripts/elixir-path-escape-check.sh`).

  Cited by SYMBOL, never by line: the file this reads moves constantly.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Sites.BuildLogBytes
  alias BarkparkCloud.Sites.FakeBoxRelay

  @producer "api/lib/barkpark_web/controllers/site_deploy_controller.ex"

  defp producer_path do
    Path.expand(Path.join([__DIR__, "..", "..", "..", "..", @producer]))
  end

  # The keys of the `%{…}` literal inside `defp render_build_log_bytes(record, error) do`,
  # up to its closing `case error do`. Structural, so a renamed field is caught and
  # a reordered one is not a false positive.
  defp producer_keys do
    source = File.read!(producer_path())

    [_, block] =
      String.split(source, "defp render_build_log_bytes(record, error) do", parts: 2)

    [literal, _] = String.split(block, "case error do", parts: 2)

    Regex.scan(~r/^      ([a-z_]+):/m, literal)
    |> Enum.map(fn [_, key] -> key end)
    |> Enum.sort()
  end

  test "the producer is READABLE and its extractor is not blind" do
    # THE CONTROL. An extractor that silently returns [] would make every
    # assertion below vacuously true — the exact failure this whole file exists
    # to prevent one level down.
    assert File.regular?(producer_path()),
           "the api controller moved; this lock is measuring nothing at #{producer_path()}"

    keys = producer_keys()
    assert length(keys) > 5, "extracted #{length(keys)} keys — the extractor is blind"
    assert "tail" in keys
    assert "log_scrub" in keys
  end

  test "the fake box's byte payload emits EXACTLY the keys the real box emits" do
    {:ok, 200, body} =
      FakeBoxRelay.build_log_bytes_payload("blog", "bld-1", 200, "available", tail: "boom\n")

    assert Enum.sort(Map.keys(body)) == producer_keys(),
           "the fake and the box disagree about the wire — an UNLOCKED MIRROR"
  end

  test "every key this control plane renders is a key the box can send" do
    rendered = BuildLogBytes.__bytes_keys__()
    producer = producer_keys()

    assert rendered -- producer == [],
           "BuildLogBytes reads #{inspect(rendered -- producer)}, which the box never emits"
  end

  ## The fixture must not depend on WHICH tests ran alongside it ---------------

  @fake_relay "test/support/sites_fake_box_relay.ex"

  defp fake_relay_path do
    Path.expand(Path.join([__DIR__, "..", "..", "..", @fake_relay]))
  end

  # THE INCIDENT THIS PINS. `terminal_record/4` used to reach the caller's opts
  # through `String.to_existing_atom(key)` over its own string-keyed defaults.
  # `:finished_at` is interned by modules the FULL suite loads, so CI was green
  # forever — while `mix test test/barkpark_cloud/web/`, or either RouterBuildLog
  # file on its own, killed all 11 tests that call this helper with
  # "1st argument: not an already existing atom". A fixture whose correctness
  # depends on the run's file selection is not a fixture.
  test "the fake box relay interns no atom at runtime" do
    # CODE ONLY. The prose above and the note in the fixture itself both name the
    # banned call; a guard that matched them would red on its own explanation.
    source =
      fake_relay_path()
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&(String.trim_leading(&1) =~ ~r/^#/))
      |> Enum.join("\n")

    refute source =~ "to_existing_atom",
           """
           #{@fake_relay} calls String.to_existing_atom/1.

           That makes the fixture's behaviour depend on whether some other module
           in the same run already interned the atom: green for the full suite,
           ArgumentError for a narrow `mix test <dir>`. The opt names are literals
           in the source — write them as atoms and derive the string with
           Atom.to_string/1.
           """
  end

  # THE CONTROL for the rewrite above: the atom -> string conversion must still
  # let a caller override a default by its atom opt name. A version that only
  # stopped interning atoms, and quietly stopped honouring opts, passes the guard
  # above and fails here.
  test "terminal_record/4 honours an opt override keyed by atom" do
    {:ok, 200, default} = FakeBoxRelay.terminal_record("blog", "bld-1", "available")

    {:ok, 200, overridden} =
      FakeBoxRelay.terminal_record("blog", "bld-1", "available",
        finished_at: "2027-01-01T00:00:00Z"
      )

    assert default["finished_at"] == "2026-08-06T01:04:00Z"
    assert overridden["finished_at"] == "2027-01-01T00:00:00Z"
    assert overridden["log_state"] == "available"
  end
end
