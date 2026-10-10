defmodule BarkparkWeb.ReaderWritesCommentsTest do
  @moduledoc """
  Read seats may add and resolve comments (task-97702b326b8bfd6d; owner
  decision 2026-10-10, lead ruling "A, narrowed").

  A type opts in with `readerWrites`. A read seat may create it, patch the
  listed fields on anyone's document, patch everything only on a document the
  server recorded it as creating, and publish only what it just wrote. The
  negative tests prove the rest stays forbidden: another viewer's comment
  body, an unflagged type, delete, unpublish, a bare publish, and every other
  write route.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "production"
  @comment "studioComment"

  setup do
    ws_id = TenancyFixtures.default_workspace_id!()

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @comment,
          "title" => "Studio comment",
          "visibility" => "private",
          "readerWrites" => %{
            "create" => true,
            "patchFields" => ["state", "resolvedAt", "resolvedBy"]
          },
          "fields" => [
            %{"name" => "message", "type" => "text"},
            %{"name" => "state", "type" => "string"},
            %{"name" => "resolvedAt", "type" => "string"},
            %{"name" => "resolvedBy", "type" => "string"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset
      )

    %{
      ws_id: ws_id,
      viewer1: token!(ws_id, ["read"]),
      viewer2: token!(ws_id, ["read"]),
      writer: token!(ws_id, ["read", "write"])
    }
  end

  defp token!(ws_id, perms) do
    raw = "rw-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "rw", @dataset, perms, ws_id)
    raw
  end

  defp mutate(raw, mutations) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp new_id, do: "rw-comment-#{System.unique_integer([:positive])}"

  defp add_comment(raw, id, message) do
    mutate(raw, [
      %{
        "create" => %{
          "_id" => id,
          "_type" => @comment,
          "message" => message,
          "state" => "open"
        }
      },
      %{"publish" => %{"id" => id, "type" => @comment}}
    ])
  end

  defp published(id, type \\ @comment) do
    {:ok, doc} = Content.get_document(id, type, @dataset)
    doc
  end

  defp assert_refused(conn) do
    body = json_response(conn, 403)
    assert body["error"]["code"] == "forbidden"
    assert body["error"]["reason"] == "reader_write_not_permitted"
    body
  end

  test "a viewer adds a comment (create + publish)", %{viewer1: v1} do
    id = new_id()
    assert json_response(add_comment(v1, id, "hello"), 200)
    assert published(id).content["message"] == "hello"
  end

  test "another viewer resolves it (listed fields only)", %{viewer1: v1, viewer2: v2} do
    id = new_id()
    assert json_response(add_comment(v1, id, "hello"), 200)

    conn =
      mutate(v2, [
        %{"patch" => %{"id" => id, "type" => @comment, "set" => %{"state" => "resolved"}}},
        %{"publish" => %{"id" => id, "type" => @comment}}
      ])

    assert json_response(conn, 200)
    assert published(id).content["state"] == "resolved"
  end

  test "NEGATIVE: a viewer cannot edit another viewer's comment body", %{viewer1: v1, viewer2: v2} do
    id = new_id()
    assert json_response(add_comment(v1, id, "original"), 200)

    body =
      mutate(v2, [
        %{"patch" => %{"id" => id, "type" => @comment, "set" => %{"message" => "rewritten"}}},
        %{"publish" => %{"id" => id, "type" => @comment}}
      ])
      |> assert_refused()

    assert body["error"]["message"] =~ "message"
    assert published(id).content["message"] == "original"
    assert {:error, :not_found} = Content.get_document("drafts." <> id, @comment, @dataset)

    # Mixing an allowed field in does not smuggle the body through.
    mutate(v2, [
      %{
        "patch" => %{
          "id" => id,
          "type" => @comment,
          "set" => %{"state" => "resolved", "message" => "rewritten"}
        }
      }
    ])
    |> assert_refused()

    # Nor does unset.
    mutate(v2, [%{"patch" => %{"id" => id, "type" => @comment, "unset" => ["message"]}}])
    |> assert_refused()
  end

  test "the creator may edit its own comment body", %{viewer1: v1} do
    id = new_id()
    assert json_response(add_comment(v1, id, "draft one"), 200)

    conn =
      mutate(v1, [
        %{"patch" => %{"id" => id, "type" => @comment, "set" => %{"message" => "edited"}}},
        %{"publish" => %{"id" => id, "type" => @comment}}
      ])

    assert json_response(conn, 200)
    assert published(id).content["message"] == "edited"
  end

  test "control: a write seat edits any comment", %{viewer1: v1, writer: w} do
    id = new_id()
    assert json_response(add_comment(v1, id, "original"), 200)

    conn =
      mutate(w, [
        %{"patch" => %{"id" => id, "type" => @comment, "set" => %{"message" => "by writer"}}},
        %{"publish" => %{"id" => id, "type" => @comment}}
      ])

    assert json_response(conn, 200)
    assert published(id).content["message"] == "by writer"
  end

  describe "NEGATIVE: everything else stays forbidden to a viewer" do
    test "an unflagged type: create, patch, publish", %{viewer1: v1, writer: w} do
      post_id = "rw-post-#{System.unique_integer([:positive])}"

      mutate(v1, [%{"create" => %{"_id" => post_id, "_type" => "post", "title" => "x"}}])
      |> assert_refused()

      assert json_response(
               mutate(w, [
                 %{"create" => %{"_id" => post_id, "_type" => "post", "title" => "x"}},
                 %{"publish" => %{"id" => post_id, "type" => "post"}}
               ]),
               200
             )

      mutate(v1, [%{"patch" => %{"id" => post_id, "type" => "post", "set" => %{"title" => "y"}}}])
      |> assert_refused()

      assert published(post_id, "post").title == "x"
    end

    test "delete, unpublish, discardDraft and createOrReplace on a comment", %{viewer1: v1} do
      id = new_id()
      assert json_response(add_comment(v1, id, "mine"), 200)

      for op <- [
            %{"delete" => %{"id" => id, "type" => @comment}},
            %{"unpublish" => %{"id" => id, "type" => @comment}},
            %{"discardDraft" => %{"id" => id, "type" => @comment}},
            %{"createOrReplace" => %{"_id" => id, "_type" => @comment, "message" => "x"}}
          ] do
        mutate(v1, [op]) |> assert_refused()
      end

      assert published(id).content["message"] == "mine"
    end

    test "a bare publish of a draft it did not write in the batch", %{viewer1: v1, writer: w} do
      id = new_id()

      assert json_response(
               mutate(w, [%{"create" => %{"_id" => id, "_type" => @comment, "message" => "w"}}]),
               200
             )

      mutate(v1, [%{"publish" => %{"id" => id, "type" => @comment}}]) |> assert_refused()
      assert {:error, :not_found} = Content.get_document(id, @comment, @dataset)
    end

    test "an empty batch is refused, not a silent 200", %{viewer1: v1} do
      mutate(v1, []) |> assert_refused()
    end

    test "other write routes keep their 403", %{viewer1: v1} do
      conn =
        scoped_conn()
        |> put_req_header("authorization", "Bearer " <> v1)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/v1/data/revision/#{@dataset}/#{Ecto.UUID.generate()}/restore?type=#{@comment}",
          "{}"
        )

      body = json_response(conn, 403)
      refute body["error"]["reason"] == "reader_write_not_permitted"
    end
  end

  test "the schema refuses a malformed readerWrites" do
    assert {:error, %Ecto.Changeset{} = cs} =
             Content.upsert_schema(
               %{
                 "name" => "rwBad",
                 "title" => "Bad",
                 "readerWrites" => %{"create" => "yes", "deleteAll" => true}
               },
               @dataset
             )

    assert Keyword.has_key?(cs.errors, :reader_writes)
  end
end
