defmodule Barkpark.Plugins.Github.LinkPutErasureTest do
  @moduledoc """
  The AUTOMATIC Link.put collapse cannot erase a stamped proof
  (pds-bl-github-linkput-auto-publish-erasure) — the wave-26 scratchpad probe
  re-authored under api/test/ so it can never evaporate again.

  The mechanism, from the wave-26 probe: a draft twin minted DURING an active
  claim carries the claim verbatim, so it sails past `stale_claim?/2`; a later
  `bp task stamp` writes the PUBLISHED row directly and never rebases the
  draft; the automatic bookkeeping collapse (`Link.put/4` → republish) then
  used to replace the published content WHOLESALE — `met: true` back to
  `false`, evidence to `""`, `{:ok, _}` returned, nothing logged.

  Today the criteria fence at the publish door (`gate_task_publish/2`,
  source-blind since pds-bl-sync-source-bypasses-publish-door; `:github`
  always fell through to it) REFUSES that collapse, and the rejection is
  LOGGED with the task id and the exact proof it would have destroyed
  (authoring-excellence D23). These tests pin all of it at the chokepoint
  BOTH automatic arms funnel through:

    * MirrorJob arm — `mirror_job.ex` `stamp/4` → `Link.put/4`. The arm that
      CAN reach a `pds-*` row (it mirrors task documents wholesale).
    * inbound-webhook detach arm — `inbound_events.ex` `detach/6` →
      `Link.put(doc_id, dataset, %{"state" => "detached"}, opts)`. Only ever
      addresses `gh-<num>` intake tasks, so it cannot reach a `pds-*` row —
      but it is fence-covered identically, and the detach payload shape is
      exercised below on its own.
  """
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Plugins.Github.Link
  alias Barkpark.Tasks.Stamp

  @dataset "linkput_erasure_test"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)
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

  # The wave-26 recipe, exactly: publish → claim → mint the draft twin FROM the
  # current published content (claim rides along verbatim, criteria pre-stamp)
  # → stamp the PUBLISHED row. Returns {doc_id, epoch}.
  defp stamped_task_with_stale_draft!(prefix, scope) do
    doc_id = uniq(prefix)

    content =
      %{
        "kind" => "task",
        "lifecycle_status" => "open",
        "acceptance_criteria" => [
          %{"criterion" => "it works", "met" => false, "evidence" => ""}
        ]
      }
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())

    {:ok, _task} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => "Erasure probe #{doc_id}", "content" => content},
        @dataset,
        scope
      )

    {:ok, _pub} = Content.publish_document(doc_id, "task", @dataset, scope)
    {:ok, claimed} = Tasks.claim_by_id(doc_id, "lp-worker", scope)
    epoch = claimed.content["claim"]["epoch"]

    # The stale draft twin: derived from the CURRENT published content (claim
    # verbatim — it will sail past stale_claim?/2), minted BEFORE the stamp.
    # Minted at the WRITER SEAM, not through a mutate `patch`: since
    # task-b9c618482e688500 a bare-id `patch` on a `type:task` resolves
    # PUBLISHED-first and LANDS there, so it no longer leaves a twin behind to
    # collapse. The twin this file needs — derived from the published content,
    # claim verbatim, minted pre-stamp — is byte-identical either way.
    {:ok, published} = Content.get_document(doc_id, "task", @dataset, scope)

    {:ok, _twin} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => published.title,
          "content" =>
            Map.put(
              published.content,
              "description",
              "The github mirror touched this row's bookkeeping during an active claim."
            )
        },
        @dataset,
        scope
      )

    # The stamp writes the PUBLISHED row directly; the draft never rebases.
    # The stamp addresses the PUBLISHED row (the draft row died at publish).
    assert {:ok, _} =
             Stamp.stamp(claimed.id, "lp-worker",
               observed_epoch: epoch,
               criterion: 0,
               criterion_text: "it works",
               outcome: {:met, "run output pasted"}
             )

    doc_id
  end

  defp published_criteria!(doc_id, scope) do
    {:ok, pub} = Content.get_document(doc_id, "task", @dataset, scope)
    pub.content["acceptance_criteria"]
  end

  test "MIRRORJOB SHAPE: the automatic bookkeeping Link.put cannot erase the stamp — " <>
         "refused at the publish door, LOGGED with the id and the proof at stake",
       %{scope: scope} do
    doc_id = stamped_task_with_stale_draft!("lp-mirror", scope)

    {result, log} =
      with_log(fn ->
        Link.put(doc_id, @dataset, %{"repo" => "o/r", "issue" => 7, "state" => "open"}, scope)
      end)

    # The put keeps its contract (the bookkeeping landed on the draft)…
    assert {:ok, _doc} = result

    # …the published proof SURVIVED the automatic collapse…
    assert [%{"met" => true, "evidence" => "run output pasted"}] =
             published_criteria!(doc_id, scope)

    # …and the refusal is LOGGED with the task id and what it would have
    # overwritten (criterion 1 of the row) — not the old silent {:ok, _}.
    assert log =~ "draft-twin collapse publish for #{doc_id} rejected"
    assert log =~ "clear the `met: true` flag"
    assert log =~ "acceptance criterion 0"
  end

  test "DETACH SHAPE: the inbound-webhook arm's exact payload is fence-covered identically",
       %{scope: scope} do
    doc_id = stamped_task_with_stale_draft!("lp-detach", scope)

    {result, log} =
      with_log(fn ->
        # inbound_events.ex detach/6 verbatim: Link.put(doc_id, dataset,
        # %{"state" => "detached"}, opts)
        Link.put(doc_id, @dataset, %{"state" => "detached"}, scope)
      end)

    assert {:ok, _} = result

    assert [%{"met" => true, "evidence" => "run output pasted"}] =
             published_criteria!(doc_id, scope)

    assert log =~ "draft-twin collapse publish for #{doc_id} rejected"
  end

  test "control: with NO stale draft the collapse still converges cleanly (the fence " <>
         "refuses erasure, not bookkeeping)",
       %{scope: scope} do
    doc_id = uniq("lp-clean")

    content =
      %{"kind" => "task", "lifecycle_status" => "open"}
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())

    {:ok, _} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => "Clean probe #{doc_id}", "content" => content},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, "task", @dataset, scope)

    {result, log} =
      with_log(fn ->
        Link.put(doc_id, @dataset, %{"repo" => "o/r", "synced_rev" => "abc"}, scope)
      end)

    assert {:ok, doc} = result
    assert doc.content["github"]["repo"] == "o/r"
    refute log =~ "collapse publish"
  end
end
