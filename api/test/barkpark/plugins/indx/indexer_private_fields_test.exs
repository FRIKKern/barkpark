defmodule Barkpark.Plugins.Indx.IndexerPrivateFieldsTest do
  @moduledoc """
  Owner ruling #20 (task-3c68de39a19285c4), the Indx half: the Indx corpus
  holds public fields only. Indx folds every content string into its `body`
  field, so before this a private field's words matched an anonymous
  `engine=indx` search exactly as they did the Postgres full vector.
  """
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.Plugins.Indx.IndexerWorker

  @indexer "Barkpark.Plugins.Indx.IndexerPrivateFieldsTest.FakeIndexer"
  @content "Barkpark.Plugins.Indx.IndexerPrivateFieldsTest.FakeContent"

  defmodule FakeContent do
    @moduledoc false
    def list_schemas(_scope, _opts) do
      [
        %Barkpark.Content.SchemaDefinition{
          name: "memo",
          visibility: "public",
          fields: [
            %{"name" => "notes", "type" => "text", "private" => true},
            %{"name" => "summary", "type" => "text"}
          ]
        }
      ]
    end

    defp doc(id),
      do: %{
        id: id,
        doc_id: id,
        type: "memo",
        title: "Memo",
        content: %{"notes" => "quixotical", "summary" => "harmless"}
      }

    def list_documents("memo", _scope, _opts), do: [doc("m1")]
    def list_documents(_type, _scope, _opts), do: []
    def get_document(id, "memo", _scope), do: {:ok, doc(id)}
  end

  defmodule FakeIndexer do
    @moduledoc false
    def upsert_record(_scope, doc) do
      send(self(), {:upserted, doc})
      :ok
    end

    def rebuild(_scope, docs) do
      send(self(), {:rebuild_docs, docs})
      {:ok, %{new_dataset: "bp_v2", old_dataset: nil, count: length(docs), key_map: %{}}}
    end

    def swap(_scope, _result), do: nil
    def delete_dataset(_old, _opts), do: :ok
  end

  test "an upsert hands the indexer the public fields only" do
    assert :ok =
             perform_job(IndexerWorker, %{
               "op" => "upsert",
               "scope" => "production",
               "_id" => "m1",
               "types" => ["memo"],
               "indexer" => @indexer,
               "content" => @content
             })

    assert_receive {:upserted, %{content: content}}
    assert content == %{"summary" => "harmless"}
  end

  test "a rebuild hands the indexer the public fields only" do
    assert :ok =
             perform_job(IndexerWorker, %{
               "op" => "rebuild",
               "scope" => "production",
               "indexer" => @indexer,
               "content" => @content
             })

    assert_receive {:rebuild_docs, [%{content: content}]}
    assert content == %{"summary" => "harmless"}
  end
end
