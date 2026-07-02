defmodule Barkpark.Content.ValuerefDriftTest do
  @moduledoc """
  lvw-t2 — stale-drift detection + the accept-baseline affordance (wire §8 as
  amended; strategy §3; D4 ratified).

  Drift is the ONE comparison — pinned `fallback` literal vs the value the
  pre-resolve pass resolved — made where the pass injects its result into the
  render. There is NO standalone checker (the `Validation.Checker` seam is a
  pure value-validation behaviour with no Repo access and structurally cannot
  resolve `target.field` on another document). Covered here:

    1. End-to-end DRIFT vs RESOLVED off the real pre-resolve pass: a stale
       pinned literal marks `drift`, a matching one stays `resolved`
       (the non-drift guard — no vacuous all-drift pass).
    2. DANGLING vs DRIFT: an unresolvable target (deleted / never published)
       is `dangling` — drift uncomputable — never `drift`.
    3. PROTECTIVE (criterion 2): public/anonymous drift compares against the
       PUBLISHED canonical value only — a diverged draft twin cannot make a
       published-matching pin look drifted (#746's anonymous+published-only
       resolution guarantees it; this test pins the guarantee).
    4. ACCEPT-BASELINE (D4): an ifRev-guarded, fallback-ONLY patch-block
       batch through `apply_paper_block_ops/4` (never hand-rolled writes)
       that re-pins `fallback` + the D6 dual-written text child, preserves
       `as`/`label`/unrelated nodes, records provenance (revision action
       `valueref-accept-baseline` + actor), and surfaces a rev race as the
       retry-able `:precondition_failed`.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Revision}
  alias Barkpark.PortableDoc.Render
  alias Barkpark.Repo

  @dataset "valueref_drift_test"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "metric",
          "title" => "Metric",
          "visibility" => "public",
          "fields" => [%{"name" => "launch_delay", "type" => "string"}]
        },
        @dataset
      )

    :ok
  end

  defp metric!(id, content) do
    {:ok, _} =
      Content.create_document(
        "metric",
        Map.merge(%{"_id" => id, "title" => "Metric #{id}"}, content),
        @dataset
      )

    {:ok, _} = Content.publish_document(id, "metric", @dataset)
    id
  end

  defp valueref(target, fallback) do
    %{
      "type" => "valueref",
      "target" => target,
      "field" => "launch_delay",
      "as" => "duration",
      "label" => "launch delay",
      "fallback" => fallback,
      "children" => [%{"type" => "text", "value" => fallback}]
    }
  end

  defp paragraph(id, inlines), do: %{"id" => id, "type" => "paragraph", "content" => inlines}

  defp render_with_pass(blocks, opts \\ []) do
    values = Content.resolve_values_in_blocks(blocks, @dataset, opts)
    Enum.map_join(blocks, &Render.render_block(&1, %{values: values}))
  end

  # ── drift / dangling states off the REAL pre-resolve pass ────────────────

  test "stale pin marks DRIFT, matching pin stays RESOLVED — one comparison, no all-drift vacuity" do
    metric!("m-drift", %{"launch_delay" => "6 weeks"})

    html =
      render_with_pass([
        paragraph("b1", [valueref("m-drift", "12 weeks")]),
        paragraph("b2", [valueref("m-drift", "6 weeks")])
      ])

    # The stale pin ("12 weeks" vs canonical "6 weeks") drifts and still shows
    # the RESOLVED value; the matching pin is plain resolved.
    assert html =~ ~s(data-valueref-state="drift")
    assert html =~ ~s(data-valueref-state="resolved")
    refute html =~ ~s(data-valueref-state="dangling")
  end

  test "an unresolvable target is DANGLING (drift uncomputable), never DRIFT" do
    html = render_with_pass([paragraph("b1", [valueref("m-never-existed", "12 weeks")])])

    assert html =~ ~s(data-valueref-state="dangling")
    refute html =~ ~s(data-valueref-state="drift")
    # The pinned literal still shows — never a blank.
    assert html =~ "12 weeks"
  end

  # ── criterion 2 (PROTECTIVE): public drift is published-value drift ───────

  test "public/anonymous drift compares against the PUBLISHED value — a diverged draft twin cannot flag it" do
    metric!("m-pub", %{"launch_delay" => "12 weeks"})

    # The "edited after publish" state: a diverged draft twin alongside the
    # published row.
    %Document{}
    |> Document.changeset(%{
      doc_id: "drafts.m-pub",
      type: "metric",
      dataset: @dataset,
      title: "Metric m-pub",
      status: "draft",
      content: %{"launch_delay" => "6 weeks (draft)"},
      rev: Ecto.UUID.generate()
    })
    |> Repo.insert!()

    blocks = [paragraph("b1", [valueref("m-pub", "12 weeks")])]

    # Anonymous/public palette (the D5 gate BulldocsLive passes): the pin
    # matches the PUBLISHED value ⇒ resolved, NOT drift — the draft twin's
    # divergence must not leak into public drift.
    html = render_with_pass(blocks, published_only: true)
    assert html =~ ~s(data-valueref-state="resolved")
    refute html =~ ~s(data-valueref-state="drift")

    # And a draft-ONLY target on the public palette is DANGLING, never a
    # drift computed against the unpublished value.
    {:ok, _} =
      Content.create_document(
        "metric",
        %{"_id" => "m-draft-only", "title" => "Draft only", "launch_delay" => "6 weeks"},
        @dataset
      )

    draft_html =
      render_with_pass([paragraph("b1", [valueref("m-draft-only", "12 weeks")])],
        published_only: true
      )

    assert draft_html =~ ~s(data-valueref-state="dangling")
    refute draft_html =~ ~s(data-valueref-state="drift")
  end

  # ── accept-baseline (D4) ──────────────────────────────────────────────────

  describe "accept_valueref_baseline/6" do
    defp paper!(slug, blocks) do
      {:ok, doc} = Content.upsert_paper(%{slug: slug, blocks: blocks, dataset: @dataset})
      doc
    end

    defp paper_rev(slug) do
      get_in(Content.get_paper(slug, @dataset).content, ["rev"])
    end

    defp paper_blocks(slug) do
      get_in(Content.get_paper(slug, @dataset).content, ["blocks"])
    end

    test "re-pins fallback + D6 child on exactly the matching nodes, preserves everything else, with provenance" do
      metric!("m-accept", %{"launch_delay" => "6 weeks"})
      metric!("m-other", %{"launch_delay" => "9 weeks"})

      paper!("p-accept", [
        paragraph("b1", [
          %{"type" => "text", "value" => "Delay: "},
          valueref("m-accept", "12 weeks")
        ]),
        # Same target+field but a DIFFERENT pinned literal — a different
        # baseline, NOT addressed by this accept.
        paragraph("b2", [valueref("m-accept", "10 weeks")]),
        # Different target entirely — untouched.
        paragraph("b3", [valueref("m-other", "12 weeks")])
      ])

      assert {:ok, %{op_count: 1}} =
               Content.accept_valueref_baseline(
                 "p-accept",
                 "m-accept",
                 "launch_delay",
                 "12 weeks",
                 @dataset,
                 if_rev: paper_rev("p-accept"),
                 actor_user_id: "user-w11"
               )

      [b1, b2, b3] = paper_blocks("p-accept")

      # b1: the matching node is re-pinned — fallback AND the D6 text child —
      # while as/label round-trip untouched and sibling text survives (the
      # patch resent the whole content array).
      [text, accepted] = b1["content"]
      assert text == %{"type" => "text", "value" => "Delay: "}
      assert accepted["fallback"] == "6 weeks"
      assert accepted["children"] == [%{"type" => "text", "value" => "6 weeks"}]
      assert accepted["as"] == "duration"
      assert accepted["label"] == "launch delay"

      # b2 (different baseline) and b3 (different target): byte-untouched.
      assert [%{"fallback" => "10 weeks"}] = b2["content"]
      assert [%{"fallback" => "12 weeks"}] = b3["content"]

      # Provenance: one revision row carrying the action + the actor.
      assert %Revision{actor_user_id: "user-w11"} =
               Repo.get_by(Revision,
                 action: "valueref-accept-baseline",
                 doc_id: "p-accept",
                 dataset: @dataset
               )
    end

    test "a stale ifRev is a retry-able :precondition_failed and writes NOTHING" do
      metric!("m-race", %{"launch_delay" => "6 weeks"})
      paper!("p-race", [paragraph("b1", [valueref("m-race", "12 weeks")])])

      before = paper_blocks("p-race")

      assert {:error, :precondition_failed} =
               Content.accept_valueref_baseline(
                 "p-race",
                 "m-race",
                 "launch_delay",
                 "12 weeks",
                 @dataset,
                 if_rev: paper_rev("p-race") + 41
               )

      assert paper_blocks("p-race") == before
      refute Repo.get_by(Revision, action: "valueref-accept-baseline", doc_id: "p-race")
    end

    test "not drifted / dangling / empty pin: nothing to accept, nothing written" do
      metric!("m-sync", %{"launch_delay" => "12 weeks"})
      paper!("p-guard", [paragraph("b1", [valueref("m-sync", "12 weeks")])])

      rev = paper_rev("p-guard")

      # Pin already matches the canonical value.
      assert {:error, :not_drifted} =
               Content.accept_valueref_baseline(
                 "p-guard",
                 "m-sync",
                 "launch_delay",
                 "12 weeks",
                 @dataset,
                 if_rev: rev
               )

      # Unresolvable target — drift uncomputable.
      assert {:error, :dangling} =
               Content.accept_valueref_baseline(
                 "p-guard",
                 "m-gone",
                 "launch_delay",
                 "12 weeks",
                 @dataset,
                 if_rev: rev
               )

      # No pinned baseline (fallback "") — nothing to accept.
      assert {:error, :not_drifted} =
               Content.accept_valueref_baseline(
                 "p-guard",
                 "m-sync",
                 "launch_delay",
                 "",
                 @dataset,
                 if_rev: rev
               )

      assert paper_rev("p-guard") == rev
    end

    test "unknown paper is :not_found" do
      assert {:error, :not_found} =
               Content.accept_valueref_baseline(
                 "p-missing",
                 "m",
                 "launch_delay",
                 "12 weeks",
                 @dataset,
                 []
               )
    end
  end
end
