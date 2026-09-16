defmodule Barkpark.Plugins.Github.ResolutionNoticeTest do
  @moduledoc """
  The composer that answers an outside reporter, and the four ways it refuses.

  NOTHING in this file touches the network. `compose/3` takes no client and
  returns a string; the #8463 notice asserted below is the artifact a human
  reviews and posts, and posting it is not this suite's business.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Github.ResolutionNotice

  # The real row, as the ledger carries it: doc_id `gh-8463`, github.issue 8463.
  defp row_8463 do
    {"gh-8463", %{"github" => %{"issue" => 8463, "repo" => "FRIKKern/barkpark"}}}
  end

  # The judgment half of the #8463 answer, written by a human. It is a fixture
  # rather than a derivation precisely because no function could have produced
  # it — see the module's "why the judgment half is a REQUIRED input".
  defp opts_8463 do
    [
      behaviour:
        "A private schema that is not owned by a plugin and does not set " <>
          "singleton:true now renders as a drillable document-type list under a " <>
          "\"Content\" group in the Studio desk, instead of a dead singleton " <>
          "document node. The 25-custom-type case in your report works unchanged.",
      action_required:
        "One thing to know: a schema that really IS a config singleton must now " <>
          "opt in with singleton:true on POST /v1/schemas/:dataset. The default is " <>
          "false, and everything else becomes a browsable list.",
      shipped_in: "PR #8471, commit eb23ef9544",
      shipped_at: "2026-08-02"
    ]
  end

  describe "compose/3 — the #8463 notice" do
    test "names the PR, the commit, the merge date and the new behaviour" do
      {doc_id, content} = row_8463()
      assert {:ok, text} = ResolutionNotice.compose(doc_id, content, opts_8463())

      assert text =~ "#8471"
      assert text =~ "eb23ef9544"
      assert text =~ "2026-08-02"
      assert text =~ "drillable document-type list"
      assert text =~ "singleton:true"
      assert text =~ "25-custom-type"
      assert text =~ "Issue #8463"
    end

    test "carries no ledger vocabulary onto the stranger's issue" do
      {doc_id, content} = row_8463()
      assert {:ok, text} = ResolutionNotice.compose(doc_id, content, opts_8463())

      refute text =~ "gh-8463"
      refute text =~ ~r/\btask-[0-9a-f]{8,}\b/
      refute text =~ "acceptance_criteria"
      refute text =~ "ack_gate"
    end
  end

  describe "compose/3 — the refusals" do
    test "refuses a row that was not born from an outsider's issue" do
      # An outbound mirror keeps its real slug, so the pair never matches.
      content = %{"github" => %{"issue" => 8463, "repo" => "FRIKKern/barkpark"}}

      assert {:error, :not_intake_born} =
               ResolutionNotice.compose("task-3044ea0939fb056b", content, opts_8463())
    end

    test "refuses when the judgment half is missing rather than emitting a placeholder" do
      {doc_id, content} = row_8463()
      opts = Keyword.delete(opts_8463(), :behaviour)

      assert {:error, :behaviour_required} = ResolutionNotice.compose(doc_id, content, opts)
    end

    test "refuses a notice naming neither a PR nor a commit" do
      {doc_id, content} = row_8463()
      opts = Keyword.put(opts_8463(), :shipped_in, "an internal change")

      assert {:error, :no_shipped_ref} = ResolutionNotice.compose(doc_id, content, opts)
    end

    test "refuses — never silently strips — an internal identifier in human text" do
      {doc_id, content} = row_8463()

      opts =
        Keyword.put(
          opts_8463(),
          :action_required,
          "Tracked internally as task-5e21301e51541200 if you want the detail."
        )

      assert {:error, {:internal_identifier, "task-5e21301e51541200"}} =
               ResolutionNotice.compose(doc_id, content, opts)
    end
  end
end
