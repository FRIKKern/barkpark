defmodule BarkparkWeb.BulldocsCreateControllerTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, LabelFixtures}
  import Barkpark.TenancyFixtures

  @token "barkpark-test-ingest-token"

  defp body(slug) do
    LabelFixtures.paper_attrs(%{
      "slug" => slug,
      "title" => slug,
      "blocks" => [
        %{"id" => "heading", "type" => "heading", "level" => 1, "text" => slug},
        %{
          "id" => "body",
          "type" => "paragraph",
          "text" => "Preserve this author's original note."
        }
      ]
    })
  end

  defp create(conn, payload, token \\ @token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/plugins/bulldocs/papers/#{payload["slug"]}/create", payload)
  end

  test "creates once and preserves the complete published row on a collision", %{conn: conn} do
    payload = body("insert-only-published")
    assert json_response(create(conn, payload), 201)["slug"] == payload["slug"]
    original = Content.get_paper(payload["slug"])

    collision = create(recycle(conn), Map.put(payload, "title", "Unwanted replacement"))
    assert json_response(collision, 409)["error"]["code"] == "paper_exists"
    assert Content.get_paper(payload["slug"]) == original
  end

  test "refuses an existing draft without creating a published twin", %{conn: conn} do
    payload = body("insert-only-draft")

    {:ok, draft} =
      Content.create_document(
        "paper",
        %{
          "doc_id" => payload["slug"],
          "title" => "Existing draft",
          "content" => payload
        },
        "production"
      )

    assert json_response(create(conn, payload), 409)["error"]["code"] == "paper_exists"
    refute Content.get_paper(payload["slug"])
    assert {:ok, ^draft} = Content.get_document(draft.doc_id, "paper", "production")
  end

  test "cannot address the draft namespace or silently accept a revision fence", %{conn: conn} do
    assert json_response(create(conn, body("drafts.insert-only-invalid")), 400)["error"]
    payload = body("insert-only-fence") |> Map.put("ifRev", "1")
    assert create(recycle(conn), payload).status in [400, 422]
    refute Content.get_paper(payload["slug"])
  end

  test "retains authentication and authoring-wall refusals", %{conn: conn} do
    payload = body("insert-only-auth")
    assert json_response(create(conn, payload, "invalid"), 401)["error"]
    invalid = payload |> Map.delete("tags") |> Map.delete("description")
    assert json_response(create(recycle(conn), invalid), 422)["error"]
    refute Content.get_paper(payload["slug"])
  end

  test "a bound credential cannot retarget the create into another workspace", %{conn: conn} do
    a = create_workspace!()
    b = create_workspace!()
    create_project!(a, "default")
    create_project!(b, "default")
    raw = "create-scope-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(raw, "create scope", "production", ["read", "write", "admin"], a.id)

    payload = body("insert-only-scope") |> Map.put("workspace_id", b.id)
    response = create(conn, payload, raw)
    assert json_response(response, 422)["error"]["code"] == "workspace_scope_conflict"
    refute Content.get_paper(payload["slug"], "production", workspace_id: a.id)
    refute Content.get_paper(payload["slug"], "production", workspace_id: b.id)
  end
end
