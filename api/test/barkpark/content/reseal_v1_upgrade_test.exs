defmodule Barkpark.Content.ResealV1UpgradeTest do
  @moduledoc """
  Owner ruling #18 bind half, residual (task-7cdf86a62a1d8c08 follow-up): a
  version-1 envelope (bare-scope AAD) stored before #21609 can still be copied
  to another document of the same workspace and dataset. The reseal tool's
  upgrade mode counts v1 envelopes and rewrites them as bound v2 seals.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Document, Reseal}
  alias Barkpark.Crypto.FieldCipher
  alias Barkpark.Repo

  @dataset "reseal-upgrade-test"
  @admin %CallerContext{principal_type: :api_token, is_admin: true}

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]
    type = "vault_#{System.unique_integer([:positive])}"

    {:ok, schema} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => type,
          "visibility" => "private",
          "fields" => [
            %{"name" => "name", "type" => "string"},
            %{"name" => "secret", "type" => "string", "encrypted" => true}
          ]
        },
        @dataset,
        scope
      )

    {:ok, doc} =
      Content.upsert_document(
        type,
        %{"doc_id" => "old-1", "title" => "vault", "content" => %{"name" => "a"}},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("old-1", type, @dataset, scope)
    published = Repo.get_by!(Document, doc_id: "old-1", dataset: @dataset)

    # Stored the way a write before #21609 left it: a v1 envelope.
    v1 = FieldCipher.encrypt("legacy", "dataset:" <> @dataset, ws.id)
    assert v1["_bpenc"] == 1

    {1, _} =
      from(d in Document, where: d.id == ^published.id)
      |> Repo.update_all(set: [content: %{"name" => "a", "secret" => v1}])

    _ = doc
    %{ws: ws, scope: scope, type: type, schema: schema, v1: v1}
  end

  defp stored(doc_id),
    do: Repo.get_by!(Document, doc_id: doc_id, dataset: @dataset)

  test "the census and the plan find the v1 envelope; nothing is written", %{
    ws: ws,
    type: type,
    v1: v1
  } do
    {top, docs} = Reseal.v1_census()

    assert [%{workspace: slug, field: "secret", rows: 1}] =
             Enum.filter(top, &(&1.type == type))

    assert slug == ws.slug
    assert [%{rows: 1}] = Enum.filter(docs, &(&1.type == type))

    assert [%{doc_id: "old-1"}] =
             Reseal.upgrade_plan(workspace: ws.slug) |> Enum.filter(&(&1.type == type))

    assert stored("old-1").content["secret"] == v1
  end

  test "upgrade_apply rewrites it as a bound v2 seal, keeps the rev, and a rerun changes nothing",
       %{ws: ws, type: type, schema: schema} do
    before = stored("old-1")
    assert {:ok, %{upgraded: 1, failed: []}} = Reseal.upgrade_apply(ws.slug)

    after_doc = stored("old-1")
    env = after_doc.content["secret"]
    assert env["_bpenc"] == 2
    assert after_doc.rev == before.rev

    assert {:ok, "legacy"} =
             FieldCipher.decrypt(
               env,
               "dataset:" <> @dataset,
               ws.id,
               FieldCipher.binding(type, "old-1", "secret")
             )

    assert {:ok, %{content: %{"secret" => "legacy"}}} =
             Content.reveal_fields(after_doc, schema, @dataset, @admin)

    {top, _} = Reseal.v1_census()
    assert Enum.filter(top, &(&1.type == type)) == []
    assert {:ok, %{upgraded: 0, failed: []}} = Reseal.upgrade_apply(ws.slug)
    assert stored("old-1").content["secret"] == env
  end

  test "an upgraded envelope copied to another document is refused with 422",
       %{ws: ws, scope: scope, type: type, v1: v1} do
    # Before the upgrade, the v1 envelope still copies (the residual).
    assert {:ok, _} =
             Content.upsert_document(
               type,
               %{"doc_id" => "copy-a", "title" => "c", "content" => %{"secret" => v1}},
               @dataset,
               scope
             )

    assert {:ok, _} = Reseal.upgrade_apply(ws.slug)
    upgraded = stored("old-1").content["secret"]

    assert {:error, {:validation_failed, "encrypted field", details, _}} =
             Content.upsert_document(
               type,
               %{"doc_id" => "copy-b", "title" => "c", "content" => %{"secret" => upgraded}},
               @dataset,
               scope
             )

    assert Map.keys(details) == ["secret"]
  end

  test "upgrade_apply refuses an unknown workspace and a missing KEK", %{ws: ws} do
    assert {:error, :workspace_not_found} =
             Reseal.upgrade_apply("no-such-#{System.unique_integer([:positive])}")

    prior = Application.get_env(:barkpark, :key_provider)
    Application.put_env(:barkpark, :key_provider, Barkpark.Content.ResealTest.BrokenKek)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, :key_provider, prior),
        else: Application.delete_env(:barkpark, :key_provider)
    end)

    assert {:error, :kek_unavailable} = Reseal.upgrade_apply(ws.slug)
  end
end
