defmodule Barkpark.Content.CascadeWriteAtomicityTest do
  @moduledoc """
  task-5e4470a96f0a2e55: two DERIVED writes, the reference strip
  (`Edges.disconnect_one_source/5`, reached through `Content.disconnect_references/3`)
  and the sheet-embed refresh (`Sheets.refresh_doc_sheet_snapshots/3`), must
  land the row change and its `mutation_events` row together.

  Each piped a bare `Repo.update` into `Broadcast.tap_broadcast`, so the update
  auto-committed before `save_event` ran. A fault on the event insert left the
  referencer stripped, or the paper rewritten, with no event.

  The fault is the `RETURN NULL` trigger from
  `Barkpark.Content.PublishEventAtomicityTest` (its moduledoc says why not a
  `RAISE`): `save_event`'s `Repo.insert!` raises `Ecto.StaleEntryError` with the
  Postgres transaction still healthy. Under the sandbox, "unchanged" means the
  update shared the event's transaction and rolled back with it.

  `async: false`: `CREATE TRIGGER` takes an ACCESS EXCLUSIVE lock on
  `mutation_events`, on every mutation's write path.
  """
  # sync: `CREATE TRIGGER` takes an ACCESS EXCLUSIVE lock on `mutation_events`, on every mutation's write path
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.{Document, MutationEvent, Sheets}
  alias Barkpark.Repo

  @dataset "cascade_atomicity_test"

  setup do
    Content.upsert_schema(
      %{"name" => "target", "title" => "Target", "visibility" => "public", "fields" => []},
      @dataset
    )

    Content.upsert_schema(
      %{
        "name" => "pointer",
        "title" => "Pointer",
        "visibility" => "public",
        "fields" => [%{"name" => "rel", "type" => "reference", "refType" => "target"}]
      },
      @dataset
    )

    :ok
  end

  defp uid(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp publish!(type, id, attrs \\ %{}) do
    {:ok, _} =
      Content.create_document(type, Map.merge(%{"_id" => id, "title" => id}, attrs), @dataset)

    {:ok, doc} = Content.publish_document(id, type, @dataset)
    doc
  end

  defp break_mutation_events! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION bp_test_swallow_mutation_event() RETURNS trigger AS $fn$
    BEGIN
      RETURN NULL;
    END;
    $fn$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER bp_test_swallow_mutation_event_trg
    BEFORE INSERT ON mutation_events
    FOR EACH ROW EXECUTE FUNCTION bp_test_swallow_mutation_event()
    """)

    :ok
  end

  defp event_count(doc_id) do
    Repo.aggregate(from(e in MutationEvent, where: e.doc_id == ^doc_id), :count)
  end

  defp rel_of(pointer_id) do
    {:ok, doc} = Content.get_document(pointer_id, "pointer", @dataset)
    Map.get(doc.content || %{}, "rel")
  end

  describe "reference strip (Content.disconnect_references/3)" do
    test "a save_event fault leaves the referencer's reference in place" do
      target = uid("tgt")
      pointer = uid("ptr")
      publish!("target", target)
      publish!("pointer", pointer, %{"rel" => target})
      break_mutation_events!()

      assert_raise Ecto.StaleEntryError, fn ->
        Content.disconnect_references(target, @dataset)
      end

      assert rel_of(pointer) == target,
             "the strip survived a failed mutation_event insert — in production it is " <>
               "committed and no SSE/webhook consumer ever learns of it"
    end

    test "CONTROL: without the fault the reference is stripped with one event" do
      target = uid("tgt")
      pointer = uid("ptr")
      publish!("target", target)
      publish!("pointer", pointer, %{"rel" => target})
      before = event_count(pointer)

      Content.disconnect_references(target, @dataset)

      assert rel_of(pointer) == nil
      assert event_count(pointer) == before + 1
    end
  end

  describe "sheet-embed refresh (Sheets.refresh_doc_sheet_snapshots/3)" do
    defp embedder!(sheet_ref) do
      doc_id = uid("paper")

      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          "doc_id" => doc_id,
          "type" => "paper",
          "dataset" => @dataset,
          "title" => doc_id,
          "status" => "draft",
          "content" => %{"blocks" => [%{"type" => "sheet", "ref" => sheet_ref}]},
          "rev" => "rev-" <> doc_id
        })
        |> Repo.insert()

      doc
    end

    defp snapshot_of(%Document{id: id}) do
      Repo.get!(Document, id).content["blocks"] |> hd() |> Map.get("snapshot")
    end

    test "a save_event fault leaves the embedding paper unchanged" do
      doc = embedder!("sheet-a")
      break_mutation_events!()

      assert_raise Ecto.StaleEntryError, fn ->
        Sheets.refresh_doc_sheet_snapshots(doc, ["sheet-a"], %{})
      end

      assert snapshot_of(doc) == nil,
             "the embed rewrite survived a failed mutation_event insert"
    end

    test "CONTROL: without the fault the paper is rewritten with one event" do
      doc = embedder!("sheet-b")

      assert :rewritten = Sheets.refresh_doc_sheet_snapshots(doc, ["sheet-b"], %{})

      assert %{"rows" => []} = snapshot_of(doc)
      assert event_count(doc.doc_id) == 1
    end
  end
end
