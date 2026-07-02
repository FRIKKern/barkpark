defmodule Barkpark.SelfUpdate.Client.GitHubTest do
  # Pure parsing tests only — no network. The HTTP path is exercised through
  # the Fake client seam in checker_test.exs.
  use ExUnit.Case, async: true

  alias Barkpark.SelfUpdate.Client.GitHub

  describe "max_release_tag/1" do
    test "picks the numerically-largest vA.B.C tag (integer, not lexicographic)" do
      # v0.10.1 > v0.2.23 as integer tuples; "v0.9.9" would win a string sort.
      assert GitHub.max_release_tag(["v0.2.9", "v0.2.23", "v0.10.1", "v0.9.9"]) ==
               {"0.10.1", "v0.10.1"}
    end

    test "ignores non-release tags: cli-v* (separate CLI version space), rc, 4-segment, junk" do
      names = ["cli-v9.9.9", "v1.0.0-rc1", "v0.2.23.4", "main", nil, "v0.2.23"]
      assert GitHub.max_release_tag(names) == {"0.2.23", "v0.2.23"}
    end

    test "returns nil when nothing matches" do
      assert GitHub.max_release_tag([]) == nil
      assert GitHub.max_release_tag(["cli-v1.0.0", "not-a-tag", nil]) == nil
    end
  end
end
