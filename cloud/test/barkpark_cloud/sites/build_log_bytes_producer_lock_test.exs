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
end
