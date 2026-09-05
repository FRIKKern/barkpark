defmodule Barkpark.Content.Papers.DocumentReplayTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Broadcast
  alias Barkpark.Repo
  alias Barkpark.Repo.IdempotencyStore

  @dataset "production"
  @doc_type "beta_replay_post"
  @doc_id "beta-replay-document"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Beta replay post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title"},
            %{"kind" => "region", "name" => "body"}
          ]
        },
        @dataset
      )

    {:ok, doc} =
      Content.create_document(
        @doc_type,
        %{"doc_id" => @doc_id, "title" => "Original title"},
        @dataset
      )

    {:ok, doc: doc}
  end

  test "a lost Beta acknowledgement replays the original receipt without another write", %{
    doc: doc
  } do
    request_id = Ecto.UUID.generate()
    op = title_patch(doc, "Saved once")

    Phoenix.PubSub.subscribe(
      Barkpark.PubSub,
      Broadcast.doc_topic(@doc_id, @doc_type, doc.workspace_id, @dataset)
    )

    assert {:ok, receipt, :applied} =
             Content.apply_document_block_op_once(
               doc.doc_id,
               @doc_type,
               op,
               @dataset,
               request_id,
               "user:beta-replay",
               if_rev: doc.rev
             )

    assert_receive {:doc_updated, %{document: %{"_rev" => committed_rev}}}
    assert committed_rev == receipt.rev

    assert {:ok, ^receipt, :replayed} =
             Content.apply_document_block_op_once(
               doc.doc_id,
               @doc_type,
               op,
               @dataset,
               request_id,
               "user:beta-replay",
               if_rev: doc.rev
             )

    refute_receive {:doc_updated, _}, 50

    {:ok, stored} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    assert stored.rev == committed_rev
    assert stored.content["title"] == "Saved once"

    assert Repo.aggregate(
             from(k in IdempotencyStore.Key, where: like(k.scope, "document_op:v1:%")),
             :count
           ) == 1
  end

  test "request reuse with a changed payload or revision fails closed", %{doc: doc} do
    request_id = Ecto.UUID.generate()
    first = title_patch(doc, "First payload")

    assert {:ok, receipt, :applied} =
             Content.apply_document_block_op_once(
               doc.doc_id,
               @doc_type,
               first,
               @dataset,
               request_id,
               "user:beta-replay",
               if_rev: doc.rev
             )

    assert {:error, :idempotency_payload_mismatch} =
             Content.apply_document_block_op_once(
               doc.doc_id,
               @doc_type,
               title_patch(doc, "Different payload"),
               @dataset,
               request_id,
               "user:beta-replay",
               if_rev: doc.rev
             )

    assert {:error, :idempotency_payload_mismatch} =
             Content.apply_document_block_op_once(
               doc.doc_id,
               @doc_type,
               first,
               @dataset,
               request_id,
               "user:beta-replay",
               if_rev: receipt.rev
             )

    {:ok, stored} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    assert stored.rev == receipt.rev
    assert stored.content["title"] == "First payload"
  end

  test "receipt completion failure rolls back an existing draft update and queued effects", %{
    doc: doc
  } do
    request_id = Ecto.UUID.generate()
    install_after_write_probe!()
    assert doc.doc_id == Content.draft_id(@doc_id)

    Phoenix.PubSub.subscribe(
      Barkpark.PubSub,
      Broadcast.doc_topic(@doc_id, @doc_type, doc.workspace_id, @dataset)
    )

    assert {:error, :idempotency_completion_failed} =
             Content.apply_document_block_op_once(
               doc.doc_id,
               @doc_type,
               title_patch(doc, "Must roll back"),
               @dataset,
               request_id,
               "user:beta-rollback",
               if_rev: doc.rev,
               before_idempotency_complete: fn ->
                 Repo.delete_all(
                   from(k in IdempotencyStore.Key,
                     where: like(k.scope, "document_op:v1:%")
                   )
                 )
               end
             )

    refute_receive {:doc_updated, _}, 50
    refute_receive %{event: :after_save}, 50

    {:ok, unchanged} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    assert unchanged.id == doc.id
    assert unchanged.rev == doc.rev
    assert unchanged.content["title"] == "Original title"

    assert Repo.aggregate(
             from(k in IdempotencyStore.Key, where: like(k.scope, "document_op:v1:%")),
             :count
           ) == 0
  end

  test "published-to-draft receipt failure creates no draft and emits no after-save effect" do
    {:ok, published} = Content.publish_document(@doc_id, @doc_type, @dataset)
    install_after_write_probe!()

    Phoenix.PubSub.subscribe(
      Barkpark.PubSub,
      Broadcast.doc_topic(@doc_id, @doc_type, published.workspace_id, @dataset)
    )

    assert {:error, :idempotency_completion_failed} =
             Content.apply_document_block_op_once(
               published.doc_id,
               @doc_type,
               title_patch(published, "Must not create a draft"),
               @dataset,
               Ecto.UUID.generate(),
               "user:published-rollback",
               if_rev: published.rev,
               before_idempotency_complete: fn ->
                 Repo.delete_all(
                   from(k in IdempotencyStore.Key,
                     where: like(k.scope, "document_op:v1:%")
                   )
                 )
               end
             )

    refute_receive {:doc_updated, _}, 50
    refute_receive %{event: :after_save}, 50

    assert {:error, :not_found} =
             Content.get_document(Content.draft_id(@doc_id), @doc_type, @dataset)

    {:ok, unchanged} = Content.get_document(@doc_id, @doc_type, @dataset)
    assert unchanged.rev == published.rev
    assert unchanged.content["title"] == "Original title"
  end

  test "a first edit of a published document keeps one replay identity after creating its draft" do
    {:ok, published} = Content.publish_document(@doc_id, @doc_type, @dataset)
    request_id = Ecto.UUID.generate()
    op = title_patch(published, "Drafted once")

    assert {:ok, receipt, :applied} =
             Content.apply_document_block_op_once(
               published.doc_id,
               @doc_type,
               op,
               @dataset,
               request_id,
               "user:published-beta",
               if_rev: published.rev
             )

    draft_id = Content.draft_id(@doc_id)

    assert {:ok, ^receipt, :replayed} =
             Content.apply_document_block_op_once(
               draft_id,
               @doc_type,
               op,
               @dataset,
               request_id,
               "user:published-beta",
               if_rev: published.rev
             )

    {:ok, draft} = Content.get_document(draft_id, @doc_type, @dataset)
    assert draft.rev == receipt.rev
    assert draft.content["title"] == "Drafted once"

    {:ok, unchanged_published} = Content.get_document(@doc_id, @doc_type, @dataset)
    assert unchanged_published.rev == published.rev
    assert unchanged_published.content["title"] == "Original title"
  end

  test "a completed receipt cannot alias a deleted and recreated document row", %{doc: doc} do
    request_id = Ecto.UUID.generate()
    op = title_patch(doc, "Old physical row")

    assert {:ok, receipt, :applied} =
             Content.apply_document_block_op_once(
               doc.doc_id,
               @doc_type,
               op,
               @dataset,
               request_id,
               "user:recreated-beta",
               if_rev: doc.rev
             )

    {:ok, old_row} = Content.get_document(doc.doc_id, @doc_type, @dataset)
    assert old_row.id == receipt.written_row_id
    Repo.delete!(old_row)

    {:ok, replacement} =
      Content.create_document(
        @doc_type,
        %{"doc_id" => @doc_id, "title" => "Replacement title"},
        @dataset
      )

    refute replacement.id == receipt.written_row_id

    assert {:error, :idempotency_target_replaced} =
             Content.apply_document_block_op_once(
               replacement.doc_id,
               @doc_type,
               op,
               @dataset,
               request_id,
               "user:recreated-beta",
               if_rev: doc.rev
             )

    {:ok, unchanged} = Content.get_document(replacement.doc_id, @doc_type, @dataset)
    assert unchanged.id == replacement.id
    assert unchanged.content["title"] == "Replacement title"
  end

  defp title_patch(doc, value) do
    title = Enum.find(doc.content["blocks"], &(&1["fieldName"] == "title"))

    %{
      "op" => "patch-block",
      "id" => title["id"],
      "patch" => %{"value" => value}
    }
  end

  defp install_after_write_probe! do
    parent = self()
    previous = Application.get_env(:barkpark, :after_write_listeners)

    Application.put_env(:barkpark, :after_write_listeners, [
      fn payload -> send(parent, payload) end
    ])

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:barkpark, :after_write_listeners)
      else
        Application.put_env(:barkpark, :after_write_listeners, previous)
      end
    end)
  end
end
