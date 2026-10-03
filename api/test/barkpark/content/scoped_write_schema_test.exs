defmodule Barkpark.Content.ScopedWriteSchemaTest do
  @moduledoc """
  The content write path reads the type's schema three times on a create:
  field encryption (`Encryption.encrypt_marked/4`), `initial_values`, and the
  layout scaffold. All three ran `Content.get_schema(type, dataset)` with no
  scope. With no workspace, the dataset string resolves to the Default
  workspace's dataset, so a document written into any other workspace was
  shaped by Default's schema, or by none:

    * a non-Default workspace's `encrypted: true` field was stored as
      PLAINTEXT, because its own schema was never found;
    * a non-Default workspace's create was pre-filled with Default's
      `initial_values` for a same-named type, and ignored its own.

  Each write now resolves the type in the document's stamped scope, then its
  workspace, then the shared global layer, and never another workspace.
  """
  use Barkpark.DataCase, async: true
  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Crypto.FieldCipher
  alias Barkpark.Repo

  @dataset "production"

  defp unique_type(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp register!(type, fields, extra, scope) do
    {:ok, _} =
      Content.upsert_schema(
        Map.merge(%{"name" => type, "title" => type, "fields" => fields}, extra),
        @dataset,
        scope
      )
  end

  defp raw_content(%Document{id: id}) do
    %{rows: [[content]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT content FROM documents WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    if is_binary(content), do: Jason.decode!(content), else: content
  end

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    %{ws: ws, proj: proj, scope: [workspace_id: ws.id, project_id: proj.id]}
  end

  describe "field encryption in a non-Default workspace" do
    test "a marked field is stored as ciphertext, not plaintext", %{scope: scope} do
      type = unique_type("vault")

      register!(
        type,
        [
          %{"name" => "name", "type" => "string"},
          %{"name" => "secret", "type" => "string", "encrypted" => true}
        ],
        %{},
        scope
      )

      {:ok, doc} =
        Content.create_document(
          type,
          %{"doc_id" => "v1", "title" => "vault", "content" => %{"secret" => "hunter2"}},
          @dataset,
          scope
        )

      raw = raw_content(doc)

      assert FieldCipher.encrypted?(raw["secret"]),
             "the workspace's own encrypted field was stored as #{inspect(raw["secret"])}"

      refute Jason.encode!(raw) =~ "hunter2"
    end

    test "upsert also encrypts the workspace's marked field", %{scope: scope} do
      type = unique_type("vault")

      register!(
        type,
        [%{"name" => "secret", "type" => "string", "encrypted" => true}],
        %{},
        scope
      )

      {:ok, doc} =
        Content.upsert_document(
          type,
          %{"doc_id" => "v2", "title" => "vault", "content" => %{"secret" => "via-upsert"}},
          @dataset,
          scope
        )

      assert FieldCipher.encrypted?(raw_content(doc)["secret"])
    end
  end

  describe "initial_values in a non-Default workspace" do
    test "a create takes its own workspace's initial values, never Default's", %{scope: scope} do
      type = unique_type("note")
      fields = [%{"name" => "tag", "type" => "string"}]

      register!(type, fields, %{"initial_values" => %{"tag" => "default-only"}},
        workspace_id: default_workspace_id!()
      )

      register!(type, fields, %{"initial_values" => %{"tag" => "own"}}, scope)

      {:ok, doc} =
        Content.create_document(type, %{"doc_id" => "n1", "title" => "n"}, @dataset, scope)

      assert doc.content["tag"] == "own"
    end

    test "a workspace type with no initial values gets none from Default", %{scope: scope} do
      type = unique_type("note")
      fields = [%{"name" => "tag", "type" => "string"}]

      register!(type, fields, %{"initial_values" => %{"tag" => "default-only"}},
        workspace_id: default_workspace_id!()
      )

      register!(type, fields, %{}, scope)

      {:ok, doc} =
        Content.create_document(type, %{"doc_id" => "n2", "title" => "n"}, @dataset, scope)

      refute doc.content["tag"] == "default-only"
    end
  end
end
