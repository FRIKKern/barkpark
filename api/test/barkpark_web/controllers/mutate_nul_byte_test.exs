defmodule BarkparkWeb.MutateNulByteTest do
  @moduledoc """
  task-0d3af3362c4702d8 (#28695 review, smaller notes): Postgres stores no
  NUL (U+0000) in text or jsonb, so a write holding one raised in the insert
  and the API answered 500. `Content.Document.changeset/2`, the changeset
  every write door goes through, now refuses it: 422 `validation_failed`
  naming the field and the path to the string, and nothing is written.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @dataset "production"
  @type_name "nulbyte"

  setup %{conn: conn} do
    ws = create_workspace!("nulbyte-ws-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "NulByte",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "body", "type" => "richText"},
            %{"name" => "notes", "type" => "text"},
            %{"name" => "blob", "type" => "json"}
          ]
        },
        @dataset,
        scope
      )

    raw = "nulbyte-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "nulbyte", @dataset, ["read", "write", "admin"], ws.id)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> raw), scope: scope}
  end

  defp mutate(conn, mutation) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => [mutation]}))
  end

  defp create(conn, id, doc),
    do: mutate(conn, %{"create" => Map.merge(%{"_type" => @type_name, "doc_id" => id}, doc)})

  defp id, do: "nulbyte-#{System.unique_integer([:positive])}"

  defp rows(id) do
    Repo.aggregate(
      from(d in Document, where: d.doc_id in ^[id, "drafts." <> id] and d.type == @type_name),
      :count
    )
  end

  defp refused!(resp, field, message) do
    assert resp.status == 422, resp.resp_body
    error = Jason.decode!(resp.resp_body)["error"]
    assert error["code"] == "validation_failed"
    assert error["details"] == %{field => [message]}
  end

  describe "a NUL byte in a write" do
    test "in a richText link address is a 422 naming the field, not a 500", %{conn: conn} do
      id = id()

      resp =
        create(conn, id, %{
          "title" => "T",
          "content" => %{"body" => ~s|<a href="https://x\u0000y">x</a>|}
        })

      refused!(resp, "content", "holds a NUL byte at /body")
      assert rows(id) == 0
    end

    for {label, content, message} <- [
          {"a text field", %{"notes" => "a\u0000b"}, "at /notes"},
          {"a json field, nested", %{"blob" => %{"a" => [1, %{"b~/c" => "\u0000"}]}},
           "at /blob/a/1/b~0~1c"},
          {"an object key", %{"blob" => %{"k\u0000" => 1}}, "in a key at /blob"},
          {"an undeclared field", %{"extra" => "\u0000"}, "at /extra"}
        ] do
      @content content
      @message message
      test "in #{label} is refused at its path", %{conn: conn} do
        id = id()

        refused!(
          create(conn, id, %{"title" => "T", "content" => @content}),
          "content",
          "holds a NUL byte " <> @message
        )

        assert rows(id) == 0
      end
    end

    test "in the title is refused on the title", %{conn: conn} do
      id = id()
      refused!(create(conn, id, %{"title" => "a\u0000"}), "title", "holds a NUL byte")
      assert rows(id) == 0
    end

    test "a patch that adds one is refused, and the row keeps its value", %{conn: conn} do
      id = id()
      assert create(conn, id, %{"title" => "T", "content" => %{"notes" => "ok"}}).status == 200

      resp =
        mutate(conn, %{
          "patch" => %{"id" => id, "type" => @type_name, "set" => %{"notes" => "x\u0000"}}
        })

      refused!(resp, "content", "holds a NUL byte at /notes")

      notes =
        Repo.one(
          from d in Document,
            where: d.doc_id == ^("drafts." <> id) and d.type == @type_name,
            select: d.content["notes"]
        )

      assert notes == "ok"
    end

    test "other control characters and an escaped \\u0000 in text are written", %{conn: conn} do
      content = %{"notes" => "tab\tbell\u0007 and the text \\u0000", "body" => "<p>\u0001</p>"}
      assert create(conn, id(), %{"title" => "T", "content" => content}).status == 200
    end
  end
end
