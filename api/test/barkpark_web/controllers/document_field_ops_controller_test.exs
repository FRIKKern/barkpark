defmodule BarkparkWeb.DocumentFieldOpsControllerTest do
  # POST /v1/data/doc/:dataset/:type/:doc_id/fields/:field/ops — the HTTP twin
  # of the field-canvas write Studio makes in-process
  # (handlers/field_blocks.ex → Content.apply_field_block_ops/6).
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "test"

  setup do
    {ws, proj} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: proj.id]
    Auth.create_token("field-ops-write-token", "w", @dataset, ["read", "write"], ws.id)
    Auth.create_token("field-ops-read-token", "r", @dataset, ["read"], ws.id)
    register_schema!(scope)
    {:ok, scope: scope}
  end

  defp register_schema!(scope) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "fieldopspub",
          "title" => "Field ops publication",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "description",
              "title" => "Description",
              "type" => "richText",
              "editor" => "blocks",
              "blocks" => %{"styles" => ["normal", "h2"], "marks" => ["strong"]}
            },
            %{"name" => "notes", "title" => "Notes", "type" => "richText"}
          ]
        },
        @dataset,
        scope
      )
  end

  defp create!(scope) do
    {:ok, doc} =
      Content.create_document(
        "fieldopspub",
        %{"doc_id" => "fo-#{System.unique_integer([:positive])}", "title" => "T"},
        @dataset,
        scope
      )

    doc
  end

  defp para(id, text),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  defp append(id, text), do: %{"op" => "append-block", "block" => para(id, text)}

  defp post_ops(token, doc_id, field, body) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/doc/#{@dataset}/fieldopspub/#{doc_id}/fields/#{field}/ops",
      Jason.encode!(body)
    )
  end

  # create_document writes `drafts.<id>`; requests name the published id, and
  # the door edits the draft (draft first, as Studio's editor does).
  defp pub_id(doc), do: String.replace_prefix(doc.doc_id, "drafts.", "")

  defp draft(doc, scope), do: Content.get_document(doc.doc_id, "fieldopspub", @dataset, scope)

  defp assert_unwritten(doc, scope) do
    {:ok, current} = draft(doc, scope)
    assert current.rev == doc.rev
    refute Map.has_key?(current.content || %{}, "description")
  end

  test "a batch applies in order to the field and answers the new rev", %{scope: scope} do
    doc = create!(scope)

    resp =
      post_ops("field-ops-write-token", pub_id(doc), "description", %{
        "ops" => [append("p1", "one"), append("p2", "two")],
        "ifRev" => doc.rev
      })

    assert resp.status == 200, resp.resp_body
    result = Jason.decode!(resp.resp_body)["result"]
    assert result["field"] == "description"
    assert Enum.map(result["blocks"], & &1["id"]) == ["p1", "p2"]

    {:ok, saved} = draft(doc, scope)
    assert result["rev"] == saved.rev
    assert Enum.map(saved.content["description"]["blocks"], & &1["id"]) == ["p1", "p2"]

    # The answered rev is the fence for the next batch, which edits the draft.
    resp =
      post_ops("field-ops-write-token", pub_id(doc), "description", %{
        "ops" => [%{"op" => "remove-block", "id" => "p1"}],
        "ifRev" => result["rev"]
      })

    assert resp.status == 200, resp.resp_body
    {:ok, saved} = draft(doc, scope)
    assert Enum.map(saved.content["description"]["blocks"], & &1["id"]) == ["p2"]
  end

  test "a stale ifRev answers 412 and writes nothing", %{scope: scope} do
    doc = create!(scope)

    resp =
      post_ops("field-ops-write-token", pub_id(doc), "description", %{
        "ops" => [append("p1", "one")],
        "ifRev" => doc.rev <> "-stale"
      })

    assert resp.status == 412, resp.resp_body
    error = Jason.decode!(resp.resp_body)["error"]
    assert error["code"] == "precondition_failed"
    assert error["details"]["actual"] == doc.rev
    assert_unwritten(doc, scope)
  end

  test "one invalid op fails the whole batch and nothing is written", %{scope: scope} do
    doc = create!(scope)

    resp =
      post_ops("field-ops-write-token", pub_id(doc), "description", %{
        "ops" => [append("p1", "one"), append("p1", "duplicate id")],
        "ifRev" => doc.rev
      })

    assert resp.status == 422, resp.resp_body
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "invalid_op"
    assert_unwritten(doc, scope)
  end

  test "a block outside the field's vocabulary is refused by name", %{scope: scope} do
    doc = create!(scope)

    resp =
      post_ops("field-ops-write-token", pub_id(doc), "description", %{
        "ops" => [
          append("p1", "one"),
          %{
            "op" => "append-block",
            "block" => %{"id" => "h", "type" => "heading", "level" => 1, "text" => "x"}
          }
        ],
        "ifRev" => doc.rev
      })

    assert resp.status == 422, resp.resp_body
    error = Jason.decode!(resp.resp_body)["error"]
    assert error["code"] == "invalid_op"
    assert error["message"] =~ "heading level 1"
    assert_unwritten(doc, scope)
  end

  test "a field that is not a block-editor field is refused", %{scope: scope} do
    doc = create!(scope)

    for field <- ["notes", "no_such_field"] do
      resp =
        post_ops("field-ops-write-token", pub_id(doc), field, %{
          "ops" => [append("p1", "one")],
          "ifRev" => doc.rev
        })

      assert resp.status == 422, resp.resp_body
      error = Jason.decode!(resp.resp_body)["error"]
      assert error["code"] == "invalid_op"
      assert error["message"] =~ field
    end

    assert_unwritten(doc, scope)
  end

  test "an empty ops list or a missing ifRev is refused before anything is read", %{
    scope: scope
  } do
    doc = create!(scope)

    for body <- [%{"ops" => [], "ifRev" => doc.rev}, %{"ops" => [append("p1", "one")]}] do
      resp = post_ops("field-ops-write-token", pub_id(doc), "description", body)
      assert resp.status == 422, resp.resp_body
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "malformed_op"
    end

    assert_unwritten(doc, scope)
  end

  test "a read-tier token is refused at the write gate", %{scope: scope} do
    doc = create!(scope)

    resp =
      post_ops("field-ops-read-token", pub_id(doc), "description", %{
        "ops" => [append("p1", "one")],
        "ifRev" => doc.rev
      })

    assert resp.status == 403, resp.resp_body
    assert_unwritten(doc, scope)
  end

  test "a token from another workspace cannot reach the document", %{scope: scope} do
    doc = create!(scope)
    other_ws = TenancyFixtures.create_workspace!()
    other_proj = TenancyFixtures.create_project!(other_ws)
    # The type exists over there too, so the refusal is the document lookup.
    register_schema!(workspace_id: other_ws.id, project_id: other_proj.id)
    Auth.create_token("field-ops-foreign-token", "f", @dataset, ["read", "write"], other_ws.id)

    resp =
      post_ops("field-ops-foreign-token", pub_id(doc), "description", %{
        "ops" => [append("p1", "one")],
        "ifRev" => doc.rev
      })

    assert resp.status == 404, resp.resp_body
    assert Jason.decode!(resp.resp_body)["error"]["message"] == "document not found"
    assert_unwritten(doc, scope)
  end
end
