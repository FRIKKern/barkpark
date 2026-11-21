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

  # task-65ce4299f6f432f0: a condition on an envelope key reads the stored row's
  # envelope, as the Studio's document has it. HSO's Sanity source locks a field
  # once the document exists: readOnly: ({document}) => Boolean(document?._createdAt).
  defp omrade(ws_id, key) do
    type = "omrade_#{String.trim_leading(key, "_")}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => type,
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "farge",
              "title" => "Farge",
              "type" => "string",
              "readOnly" => %{"field" => key, "operator" => "non_empty"}
            }
          ]
        },
        @dataset,
        workspace_id: ws_id
      )

    type
  end

  defp saved_then_patched(type, id) do
    created = mutate([%{"create" => %{"_id" => id, "_type" => type, "farge" => "rod"}}])
    patch = %{"patch" => %{"id" => id, "type" => type, "set" => %{"farge" => "bla"}}}
    {created.status, mutate([patch]).status}
  end

  test "a readOnly condition on _createdAt refuses the write on a saved document and allows it on the create",
       %{id: id, ws_id: ws_id} do
    type = omrade(ws_id, "_createdAt")
    assert saved_then_patched(type, id) == {200, 422}

    {:ok, doc} = Content.get_document("drafts." <> id, type, @dataset, workspace_id: ws_id)
    assert doc.content["farge"] == "rod"
    title = %{"patch" => %{"id" => id, "type" => type, "set" => %{"title" => "T"}}}
    assert mutate([title]).status == 200
  end

  test "_updatedAt, _id and _type read the stored row's envelope; a content field as before",
       %{id: id, ws_id: ws_id} do
    for key <- ~w(_updatedAt _id _type) do
      assert saved_then_patched(omrade(ws_id, key), "#{id}#{key}") == {200, 422}, key
    end

    # A content field: locked once it holds a value, writable while it is empty.
    type = omrade(ws_id, "farge")
    assert saved_then_patched(type, id) == {200, 422}

    assert mutate([%{"create" => %{"_id" => "#{id}-e", "_type" => type, "title" => "T"}}]).status ==
             200

    set = %{"patch" => %{"id" => "#{id}-e", "type" => type, "set" => %{"farge" => "rod"}}}
    assert mutate([set]).status == 200
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
