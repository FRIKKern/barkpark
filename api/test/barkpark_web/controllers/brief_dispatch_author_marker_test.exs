defmodule BarkparkWeb.TasksController.BriefDispatchAuthorMarkerTest do
  @moduledoc """
  task-46e82dc40c385ed2, criterion 1: a lead who reads ONLY the `bp task ready`
  listing must not be able to dispatch against a row whose content forbids it.

  This renders the cards through the shipped `Params.render_brief/4` — the
  exact function `?view=brief` maps over its page, which is what `bp task
  ready` calls — and asserts the do-not-build marker reaches the CARD, where
  the `content` it lives in does not.

  MUTATION PROOF: make `put_brief_marker/2` a no-op and the marked-row test
  reds while the clean-row test stays green.

  The fixture prose is the REAL text of the row that caused the burn:
  `task-ae82ac9ec98a49fd`'s operating_instruction refuses a builder in
  capitals, and a lead reading the listing dispatched one anyway.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Dispatchability
  alias BarkparkWeb.TasksController.Params

  defp doc(doc_id, content) do
    %Document{
      id: Ecto.UUID.generate(),
      doc_id: doc_id,
      type: "task",
      status: "published",
      title: "a P1 row a lead would claim off the listing",
      content:
        Map.merge(%{"kind" => "task", "lifecycle_status" => "open", "priority" => 1}, content),
      updated_at: ~N[2026-09-22 04:03:00]
    }
  end

  defp card(doc), do: Params.render_brief(doc, %{}, %{}, %{})

  describe "the marker reaches the card the listing actually shows" do
    test "a forbidden row carries `dispatch`; an otherwise identical row does not" do
      marked =
        doc("task-ae82ac9ec98a49fd", %{
          "description" => "A real defect with real work in it.",
          "operating_instruction" =>
            "DO NOT COMMISSION A BUILDER FOR c0 — an agent must not write to a third party's issue."
        })

      clean =
        doc("task-an-ordinary-slice", %{
          "description" => "A real defect with real work in it.",
          "operating_instruction" => "Commission a builder for c0; the fence is api/lib/**."
        })

      marked_card = card(marked)
      clean_card = card(clean)

      assert marked_card[:dispatch] == "forbidden"
      refute Map.has_key?(clean_card, :dispatch)

      refute marked_card[:dispatch] == clean_card[:dispatch],
             "THE CONTROL FAILED: the changed path produced the same card for a forbidden row and a clean one"

      # AND THE CLEAN CARD'S SILENCE IS EVIDENCE, not a vacuous read: the same
      # doc's content demonstrably carried the fields the scan looks at.
      assert Dispatchability.marker_scan(clean.content).fields_present != [],
             "the clean row's missing key would be vacuous if its content fields were empty"

      # Neither card leaks `content` — the projection is unchanged in every
      # other respect, which is why the derived key was needed at all.
      refute Map.has_key?(marked_card, :content)
      refute Map.has_key?(clean_card, :content)
    end

    test "the marker OUTRANKS the inferred edge classes" do
      # A row that is BOTH an umbrella (live children) and author-forbidden.
      # One card, one verdict, and it is the author's.
      row = doc("task-both", %{"description" => "DO NOT COMMISSION a builder here."})

      both = Params.render_brief(row, %{"task-both" => 4}, %{"task-both" => 2}, %{})

      assert both[:dispatch] == "forbidden",
             "an inferred `delegated` overwrote an author's explicit refusal"

      # The edge rule still speaks when nothing overrides it — otherwise this
      # test proves only that `delegated` never fires.
      plain = doc("task-umbrella", %{"description" => "An epic root."})

      assert Params.render_brief(plain, %{"task-umbrella" => 4}, %{"task-umbrella" => 2}, %{})[
               :dispatch
             ] == "delegated"
    end

    test "the marker is found in ANY of the three fields, not just description" do
      for field <- Dispatchability.marker_fields() do
        row = doc("task-#{field}", %{field => "OWNER-GATED: it needs a production re-seed."})

        assert card(row)[:dispatch] == "deferred",
               "a marker in #{field} alone did not reach the card; searching one field undercounts"
      end
    end
  end

  describe "the wire cost is the one the byte tripwires already price" do
    test "`forbidden`/`deferred` are no longer than the classes already on the key" do
      # The classes share ONE key, so a card carries at most one value and the
      # hostile 50-card bound is untouched. Asserted, not remembered.
      assert String.length("forbidden") == String.length("delegated")
      assert String.length("deferred") == String.length("upstream")

      for class <- Dispatchability.marker_classes() do
        assert String.length(class) <= String.length("delegated"),
               "#{class} is longer than the widest value the byte tripwires already price"
      end
    end
  end
end
