defmodule Barkpark.Content.FormsFieldExpectTest do
  @moduledoc """
  task-61c8a3663106486b: `Forms.upsert_draft/6` with `:field_expect` writes
  only while each named field still holds the value the caller read. It is
  checked under the save's own lock against the row the save reads, so another
  editor's save that landed after the caller's read stays, and nothing is
  written. The desk's value undo (`Desk.DocUndo`) is the caller.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Forms

  @ds "field-expect"
  @fields [
    %{"name" => "title", "type" => "string"},
    %{"name" => "choice", "type" => "string"},
    %{"name" => "note", "type" => "string"}
  ]
  @schema %{fields: @fields}

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "fpost", "title" => "Post", "visibility" => "public", "fields" => @fields},
        @ds
      )

    {:ok, doc} =
      Content.create_document(
        "fpost",
        %{
          "doc_id" => "drafts.fe-1",
          "title" => "T",
          "content" => %{"choice" => "b", "note" => "n"}
        },
        @ds
      )

    %{doc: doc}
  end

  defp stored do
    {:ok, doc} = Content.get_document("drafts.fe-1", "fpost", @ds)
    doc
  end

  # Another editor's save, straight to the store, after this one read the doc.
  defp theirs(changes) do
    now = stored()

    {:ok, _} =
      Content.upsert_document(
        "fpost",
        %{
          "doc_id" => "drafts.fe-1",
          "title" => now.title,
          "content" => Map.merge(now.content, changes)
        },
        @ds
      )
  end

  test "a field another editor saved since the read is refused, and nothing is written", %{
    doc: doc
  } do
    theirs(%{"choice" => "a"})
    before = stored()

    assert {:error, {:field_changed, ["choice"]}} =
             Forms.upsert_draft(doc, "fpost", @schema, %{"choice" => "c"}, @ds,
               field_expect: %{"choice" => "b"}
             )

    assert stored().content["choice"] == "a"
    assert stored().rev == before.rev
  end

  test "the title column is checked too", %{doc: doc} do
    {:ok, _} =
      Content.upsert_document(
        "fpost",
        %{"doc_id" => "drafts.fe-1", "title" => "Theirs", "content" => stored().content},
        @ds
      )

    assert {:error, {:field_changed, ["title"]}} =
             Forms.upsert_draft(doc, "fpost", @schema, %{"title" => "Mine"}, @ds,
               field_expect: %{"title" => "T"}
             )

    assert stored().title == "Theirs"
  end

  test "a field still as read is written; a sibling another editor saved since stays", %{doc: doc} do
    theirs(%{"note" => "theirs"})

    assert {:ok, saved, _} =
             Forms.upsert_draft(doc, "fpost", @schema, %{"choice" => "c"}, @ds,
               field_expect: %{"choice" => "b"}
             )

    assert saved.content["choice"] == "c"
    assert stored().content == %{"choice" => "c", "note" => "theirs"}
  end
end
