defmodule Barkpark.Tasks.EventsLandedPayloadTest do
  @moduledoc """
  `bp task events --payload` carries the LANDING MARK — and carries the next
  verb's stamp too, without anyone remembering to list it.

  ## The defect these arms close

  `Tasks.Landed` has stamped a `landed_mark` — `%{landed, criterion, flipped}` —
  onto its `task.landed` mutation_event since the verb shipped
  (`landed.ex:197`). `Tasks.Events.replay_since/3` projected the typed payload
  through a HAND-KEPT whitelist, `~w(staged reparented fenced lease_expired)`,
  and `landed_mark` was never added to it. So every `task.landed` event on the
  feed carried an EMPTY payload — 20 of them across 16 docs, measured
  2026-09-06 over the verb's whole 81,564-event lifetime.

  That is the worst verb to be blind on. `bp task landed` holds NO claim, NO
  worker id and NO epoch — it is the write path with no holder to interrogate
  afterwards, which makes its event the only durable account of WHICH criterion
  a landing notice flipped and WHAT it claimed. Without it a sweep has to
  re-read every named document, or join on the `--note` text appearing
  byte-identically in two places, which a later `close --set criteria` silently
  breaks.

  ## Which shape of criterion 1 this is: DERIVED (the first branch)

  The row allowed either a derived projection or an enumeration test over
  writer-kinds. This is the derived one, because the enumeration branch still
  leaves the feed WRONG until someone reads the red — and the whitelist was
  never load-bearing in the first place. What actually bounds the payload is
  the ENVELOPE SUBTRACTION, not the list of verbs: `content` (the whole row
  blob) is an envelope key and `caller_token_id` is an audit key, and those two
  are the entire reason the projection could not just hand back `document`.

  So both lists now live next to the WRITER that produces them
  (`Internal.envelope_keys/0`, `Internal.audit_keys/0`, both fed by the single
  `Internal.envelope_document/1` that every task event — including
  `TtlSweeper`'s two hand-rolled inserts — builds from), and the payload is
  `document` minus them. Anything else in `document` got there because a write
  path merged a typed `extra_document`; that is the definition of a payload.

  ## What is proven here

    * criterion 0 — a real `Tasks.Landed.record/2` with `--criterion N --note X`
      produces a feed row whose payload answers BOTH questions from the feed
      alone: the criterion index it flipped, and the note it claimed it with.
    * criterion 1 — the derivation: an event stamping a typed key NO list
      anywhere mentions is projected anyway, while the envelope and the audit
      stamp are still excluded; and the reader's exclusion list is checked
      against what the writer actually writes, so the two cannot drift.
    * criterion 2 — see the PR body: re-introducing a per-verb exclusion for
      `landed_mark` reds the criterion-0 arms here while
      `events_staged_payload_test.exs` stays green.
  """

  use Barkpark.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Tasks.{Events, Internal, Landed}

  @dataset "production"
  @note "landed via PR #16622 — the recovery channel now carries this sentence"

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

  # The keyset baseline: the max mutation_events id BEFORE the fixture writes.
  # Every agent shares ONE test database and a page is 500 events, so replaying
  # from 0 would page our own rows off the front.
  defp baseline, do: Repo.one(from(e in MutationEvent, select: max(e.id))) || 0

  defp task!(scope) do
    doc_id = uniq("landed-payload")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "acceptance_criteria" => [
              %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fix"},
              %{"criterion" => "LEAD-OWNED: PR merged to main", "met" => false, "evidence" => ""}
            ],
            "lifecycle_status" => "open"
          }
        },
        @dataset,
        scope
      )

    doc
  end

  defp rows_for(baseline, doc_id, event) do
    @dataset
    |> Events.replay_since(baseline, payload: true, limit: 500)
    |> Enum.filter(&(&1.doc_id == doc_id and &1.event == event))
  end

  describe "criterion 0 — the landing mark reaches the feed" do
    test "payload.landed_mark carries the criterion index AND the note", %{scope: scope} do
      doc = task!(scope)
      since = baseline()

      {:ok, _} = Landed.record(doc.id, criterion: 1, note: @note, commit: "deadbee")

      [row] = rows_for(since, doc.doc_id, "task.landed")

      mark = get_in(row, [:payload, "landed_mark"])

      # RED BEFORE: `@payload_keys` was a whitelist without `landed_mark`, so
      # `project_payload/1` narrowed the document to `%{}` and the row carried
      # no `:payload` key at all — `mark` was nil and every assertion below
      # failed on the FIRST one, exactly as the 20 events in the backlog did.
      assert is_map(mark),
             "the landing mark is not on the feed: #{inspect(Map.get(row, :payload))}"

      # "Which criterion did this landing notice flip" — answered from the feed.
      assert mark["criterion"] == 1
      assert mark["flipped"] == true

      # "And what did it claim" — answered from the feed.
      assert mark["landed"]["notes"] == [@note]
      assert mark["landed"]["commits"] == ["deadbee"]
    end

    test "the envelope and the audit stamp still stay off the wire", %{scope: scope} do
      doc = task!(scope)
      since = baseline()

      {:ok, _} = Landed.record(doc.id, criterion: 1, note: @note, caller_token_id: "tok-abc")

      [row] = rows_for(since, doc.doc_id, "task.landed")

      assert Map.keys(row) |> Enum.sort() == [:at, :doc_id, :event, :id, :payload, :rev]
      assert Map.keys(row.payload) == ["landed_mark"]
      refute Map.has_key?(row, :document)

      # The audit stamp WAS written on this event (that is what makes this arm
      # discriminating rather than vacuous) and is still excluded.
      ev =
        Repo.one!(
          from(e in MutationEvent,
            where: e.doc_id == ^doc.doc_id and e.mutation == "task.landed"
          )
        )

      assert ev.document["caller_token_id"] == "tok-abc"
      refute Map.has_key?(row.payload, "caller_token_id")
      refute Map.has_key?(row.payload, "content")
    end

    test "the default (no opt-in) shape is byte-for-byte unchanged", %{scope: scope} do
      doc = task!(scope)
      since = baseline()

      {:ok, _} = Landed.record(doc.id, criterion: 1, note: @note)

      [row] =
        @dataset
        |> Events.replay_since(since, limit: 500)
        |> Enum.filter(&(&1.doc_id == doc.doc_id and &1.event == "task.landed"))

      assert Map.keys(row) |> Enum.sort() == [:at, :doc_id, :event, :id, :rev]
    end
  end

  describe "criterion 1 — the projection is DERIVED from what the writer stores" do
    test "a typed stamp NO list mentions is projected the moment it is written", %{scope: scope} do
      doc = task!(scope)
      stored = Repo.get!(Document, doc.id)
      since = baseline()

      # The next verb, spelled as a verb that does not exist. Nothing in
      # `Tasks.Events` names this key — that is the point.
      future_key = "verb_that_did_not_exist_when_the_feed_was_written"

      refute future_key in Events.non_payload_keys()

      Internal.insert_mutation_event!(
        stored,
        "task.future_verb",
        stored.rev,
        "api",
        %{
          future_key => %{"criterion" => 3, "note" => "a stamp nobody remembered to whitelist"},
          "caller_token_id" => "tok-future"
        }
      )

      [row] = rows_for(since, doc.doc_id, "task.future_verb")

      assert get_in(row, [:payload, future_key, "criterion"]) == 3,
             "a new writer's typed stamp did not reach the feed: #{inspect(row)}"

      # Derived does NOT mean "hand back the document": the envelope half and
      # the audit stamp are still subtracted.
      assert Map.keys(row.payload) == [future_key]
    end

    test "the reader's exclusion list is exactly what the writer writes", %{scope: scope} do
      doc = task!(scope)
      stored = Repo.get!(Document, doc.id)

      # 1. The exclusion list IS the writer's two lists — not a third copy.
      assert Events.non_payload_keys() ==
               Internal.envelope_keys() ++ Internal.audit_keys()

      # 2. And the writer's envelope list is not stale relative to the envelope
      #    it actually writes. Drop a key from `envelope_document/1` without
      #    dropping it from `envelope_keys/0` (or vice versa) and this reds —
      #    which is the drift that would silently leak `content` onto the feed.
      assert stored |> Internal.envelope_document() |> Map.keys() |> Enum.sort() ==
               Enum.sort(Internal.envelope_keys())

      # 3. Non-vacuity: the envelope really does carry the blob the opt-in
      #    exists to keep off a poll response.
      assert "content" in Internal.envelope_keys()
      assert "caller_token_id" in Internal.audit_keys()
    end
  end
end
