defmodule Barkpark.Tasks.HeldPredicateTest do
  @moduledoc """
  task-4787fdd569f3aff4 — a RELEASED row must not read as HELD.

  `Tasks.Release` preserves the claim OBJECT as the audit trail: it nulls
  `claim.worker` and leaves everything else, INCLUDING a bumped `claim.epoch`
  (which `Tasks.Claim` reads as `current_epoch(doc) + 1` and `Tasks.Close`
  fences against, so it is load-bearing, not residue).

  The consequence is that three obvious presence tests are FALSE tests of
  heldness, and this file pins the difference:

      claim != nil               -> TRUE on a released row
      claim["epoch"] != nil      -> TRUE on a released row
      has_key?(claim, "worker")  -> TRUE on a released row
      Internal.held?/1           -> FALSE on a released row  <- the supported one

  MUTATION ARM: flip `Internal.held?/1` to any of the three presence tests and
  "a released row is NOT held" reds, naming the released row it misclassified.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.{Internal, Release}

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp claimed_task!(scope, worker) do
    doc_id = uniq("held")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "acceptance_criteria" => [
              %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fx"}
            ],
            "lifecycle_status" => "open"
          }
        },
        @dataset,
        scope
      )

    {:ok, claimed} = Tasks.claim_by_id(doc.doc_id, worker, scope)
    claimed
  end

  defp stored(doc), do: Repo.get!(Document, doc.id)

  # The three shapes a reader reaches for instead of the supported predicate.
  # A PREDICATE, not an enumeration of known-bad call sites: any reader with
  # this shape gets the same wrong answer.
  defp claim_object_present?(content), do: not is_nil(Map.get(content || %{}, "claim"))
  defp claim_epoch_present?(content), do: not is_nil(get_in(content || %{}, ["claim", "epoch"]))

  defp claim_worker_key_present?(content),
    do: Map.has_key?(Map.get(content || %{}, "claim") || %{}, "worker")

  describe "the held predicate discriminates a released row from a held one" do
    test "PRECONDITION: a released row really is released, and really keeps its claim",
         %{scope: scope} do
      doc = claimed_task!(scope, "w-pre")
      epoch = get_in(stored(doc).content, ["claim", "epoch"])
      assert {:ok, _} = Release.release(doc.id, "w-pre", observed_epoch: epoch)

      content = stored(doc).content

      # The setup landed, asserted — not inferred from a return code.
      assert content["lifecycle_status"] == "open",
             "precondition failed: the release did not reopen #{doc.doc_id}"

      assert get_in(content, ["claim", "worker"]) == nil,
             "precondition failed: #{doc.doc_id} still names a holder"

      # And the audit trail this row exists to describe is INTACT. If a future
      # change clears the claim object, this file's whole premise is gone and
      # you should be told here rather than by a green that measures nothing.
      assert is_map(Map.get(content, "claim")),
             "premise gone: the released claim object was cleared"

      assert get_in(content, ["claim", "epoch"]) == epoch + 1
      assert is_binary(get_in(content, ["claim", "released_at"]))
      assert get_in(content, ["claim", "released_by"]) == "w-pre"
    end

    test "CONTROL: a HELD row answers held? == true", %{scope: scope} do
      doc = claimed_task!(scope, "w-live")
      content = stored(doc).content

      assert content["lifecycle_status"] == "in_progress",
             "precondition failed: #{doc.doc_id} was not claimed"

      assert Internal.held?(content) == true
      assert Internal.holder(content) == "w-live"
    end

    test "a RELEASED row is NOT held, while all three presence tests say it is",
         %{scope: scope} do
      doc = claimed_task!(scope, "w-rel")
      epoch = get_in(stored(doc).content, ["claim", "epoch"])
      assert {:ok, _} = Release.release(doc.id, "w-rel", observed_epoch: epoch)

      content = stored(doc).content

      # THE ASSERTION THIS FILE EXISTS FOR.
      refute Internal.held?(content),
             "released row #{doc.doc_id} was classified as HELD — " <>
               "held?/1 must key on claim.worker and nothing else. " <>
               "claim=#{inspect(Map.get(content, "claim"))}"

      assert Internal.holder(content) == nil

      # …and the same row proves the three alternatives are FALSE TESTS. These
      # are not aspirational: they are what a presence-testing reader answers.
      assert claim_object_present?(content),
             "the released row lost its claim object — the defect this file pins is gone"

      assert claim_epoch_present?(content)
      assert claim_worker_key_present?(content)
    end

    test "held and released rows give DIFFERENT answers to the supported predicate",
         %{scope: scope} do
      held = claimed_task!(scope, "w-a")

      released = claimed_task!(scope, "w-b")
      epoch = get_in(stored(released).content, ["claim", "epoch"])
      assert {:ok, _} = Release.release(released.id, "w-b", observed_epoch: epoch)

      held_content = stored(held).content
      released_content = stored(released).content

      assert Internal.held?(held_content) != Internal.held?(released_content),
             "held?/1 did not discriminate: held=#{held.doc_id} released=#{released.doc_id}"

      # …and the presence tests do NOT discriminate — which is the whole point.
      assert claim_object_present?(held_content) == claim_object_present?(released_content)
      assert claim_epoch_present?(held_content) == claim_epoch_present?(released_content)
    end

    test "a blank worker string is not a holder either", %{scope: scope} do
      doc = claimed_task!(scope, "w-blank")
      content = put_in(stored(doc).content, ["claim", "worker"], "   ")
      refute Internal.held?(content)
    end

    test "a claim-less row is not held, and does not raise", %{scope: _scope} do
      refute Internal.held?(%{"lifecycle_status" => "open"})
      refute Internal.held?(%{})
      refute Internal.held?(nil)
      # A non-map claim must not blow up a read-side predicate.
      refute Internal.held?(%{"claim" => "nonsense"})
    end
  end
end
