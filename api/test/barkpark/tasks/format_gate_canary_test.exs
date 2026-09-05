defmodule Barkpark.Tasks.FormatGateCanaryTest do
  @moduledoc """
  A canary for the format gate, deliberately committed UNFORMATTED first.

  The gate's `fetch-depth` fix (this PR) is only provable if the gate can still
  RED. A gate that goes from never-measuring to always-passing is the same
  defect with a new mechanism, and it would look exactly like a fix.

  So this file lands unformatted on the first push, the Format job's red is
  recorded, and the second push formats it and records the pass. Both runs are
  quoted on the row.

  The test itself is trivial on purpose: the assertion under test is the GATE's,
  not this file's.
  """

  use ExUnit.Case, async: true

  test "the canary compiles and passes — the gate is what is under test" do
        assert    1 + 1 ==
      2
  end
end
