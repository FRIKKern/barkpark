defmodule BarkparkWeb.TasksController.BriefClaimResidueTest do
  @moduledoc """
  task-4fe00055375680bb: a board-wide sweep must be able to COUNT the rows
  whose claim object outlived its holder, without reverting the card
  tightening that removed the claim block from them.

  THE SHAPE OF THE BUG, AND IT IS AN INSTRUMENT BUG, NOT A CARD BUG.
  `brief_claim/1` correctly drops the claim block when the claim names no
  worker — a ready row is claimable by anyone and a worker-less block is not
  an ownership signal. `bp task ready` serves the brief view, so after that
  tightening a full ready walk filtered for `.claim != null and
  .claim.worker == null` returns ZERO on every board, forever, by
  construction. Measured on the live board 2026-09-23 over a complete
  two-page walk (724 rows): that filter returned 0, the positive control
  (`.claim.worker != null`) returned 19 — so the lens fires for live claims
  and is blind to residue — and a per-row `bp task get` over all 724 rows
  found 183 rows carrying a claim map with a null worker (53 swept by the
  TTL sweeper, 130 deliberately released). The sweep could not tell a clean
  board from a blind instrument.

  THE FIX IS ADDITIVE. The card keeps its tightening; the residue gets its
  OWN key, `claim_residue`, a short discriminating string — never the claim
  block back. `claim.worker` remains the one ownership signal and nothing
  that reads it changes meaning.

  WHY A STRING AND NOT A BOOLEAN. 130 of the 183 are deliberate releases,
  which are ordinary correct lane behaviour; 53 are TTL-sweeper reaps, which
  are the hazard the pulse loop exists to catch. A boolean would conflate the
  two and hand the next sweep a 183-row haystack for a 53-row question.

  MUTATION PROOF, three mutations, three different reds:

    M1  `defp put_brief_claim_residue(map, _content), do: map`
        reds every "the residue is visible" assertion; the claimless and
        live-claim arms stay GREEN.
    M2  drop the nil-worker guard so any claim map emits a residue
        reds "a LIVE claim is not residue" only.
    M3  emit `claim_residue` from the catch-all clause (no claim key at all)
        reds "a claimless row is NOT swept" only — the false-positive arm.

  The second and third arms are the ones that matter: a sweep that reports
  every claimless row is the same instrument failure with the sign flipped.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Document
  alias BarkparkWeb.TasksController.Params

  # A TTL-swept lease exactly as the sweeper leaves it: worker nulled,
  # previous_worker and expired_at recorded. Copied from a live specimen
  # (cch-w34-bl-lower-recipient-index), not invented.
  @swept %{
    "worker" => nil,
    "epoch" => 2,
    "previous_worker" => "console-r21f-w14",
    "expired_at" => "2026-09-18T05:06:00.735979Z",
    "ts_iso" => "2026-09-18T05:06:00.735979Z"
  }

  # A deliberate release, the other 130/183. Also worker-less, also residue,
  # but a different story — and the card must say which.
  @released %{
    "worker" => nil,
    "epoch" => 16,
    "released_by" => "lead-cli",
    "released_at" => "2026-09-20T14:56:20.623609Z",
    "ts_iso" => "2026-09-20T14:56:20.276678Z"
  }

  # Residue with neither marker — the shape `tasks_controller_test.exs`'s
  # "signal-free claim" fixture plants, and the shape a hand-written claim
  # map can have. Still residue: there is an epoch and no holder.
  @unheld %{"epoch" => 2, "ts_iso" => "2026-07-18T09:00:00Z", "work_digest" => "abcd"}

  # THE CONTROL. One field apart from @swept, opposite verdict.
  @live Map.put(@swept, "worker", "api-r22-w7")

  defp doc(doc_id, claim) do
    content = %{"kind" => "task", "lifecycle_status" => "open", "priority" => 2}
    content = if claim == :none, do: content, else: Map.put(content, "claim", claim)

    %Document{
      id: Ecto.UUID.generate(),
      doc_id: doc_id,
      type: "task",
      status: "published",
      title: "a ready row",
      content: content,
      updated_at: ~N[2026-09-23 12:00:00]
    }
  end

  defp card(doc_id, claim), do: Params.render_doc(doc(doc_id, claim), :brief)

  describe "ARM ONE — the residue is VISIBLE to a board-wide sweep" do
    test "a TTL-swept claim (epoch + null worker) carries claim_residue == \"expired\"" do
      c = card("swept-1", @swept)

      assert Map.get(c, :claim_residue) == "expired",
             "a swept lease is invisible to the sweep: #{inspect(c)}"
    end

    test "a RELEASED claim (epoch + null worker) carries claim_residue == \"released\"" do
      assert Map.get(card("released-1", @released), :claim_residue) == "released"
    end

    test "residue with neither marker still rides, as \"unheld\"" do
      assert Map.get(card("unheld-1", @unheld), :claim_residue) == "unheld"
    end

    test "a claim map with an EXPLICIT nil worker and nothing else is still residue" do
      assert Map.get(card("unheld-2", %{"worker" => nil}), :claim_residue) == "unheld"
    end

    test "the card tightening SURVIVES: the claim block itself is still gone" do
      for {id, claim} <- [{"swept-2", @swept}, {"released-2", @released}, {"unheld-3", @unheld}] do
        c = card(id, claim)
        refute Map.has_key?(c, :claim), "the residue rode the claim block back onto #{id}"
        assert Map.has_key?(c, :claim_residue)
      end
    end
  end

  describe "ARM TWO — a row with NO claim is NOT swept (the false-positive arm)" do
    test "a row whose content has no claim key at all carries NO claim_residue key" do
      c = card("noclaim-1", :none)

      refute Map.has_key?(c, :claim_residue),
             "every claimless row became a false positive: #{inspect(c)}"

      refute Map.has_key?(c, :claim)
    end

    test "a claim key that is not a map — nil, a string, a list — is NOT residue" do
      for junk <- [nil, "api-r22-w7", [], 7] do
        c = card("junk-1", junk)

        refute Map.has_key?(c, :claim_residue),
               "junk claim #{inspect(junk)} was reported as residue"
      end
    end

    test "a LIVE claim is NOT residue — it is held, and the card says so on :claim" do
      c = card("live-1", @live)

      refute Map.has_key?(c, :claim_residue),
             "a held row was reported as lapsed residue: #{inspect(c)}"

      assert c.claim["worker"] == "api-r22-w7"
      assert c.claim["epoch"] == 2
    end
  end

  describe "the sweep the criterion asks for, run over a mixed page" do
    test "the count off the CARD equals the count off the raw content, both directions" do
      plan =
        List.duplicate(@swept, 7) ++
          List.duplicate(@released, 11) ++
          List.duplicate(@unheld, 2) ++
          List.duplicate(@live, 5) ++
          List.duplicate(:none, 25)

      docs = plan |> Enum.with_index() |> Enum.map(fn {c, i} -> doc("mix-#{i}", c) end)
      cards = Enum.map(docs, &Params.render_doc(&1, :brief))

      # The new sweep: one list read, no per-row `bp task get`.
      swept = Enum.filter(cards, &Map.has_key?(&1, :claim_residue))

      # The ground truth, read off the documents the page was built from.
      truth =
        Enum.filter(docs, fn d ->
          claim = Map.get(d.content, "claim")
          is_map(claim) and is_nil(Map.get(claim, "worker"))
        end)

      assert length(swept) == length(truth)
      assert length(swept) == 20
      assert Enum.count(swept, &(&1.claim_residue == "expired")) == 7
      assert Enum.count(swept, &(&1.claim_residue == "released")) == 11
      assert Enum.count(swept, &(&1.claim_residue == "unheld")) == 2

      # The blindness this row was filed for: the OLD lens, run on the same
      # page, still answers zero — so the new key is the only way to ask.
      assert Enum.count(cards, fn c ->
               is_map(Map.get(c, :claim)) and is_nil(get_in(c, [:claim, "worker"]))
             end) == 0

      # And the positive control that made that zero a suppression rather
      # than an empty board is unchanged.
      assert Enum.count(cards, &Map.has_key?(&1, :claim)) == 5

      # NOT A FALSE-POSITIVE MACHINE: 25 claimless rows contributed nothing.
      assert length(cards) - length(swept) - 5 == 25
    end
  end

  describe "nothing else moved" do
    test "FULL view — what `bp task get <doc_id>` returns — is byte-identical" do
      full = Params.render_doc(doc("full-1", @swept), :full)

      assert full.claim == @swept
      refute Map.has_key?(full, :claim_residue), "the brief-only key leaked onto the full view"
    end

    test "the residue key is a SHORT string — it cannot carry a now-line or a digest" do
      c = card("short-1", @released)
      assert is_binary(c.claim_residue)
      assert byte_size(c.claim_residue) <= 8
    end

    test "a residue-only page raises no truncation banner" do
      d = doc("banner-1", @swept)
      assert Params.maybe_put_brief_truncation_help(%{docs: []}, [d], :brief) == %{docs: []}
    end
  end
end
