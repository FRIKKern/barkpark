defmodule Barkpark.Content.ResealTest do
  @moduledoc """
  Owner ruling #19 (task-5aba9d644eb3b40c): count, then reseal, plaintext left
  in `encrypted: true` fields of non-Default workspaces.

  The legacy row is built the way it happened in production: written while the
  field was not (yet) marked, then the schema marks it. The census and the plan
  find it; `apply/2` seals it through a normal save; a second census is zero.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.Reseal
  alias Barkpark.Crypto.FieldCipher
  alias Barkpark.Repo

  @dataset "reseal-test"

  defp register!(type, fields, scope) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => type, "title" => type, "visibility" => "private", "fields" => fields},
        @dataset,
        scope
      )
  end

  defp raw_secret(doc_id) do
    %{rows: [[content]]} =
      Repo.query!("SELECT content FROM documents WHERE doc_id = $1 AND dataset = $2", [
        doc_id,
        @dataset
      ])

    content = if is_binary(content), do: Jason.decode!(content), else: content
    content["secret"]
  end

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]
    type = "vault_#{System.unique_integer([:positive])}"

    register!(type, [%{"name" => "secret", "type" => "string"}], scope)

    {:ok, _} =
      Content.upsert_document(
        type,
        %{"doc_id" => "legacy-1", "title" => "vault", "content" => %{"secret" => "old-plain"}},
        @dataset,
        scope
      )

    register!(type, [%{"name" => "secret", "type" => "string", "encrypted" => true}], scope)

    %{ws: ws, scope: scope, type: type}
  end

  test "the census and the plan find the plaintext row; nothing is written", %{ws: ws, type: type} do
    assert [%{workspace: slug, type: ^type, field: "secret", rows: 1}] =
             Enum.filter(Reseal.census(), &(&1.type == type))

    assert slug == ws.slug

    assert [%{doc_id: "drafts.legacy-1", workspace: ^slug}] =
             Enum.filter(Reseal.plan(workspace: ws.slug), &(&1.type == type))

    assert raw_secret("drafts.legacy-1") == "old-plain"
  end

  test "apply/2 seals the workspace's rows, and a second census is zero", %{
    ws: ws,
    type: type,
    scope: scope
  } do
    assert {:ok, %{resealed: 1, failed: []}} = Reseal.apply(ws.slug)

    sealed = raw_secret("drafts.legacy-1")
    assert FieldCipher.encrypted?(sealed)
    assert {:ok, "old-plain"} = FieldCipher.decrypt(sealed, "dataset:" <> @dataset, ws.id)

    assert Enum.filter(Reseal.census(), &(&1.type == type)) == []
    assert Reseal.plan(workspace: ws.slug) |> Enum.filter(&(&1.type == type)) == []

    # Re-running is a no-op.
    assert {:ok, %{resealed: 0}} = Reseal.apply(ws.slug)
    _ = scope
  end

  test "apply/2 refuses the Default workspace and an unknown slug" do
    {default_ws, _} = Barkpark.TenancyFixtures.ensure_default_scope!()
    assert {:error, :default_workspace} = Reseal.apply(default_ws.slug)

    assert {:error, :workspace_not_found} =
             Reseal.apply("no-such-workspace-#{System.unique_integer()}")
  end

  test "apply/2 refuses when the KEK cannot wrap a key", %{ws: ws} do
    prior = Application.get_env(:barkpark, :key_provider)
    Application.put_env(:barkpark, :key_provider, Barkpark.Content.ResealTest.BrokenKek)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, :key_provider, prior),
        else: Application.delete_env(:barkpark, :key_provider)
    end)

    assert {:error, :kek_unavailable} = Reseal.apply(ws.slug)
    assert raw_secret("drafts.legacy-1") == "old-plain"
  end

  defmodule BrokenKek do
    @moduledoc false
    def wrap(_), do: raise("no KEK configured")
    def unwrap(_), do: :error
    def kek_version, do: 1
  end
end
