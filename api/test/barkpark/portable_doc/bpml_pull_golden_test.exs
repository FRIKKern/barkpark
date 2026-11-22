defmodule Barkpark.PortableDoc.BpmlPullGoldenTest do
  @moduledoc """
  The pull's bytes do not change. For every corpus shape and block golden, the
  printer's output (or its refusal) is pinned by a hash in
  `test/support/fixtures/bpml_pull_golden.json`, written from the printer of
  origin/main before the push check landed.

  Regenerate only on purpose: `BPML_PULL_GOLDEN_WRITE=1 mix test <this file>`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.BpmlCorpus
  alias Barkpark.PortableDoc.Bpml

  @golden Path.expand("../../support/fixtures/bpml_pull_golden.json", __DIR__)
  @blocks Path.expand("../../../priv/portable_doc/goldens/blocks/*.golden.json", __DIR__)

  # Why this test fails, and what a printer change must bring with it.
  @rule """
  the printer's output changed. A copy pulled before this change carries the
  old view's fingerprint (`bpmlView`) and now answers 412: pull again. When the
  print shows a form it did not show before, add the form as a row of
  `Bpml.PrintMark`, so a push that does not prove it saw the form keeps the
  form's blocks as stored; then regenerate this golden (BPML_PULL_GOLDEN_WRITE=1).
  """

  defp cases do
    shapes = for {name, block} <- BpmlCorpus.shapes(), do: {"shape: " <> name, block}

    goldens =
      for path <- @blocks |> Path.wildcard() |> Enum.sort(),
          %{"input" => block} = Jason.decode!(File.read!(path)),
          do: {"golden: " <> Path.basename(path, ".golden.json"), block}

    shapes ++ goldens
  end

  defp print(block) do
    bytes = Bpml.print_blocks([block])
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  rescue
    e in Barkpark.PortableDoc.Bpml.UnprintableError -> "refused: #{e.kind} #{e.type}"
  end

  test "every corpus shape and block golden prints the bytes it printed before" do
    now = Map.new(cases(), fn {name, block} -> {name, print(block)} end)

    if System.get_env("BPML_PULL_GOLDEN_WRITE") == "1" do
      File.write!(@golden, Jason.encode!(Jason.OrderedObject.new(Enum.sort(now)), pretty: true))
    end

    pinned = @golden |> File.read!() |> Jason.decode!()
    changed = for {name, hash} <- now, pinned[name] != hash, do: name

    assert changed == [], "#{inspect(changed)}: " <> @rule
  end
end
