defmodule BarkparkWeb.MutateConditionalReadOnlyTest do
  @moduledoc """
  A schema field's `readOnly` can be a condition, the same shape as
  `visibleWhen` (task-00eac0b023b11517): a post's `reviewNote` is read-only once
  `stage` is `done`. The condition is read on the stored document the write
  starts from, so the write that moves `stage` to `done` may still set the note,
  and every later write to it is refused.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "test"
  @writer "barkpark-test-cond-readonly-writer"

  setup do
    ws_id = TenancyFixtures.default_workspace_id!()

    {:ok, _} =
      Auth.create_token(@writer, "cond-readonly-writer", @dataset, ["read", "write"], ws_id)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "stage", "title" => "Stage", "type" => "string"},
            %{
              "name" => "reviewNote",
              "title" => "Review note",
              "type" => "string",
              "readOnly" => %{"field" => "stage", "operator" => "eq", "value" => "done"}
            }
          ]
        },
        @dataset,
        workspace_id: ws_id
      )

    %{ws_id: ws_id, id: "post-#{System.unique_integer([:positive])}"}
  end

  defp mutate(mutations) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{@writer}")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp set(id, fields),
    do: mutate([%{"patch" => %{"id" => id, "type" => "post", "set" => fields}}])

  defp stored(id, ws_id) do
    {:ok, doc} = Content.get_document("drafts." <> id, "post", @dataset, workspace_id: ws_id)
    doc.content
  end

  test "the schema read returns the condition", %{ws_id: ws_id} do
    {:ok, schema} = Content.get_schema("post", @dataset, workspace_id: ws_id)

    field =
      Enum.find(Content.serialize_schema_for_sdk(schema).fields, &(&1["name"] == "reviewNote"))

    assert field["readOnly"] == %{"field" => "stage", "operator" => "eq", "value" => "done"}
  end

  test "writable until the condition holds, then refused", %{id: id, ws_id: ws_id} do
    create = %{
      "_id" => id,
      "_type" => "post",
      "title" => "T",
      "stage" => "review",
      "reviewNote" => "a"
    }

    assert mutate([%{"create" => create}]).status == 200

    assert set(id, %{"reviewNote" => "b"}).status == 200
    # The write that closes the stage may still set the note.
    assert set(id, %{"stage" => "done", "reviewNote" => "final"}).status == 200

    resp = set(id, %{"reviewNote" => "changed after done"})
    assert resp.status == 422
    assert resp.resp_body =~ "reviewNote"
    assert stored(id, ws_id)["reviewNote"] == "final"

    # Other fields stay writable.
    assert set(id, %{"title" => "T2"}).status == 200
  end

  test "the Studio resolves the condition against the form" do
    alias Barkpark.Content.ReadOnlyFields

    field = %{
      "name" => "reviewNote",
      "readOnly" => %{"field" => "stage", "operator" => "eq", "value" => "done"}
    }

    assert ReadOnlyFields.resolve_for(field, %{"stage" => "done"})["readOnly"] == true
    assert ReadOnlyFields.resolve_for(field, %{"stage" => "review"})["readOnly"] == false

    assert ReadOnlyFields.resolve_for(%{"name" => "t", "readOnly" => true}, %{})["readOnly"] ==
             true
  end
end
