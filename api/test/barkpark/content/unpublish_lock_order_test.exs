defmodule Barkpark.Content.UnpublishLockOrderTest do
  @moduledoc """
  task-bb3d759d9354bae9: an unpublish racing a `[patch, publish]` batch on the
  same document deadlocked. The batch locks the draft row (the patch) and then
  the published row; unpublish locked the published row (its delete) and then
  the draft row (the revision trigger's pointer UPDATE). Postgres broke the
  cycle after deadlock_timeout by failing the unpublish with 40P01, which the
  API answered as 500 "unknown error (Postgrex.Error)" (5 in 10 on e2e-local).

  The other writer is a raw transaction that takes the same two locks in the
  batch's order, with a pause between them so the unpublish arrives while the
  draft is held. Without the fix this deadlocks; with it the unpublish queues
  on the draft, then lands once the writer commits.
  """
  use Barkpark.ConcurrencyCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Document

  @type_name "post"

  test "unpublish waits for a writer holding the draft, then lands (no deadlock)", %{
    dataset: dataset
  } do
    id = "lock-order-#{System.unique_integer([:positive])}"
    {:ok, _} = Content.create_document(@type_name, %{"_id" => id, "title" => "v1"}, dataset)
    {:ok, _} = Content.publish_document(id, @type_name, dataset)
    {:ok, _} = Content.create_document(@type_name, %{"_id" => id, "title" => "v2"}, dataset)

    parent = self()

    row = fn doc_id ->
      from(d in Document, where: d.doc_id == ^doc_id and d.dataset == ^dataset)
    end

    # The batch's order: the draft row, a pause, then the published row.
    writer =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.update_all(row.("drafts." <> id), set: [updated_at: DateTime.utc_now()])
          send(parent, :draft_held)
          Process.sleep(300)
          Repo.update_all(row.(id), set: [updated_at: DateTime.utc_now()])
        end)
      end)

    assert_receive :draft_held, 5_000
    unpublish = Task.async(fn -> Content.unpublish_document(id, @type_name, dataset) end)

    assert {:ok, _} = Task.await(writer, 10_000)
    assert {:ok, %Document{status: "draft", title: "v2"}} = Task.await(unpublish, 10_000)
    assert {:error, :not_found} = Content.get_document(id, @type_name, dataset)
  end
end
