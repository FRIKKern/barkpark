defmodule Barkpark.Content.BoundFieldGuardTest do
  @moduledoc """
  Owner ruling #21 (2026-10-03, task-9a7298f03aad0c42): a field the schema keeps
  private may not be bound into a document body, which is public.

  Before the ruling a `field-*` block with `"fieldName" => "budget"` on a
  `private: true` field wrote fine. `Envelope` then dropped `content["budget"]`
  for an anonymous reader, but the block in `content["blocks"]` carried the
  value, and the paper reader and `body_html` printed it.

  Every author write path is covered: whole-paper upsert (and therefore
  ingest), the streaming single and batch block ops, the generic document
  writer (`/v1/data/mutate`, document block ops) and the HTTP mutate door's
  422. A public field still binds, and an encrypted-only field still binds
  (it is sealed and the renderer redacts it).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.{BoundFieldGuard, SchemaDefinition}
  alias Barkpark.Repo

  defp dataset, do: "bound_guard_#{System.unique_integer([:positive])}"

  defp schema!(name, dataset, fields) do
    {:ok, schema} =
      %SchemaDefinition{}
      |> SchemaDefinition.changeset(%{
        "name" => name,
        "title" => name,
        "dataset" => dataset,
        "visibility" => "public",
        "fields" => fields
      })
      |> Repo.insert()

    schema
  end

  @fields [
    %{"name" => "budget", "type" => "string", "private" => true},
    %{"name" => "owner_note", "type" => "string", "visibility" => "owner_only"},
    %{"name" => "allow", "type" => "string", "readable_by" => ["u-1"]},
    %{"name" => "summary", "type" => "string"},
    %{"name" => "vault", "type" => "string", "encrypted" => true}
  ]

  defp bound(id, field, value),
    do: %{"id" => id, "type" => "field-string", "fieldName" => field, "value" => value}

  defp paper!(ds, slug, blocks) do
    Content.upsert_paper(
      Barkpark.LabelFixtures.paper_attrs(%{"slug" => slug, "dataset" => ds, "blocks" => blocks})
    )
  end

  describe "check/4" do
    test "refuses private, owner_only and readable_by bindings, nested ones too" do
      ds = dataset()
      schema!("memo", ds, @fields)

      blocks = [
        bound("a", "summary", "ok"),
        bound("b", "budget", "1M"),
        %{
          "id" => "s",
          "type" => "section",
          "blocks" => [bound("c", "owner_note", "x"), bound("d", "allow", "y")]
        }
      ]

      assert {:error, {:private_field_bound, ["budget", "owner_note", "allow"]}} =
               BoundFieldGuard.check(blocks, "memo", ds, nil)
    end

    test "public, encrypted-only and unbound blocks pass; a schemaless type passes" do
      ds = dataset()
      schema!("memo", ds, @fields)

      blocks = [
        bound("a", "summary", "ok"),
        bound("b", "vault", "sealed"),
        bound("t", "title", "Title"),
        %{"id" => "p", "type" => "paragraph", "value" => "budget"}
      ]

      assert :ok = BoundFieldGuard.check(blocks, "memo", ds, nil)
      assert :ok = BoundFieldGuard.check([bound("b", "budget", "1M")], "nosuchtype", ds, nil)
    end
  end

  test "as_halt/1 turns the refusal into the editors' halt banner, other results pass" do
    assert {:error, {:halted, msg}} =
             BoundFieldGuard.as_halt({:error, {:private_field_bound, ["budget"]}})

    assert msg =~ ~s("budget")
    assert {:ok, :x} = BoundFieldGuard.as_halt({:ok, :x})
    assert {:error, :nope} = BoundFieldGuard.as_halt({:error, :nope})
  end

  describe "paper write paths" do
    test "upsert_paper (and ingest) refuses a private bound field and writes nothing" do
      ds = dataset()
      schema!("paper", ds, @fields)

      assert {:error, {:private_field_bound, ["budget"]}} =
               paper!(ds, "leaky", [bound("b1", "budget", "1M")])

      assert {:error, :not_found} = Content.get_document("leaky", "paper", ds)
    end

    test "upsert_paper still binds a public field" do
      ds = dataset()
      schema!("paper", ds, @fields)

      assert {:ok, doc} = paper!(ds, "fine", [bound("b1", "summary", "Q3 plan")])
      assert doc.content["summary"] == "Q3 plan"
    end

    test "a streaming op that binds a private field is refused; the paper is unchanged" do
      ds = dataset()
      schema!("paper", ds, @fields)
      {:ok, _} = paper!(ds, "stream", [bound("b1", "summary", "Q3 plan")])

      rebind = %{"op" => "patch-block", "id" => "b1", "patch" => %{"fieldName" => "budget"}}

      assert {:error, {:private_field_bound, ["budget"]}} =
               Content.apply_paper_block_op("stream", rebind, ds)

      insert = %{
        "op" => "insert-after",
        "afterId" => "b1",
        "block" => bound("b2", "budget", "1M")
      }

      assert {:error, {:private_field_bound, ["budget"]}} =
               Content.apply_paper_block_ops("stream", [insert], ds)

      {:ok, doc} = Content.get_document("stream", "paper", ds)
      refute Jason.encode!(doc.content) =~ "1M"

      # A legitimate edit of the public bound block still lands.
      ok = %{"op" => "patch-block", "id" => "b1", "patch" => %{"value" => "Q4 plan"}}
      assert {:ok, _} = Content.apply_paper_block_op("stream", ok, ds)
    end
  end

  describe "generic document writer" do
    test "create_document refuses a private bound block, accepts a public one" do
      ds = dataset()
      schema!("memo", ds, @fields)

      assert {:error, {:private_field_bound, ["budget"]}} =
               Content.create_document(
                 "memo",
                 %{"doc_id" => "m1", "title" => "M", "blocks" => [bound("b1", "budget", "1M")]},
                 ds
               )

      assert {:ok, _} =
               Content.create_document(
                 "memo",
                 %{"doc_id" => "m2", "title" => "M", "blocks" => [bound("b1", "summary", "ok")]},
                 ds
               )
    end
  end

  describe "HTTP" do
    test "the mutate door answers 422 private_field_bound with the field names", %{conn: conn} do
      Auth.create_token(
        "bound-guard-admin",
        "admin",
        "bound-guard",
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

      schema!("memo", "production", @fields)

      body =
        conn
        |> put_req_header("authorization", "Bearer bound-guard-admin")
        |> post("/v1/data/mutate/production", %{
          "mutations" => [
            %{
              "create" => %{
                "_id" => "bound-guard-1",
                "_type" => "memo",
                "title" => "Memo",
                "blocks" => [bound("b1", "budget", "1M")]
              }
            }
          ]
        })
        |> json_response(422)

      assert body["error"]["code"] == "private_field_bound"
      assert body["error"]["details"]["fields"] == ["budget"]
      assert body["error"]["message"] =~ "Unbind the block, or make the field public"
    end
  end
end
