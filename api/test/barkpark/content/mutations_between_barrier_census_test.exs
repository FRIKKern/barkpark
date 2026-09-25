defmodule Barkpark.Content.MutationsBetweenBarrierCensusTest do
  @moduledoc """
  The between-mutations barrier in `Barkpark.Content.Mutations` is a TEST-ONLY
  seam: a `fun/0` in the batch process's dictionary parks a batch inside its
  transaction. If any code under api/lib set that key, a production batch
  could stall holding its locks. This census proves nothing there does.

  Keyed on the atom's NAME, so a rename that forgets this test fails the
  non-vacuity assert rather than passing silently.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("lib")
  @key "barkpark_mutations_between_barrier"

  test "the barrier key appears under api/lib only as its own definition in mutations.ex" do
    hits =
      @lib
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> String.contains?(line, @key) end)
        |> Enum.map(fn {line, n} -> {Path.relative_to(path, @lib), n, String.trim(line)} end)
      end)

    assert match?([{"barkpark/content/mutations.ex", _n, _line}], hits),
           "expected exactly one mention of #{@key} under api/lib (its definition); got #{inspect(hits)}"

    [{_path, _n, definition}] = hits
    assert definition =~ ~r/^@between_mutations_barrier :#{@key}$/
  end

  test "mutations.ex only reads and deletes the key, never puts it" do
    source = File.read!(Path.join(@lib, "barkpark/content/mutations.ex"))

    assert source =~ "Process.get(@between_mutations_barrier)",
           "the barrier read is gone — this census no longer describes the seam"

    refute source =~ ~r/Process\.put\(\s*@between_mutations_barrier/,
           "mutations.ex now SETS the test-only barrier key"
  end
end
