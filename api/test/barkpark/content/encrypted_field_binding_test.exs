defmodule Barkpark.Content.EncryptedFieldBindingTest do
  @moduledoc """
  Owner ruling #18 "Verify, then bind", bind half (task-7cdf86a62a1d8c08).

  The verify half (#21517) accepts an envelope only when it decrypts under the
  document's (workspace, dataset) key. A REAL envelope copied from document A
  to document B of the same workspace and dataset still decrypted, so a writer
  could move a secret between documents or fields. New seals are now version-2
  envelopes bound to (type, published doc id, top-level field), and the write
  path refuses one sent for another document or field.

  Legitimate paths kept: re-saving the stored envelope, publishing (draft and
  published share the published id), admin reveal of v2 and of v1 envelopes
  sealed before the change, and cloning a document (the clone is sealed for
  its own id).
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Document, SchemaDefinition}
  alias Barkpark.Crypto.FieldCipher
  alias Barkpark.Repo

  @dataset "seal-binding-test"
  @admin %CallerContext{principal_type: :api_token, is_admin: true}

  defp vault! do
    type = "vault_#{System.unique_integer([:positive])}"

    {:ok, schema} =
      %SchemaDefinition{}
      |> SchemaDefinition.changeset(%{
        "name" => type,
        "title" => type,
        "dataset" => @dataset,
        "fields" => [
          %{"name" => "name", "type" => "string"},
          %{"name" => "secret", "type" => "string", "encrypted" => true},
          %{"name" => "pin", "type" => "string", "encrypted" => true}
        ]
      })
      |> Repo.insert()

    {type, schema}
  end

  defp raw(%Document{id: id}) do
    %{rows: [[content]]} =
      Repo.query!("SELECT content FROM documents WHERE id = $1", [Ecto.UUID.dump!(id)])

    if is_binary(content), do: Jason.decode!(content), else: content
  end

  defp create!(type, id, content) do
    {:ok, doc} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => id, "content" => content},
        @dataset
      )

    doc
  end

  test "a new seal is a v2 envelope that opens only with its own document and field" do
    {type, _} = vault!()
    a = create!(type, "doc-a", %{"secret" => "hunter2"})
    env = raw(a)["secret"]

    assert env["_bpenc"] == 2
    assert :error = FieldCipher.decrypt(env, "dataset:" <> @dataset, a.workspace_id)

    assert :error =
             FieldCipher.decrypt(
               env,
               "dataset:" <> @dataset,
               a.workspace_id,
               FieldCipher.binding(type, "doc-b", "secret")
             )

    assert {:ok, "hunter2"} =
             FieldCipher.decrypt(
               env,
               "dataset:" <> @dataset,
               a.workspace_id,
               FieldCipher.binding(type, "doc-a", "secret")
             )
  end

  test "an envelope copied from another document of the same workspace and dataset is refused with 422" do
    {type, _} = vault!()
    a = create!(type, "doc-a", %{"secret" => "hunter2"})
    stolen = raw(a)["secret"]

    assert {:error, {:validation_failed, "encrypted field", details, _hint}} =
             Content.create_document(
               type,
               %{"doc_id" => "doc-b", "title" => "b", "content" => %{"secret" => stolen}},
               @dataset
             )

    assert Map.keys(details) == ["secret"]

    b = create!(type, "doc-c", %{"secret" => "other"})

    assert {:error, {:validation_failed, "encrypted field", _, _}} =
             Content.upsert_document(
               type,
               %{"doc_id" => "doc-c", "title" => "c", "content" => %{"secret" => stolen}},
               @dataset
             )

    assert raw(b)["secret"] != stolen
  end

  test "an envelope moved to another field of the same document is refused with 422" do
    {type, _} = vault!()
    a = create!(type, "doc-a", %{"secret" => "hunter2", "pin" => "1234"})
    content = raw(a)

    assert {:error, {:validation_failed, "encrypted field", details, _}} =
             Content.upsert_document(
               type,
               %{
                 "doc_id" => "doc-a",
                 "title" => "a",
                 "content" => %{"secret" => content["secret"], "pin" => content["secret"]}
               },
               @dataset
             )

    assert Map.keys(details) == ["pin"]
  end

  test "re-saving a document's own envelope, publishing and admin reveal still work" do
    {type, schema} = vault!()
    a = create!(type, "doc-a", %{"secret" => "hunter2", "name" => "x"})
    env = raw(a)["secret"]

    {:ok, again} =
      Content.upsert_document(
        type,
        %{"doc_id" => "doc-a", "title" => "a", "content" => %{"secret" => env, "name" => "y"}},
        @dataset
      )

    assert raw(again)["secret"] == env

    {:ok, published} = Content.publish_document("doc-a", type, @dataset)
    assert raw(published)["secret"] == env

    assert {:ok, revealed} = Content.reveal_fields(published, schema, @dataset, @admin)
    assert revealed.content["secret"] == "hunter2"
  end

  test "an envelope sealed before binding (v1) still reveals and still re-saves" do
    {type, schema} = vault!()
    a = create!(type, "doc-a", %{"name" => "x"})
    v1 = FieldCipher.encrypt("legacy", "dataset:" <> @dataset, a.workspace_id)
    assert v1["_bpenc"] == 1

    # Stored the way a pre-binding write left it.
    {1, _} =
      from(d in Document, where: d.id == ^a.id)
      |> Repo.update_all(set: [content: %{"name" => "x", "secret" => v1}])

    stored = Repo.get!(Document, a.id)

    assert {:ok, %{content: %{"secret" => "legacy"}}} =
             Content.reveal_fields(stored, schema, @dataset, @admin)

    {:ok, again} =
      Content.upsert_document(
        type,
        %{"doc_id" => "doc-a", "title" => "a", "content" => %{"secret" => v1, "name" => "y"}},
        @dataset
      )

    assert raw(again)["secret"] == v1
  end

  test "cloning a document seals the copy for its own id" do
    {type, schema} = vault!()
    a = create!(type, "doc-a", %{"secret" => "hunter2"})

    assert {:ok, copy} = Content.clone_document(a, type, @dataset)
    assert copy.doc_id != a.doc_id
    assert raw(copy)["secret"]["_bpenc"] == 2
    assert raw(copy)["secret"] != raw(a)["secret"]

    assert {:ok, %{content: %{"secret" => "hunter2"}}} =
             Content.reveal_fields(copy, schema, @dataset, @admin)
  end
end
