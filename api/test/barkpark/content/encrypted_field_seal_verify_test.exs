defmodule Barkpark.Content.EncryptedFieldSealVerifyTest do
  @moduledoc """
  Owner ruling #18 (task-f462de9e4c1c4621, item 1): the server accepts an
  encryption envelope in an `encrypted: true` field only when it is one this
  server sealed for that document's key.

  `FieldCipher.encrypt/3` used to pass ANY map carrying `"_bpenc"` through
  untouched, so a writer could store plain text in an encrypted field by
  sending `{"_bpenc": 1, "k": 1, "v": "<plaintext>"}`, and a real envelope from
  another workspace landed as a value nobody could decrypt.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Encryption, SchemaDefinition}
  alias Barkpark.Crypto.FieldCipher
  alias Barkpark.Repo

  @dataset "seal-verify-test"

  defp vault_type! do
    type = "vault_#{System.unique_integer([:positive])}"

    {:ok, _} =
      %SchemaDefinition{}
      |> SchemaDefinition.changeset(%{
        "name" => type,
        "title" => type,
        "dataset" => @dataset,
        "fields" => [
          %{"name" => "name", "type" => "string"},
          %{"name" => "secret", "type" => "string", "encrypted" => true}
        ]
      })
      |> Repo.insert()

    type
  end

  defp raw_secret(%Document{id: id}) do
    %{rows: [[content]]} =
      Repo.query!("SELECT content FROM documents WHERE id = $1", [Ecto.UUID.dump!(id)])

    content = if is_binary(content), do: Jason.decode!(content), else: content
    content["secret"]
  end

  @fake %{"_bpenc" => 1, "k" => 1, "v" => "plain text pretending to be sealed"}

  describe "the content write path" do
    test "a caller-built envelope is refused with a 422 naming the field" do
      type = vault_type!()

      assert {:error, {:validation_failed, "encrypted field", details, hint}} =
               Content.create_document(
                 type,
                 %{"doc_id" => "v1", "title" => "v", "content" => %{"secret" => @fake}},
                 @dataset
               )

      assert Map.keys(details) == ["secret"]
      assert hint =~ "plain value"

      env =
        Barkpark.Content.Errors.to_envelope(
          {:error, {:validation_failed, "encrypted field", details, hint}}
        )

      assert env.status == 422
      assert env.code == "validation_failed"

      assert {:error, :not_found} = Content.get_document("v1", type, @dataset)
    end

    test "an envelope sealed in another workspace is refused" do
      type = vault_type!()
      other_ws = create_workspace!()
      foreign = FieldCipher.encrypt("theirs", "dataset:" <> @dataset, other_ws.id)

      assert {:error, {:validation_failed, "encrypted field", %{"secret" => _}, _}} =
               Encryption.encrypt_marked(%{"secret" => foreign}, type, @dataset)
    end

    test "a bound block carrying a fake envelope is refused too" do
      type = vault_type!()

      content = %{
        "blocks" => [%{"_type" => "field-string", "fieldName" => "secret", "value" => @fake}]
      }

      assert {:error, {:validation_failed, "encrypted field", details, _}} =
               Encryption.encrypt_marked(content, type, @dataset)

      assert Map.keys(details) == ["blocks[0].value (secret)"]
    end

    test "plain text is sealed, and sending back the stored envelope re-saves unchanged" do
      type = vault_type!()

      {:ok, doc} =
        Content.create_document(
          type,
          %{
            "doc_id" => "v2",
            "title" => "v",
            "content" => %{"secret" => "hunter2", "name" => "a"}
          },
          @dataset
        )

      stored = raw_secret(doc)
      assert FieldCipher.encrypted?(stored)

      {:ok, again} =
        Content.upsert_document(
          type,
          %{"doc_id" => "v2", "title" => "v", "content" => %{"secret" => stored, "name" => "b"}},
          @dataset
        )

      assert raw_secret(again) == stored

      # A write-path seal is a v2 envelope bound to this document and field
      # (ruling #18 bind half): it opens only with that binding.
      assert stored["_bpenc"] == 2
      assert :error = FieldCipher.decrypt(stored, "dataset:" <> @dataset, again.workspace_id)

      assert {:ok, "hunter2"} =
               FieldCipher.decrypt(
                 stored,
                 "dataset:" <> @dataset,
                 again.workspace_id,
                 FieldCipher.binding(type, "v2", "secret")
               )
    end
  end

  describe "FieldCipher.encrypt/3, the floor for every other caller" do
    test "seals a look-alike envelope instead of passing it through" do
      sealed = FieldCipher.encrypt(@fake, "dataset:x")
      refute sealed == @fake
      assert {:ok, @fake} = FieldCipher.decrypt(sealed, "dataset:x")
    end

    test "passes its own envelope through untouched" do
      env = FieldCipher.encrypt("s", "dataset:x")
      assert FieldCipher.encrypt(env, "dataset:x") == env
      assert FieldCipher.verify(env, "dataset:x", nil) == :ok
      assert FieldCipher.verify(env, "dataset:y", nil) == :error
      assert FieldCipher.verify("plain", "dataset:x", nil) == :error
    end
  end
end
