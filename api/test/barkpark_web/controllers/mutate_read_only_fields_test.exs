defmodule BarkparkWeb.MutateReadOnlyFieldsTest do
  @moduledoc """
  Owner ruling #35, item 5: a schema field marked `"readOnly" => true` is
  refused on `POST /v1/data/mutate` for a NON-ADMIN caller.

  Before this, nothing under `Barkpark.Content` read `readOnly`. A write token
  could patch a ticket's `key_id` to another submitter key and hand that key
  holder the whole thread, rewrite `messages` / `status`, or rewrite a form
  submission's `site` / `source` / `received_at` / `endpoint_id`.

  The arms:

    * REFUSED — a non-admin `patch` (`set`, `unset`), `create`,
      `createOrReplace` and `replace` that changes a readOnly field answers
      422 `validation_failed` naming the field, and the stored row is
      unchanged.
    * IDEMPOTENT — a non-admin write that carries a readOnly field at the
      value already stored (a re-save of the whole document) succeeds, and so
      does a patch of a writable field.
    * ADMIN — an admin token keeps the write.
    * PLUGIN WRITES — the ticket plugin's own create / reply / answer / close
      and form ingestion write readOnly fields through `Content`, not the HTTP
      door, and keep working.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, TenancyFixtures}
  alias Barkpark.Plugins.Forms.Intake
  alias Barkpark.Plugins.Tickets.Thread

  @dataset "test"
  @writer "barkpark-test-readonly-writer"
  @admin "barkpark-test-readonly-admin"

  setup do
    ws_id = TenancyFixtures.default_workspace_id!()

    {:ok, _} = Auth.create_token(@writer, "readonly-writer", @dataset, ["read", "write"], ws_id)

    {:ok, _} =
      Auth.create_token(@admin, "readonly-admin", @dataset, ["read", "write", "admin"], ws_id)

    schemas =
      Barkpark.Plugins.Tickets.register_schemas([]) ++
        Barkpark.Plugins.Forms.register_schemas([])

    for schema_def <- schemas do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.put("dataset", @dataset)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, workspace_id: ws_id)
    end

    key = %{id: uniq("key"), name: "Kari", workspace_id: ws_id, dataset: @dataset}
    {:ok, ticket} = Thread.create(key, %{subject: "Login broken", body: "I can't sign in"})

    %{ws_id: ws_id, key: key, ticket: ticket, id: Content.published_id(ticket.doc_id)}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mutate(token, mutations) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp patch(token, id, type, ops),
    do: mutate(token, [%{"patch" => Map.merge(%{"id" => id, "type" => type}, ops)}])

  defp stored(id, type, ws_id) do
    {:ok, doc} = Content.get_document("drafts." <> id, type, @dataset, workspace_id: ws_id)
    doc.content
  end

  defp assert_read_only_refusal(resp, field) do
    assert resp.status == 422, "expected 422, got #{resp.status} #{resp.resp_body}"
    error = Jason.decode!(resp.resp_body)["error"]
    assert error["code"] == "validation_failed"
    messages = error["details"][field]
    assert is_list(messages) and length(messages) == 1, "details: #{inspect(error["details"])}"
    assert hd(messages) =~ "read-only"
  end

  describe "a non-admin write that changes a readOnly field is refused" do
    test "patch set key_id: the thread cannot be handed to another key", ctx do
      resp = patch(@writer, ctx.id, "ticket", %{"set" => %{"key_id" => "key-attacker"}})

      assert_read_only_refusal(resp, "key_id")
      assert stored(ctx.id, "ticket", ctx.ws_id)["key_id"] == ctx.key.id
    end

    test "patch set messages and status names both fields", ctx do
      resp =
        patch(@writer, ctx.id, "ticket", %{
          "set" => %{"messages" => [], "status" => "closed"}
        })

      assert_read_only_refusal(resp, "messages")
      assert_read_only_refusal(resp, "status")
      assert [_] = stored(ctx.id, "ticket", ctx.ws_id)["messages"]
    end

    test "patch unset key_id is a change too", ctx do
      resp = patch(@writer, ctx.id, "ticket", %{"unset" => ["key_id"]})

      assert_read_only_refusal(resp, "key_id")
      assert stored(ctx.id, "ticket", ctx.ws_id)["key_id"] == ctx.key.id
    end

    test "create carrying a readOnly field is refused", _ctx do
      id = uniq("ro-create")

      resp =
        mutate(@writer, [
          %{
            "create" => %{
              "_id" => id,
              "_type" => "ticket",
              "title" => "forged",
              "content" => %{"subject" => "forged", "key_id" => "key-attacker"}
            }
          }
        ])

      assert_read_only_refusal(resp, "key_id")
    end

    test "createOrReplace onto a ticket with a different key_id is refused", ctx do
      content = Map.put(stored(ctx.id, "ticket", ctx.ws_id), "key_id", "key-attacker")

      resp =
        mutate(@writer, [
          %{
            "createOrReplace" => %{
              "_id" => ctx.id,
              "_type" => "ticket",
              "title" => "Login broken",
              "content" => content
            }
          }
        ])

      assert_read_only_refusal(resp, "key_id")
      assert stored(ctx.id, "ticket", ctx.ws_id)["key_id"] == ctx.key.id
    end

    test "replace that drops the thread is refused", ctx do
      content = Map.delete(stored(ctx.id, "ticket", ctx.ws_id), "messages")

      resp =
        mutate(@writer, [
          %{
            "replace" => %{
              "_id" => ctx.id,
              "_type" => "ticket",
              "title" => "Login broken",
              "content" => content
            }
          }
        ])

      assert_read_only_refusal(resp, "messages")
    end

    test "a form submission's site, source, received_at and endpoint_id", ctx do
      {:ok, sub} =
        Intake.store(
          %{site: "acme", dataset: @dataset, workspace_id: ctx.ws_id, project_id: nil},
          %{"email" => "a@example.com"},
          %{source: %{"referer" => "https://acme.example"}}
        )

      id = Content.published_id(sub.doc_id)

      for {field, value} <- [
            {"site", "other"},
            {"source", %{"referer" => "forged"}},
            {"received_at", "2020-01-01T00:00:00Z"},
            {"endpoint_id", "form-endpoint.other"}
          ] do
        resp = patch(@writer, id, "form_submission", %{"set" => %{field => value}})
        assert_read_only_refusal(resp, field)
      end

      assert stored(id, "form_submission", ctx.ws_id)["site"] == "acme"

      # The operator's triage field is not readOnly.
      resp = patch(@writer, id, "form_submission", %{"set" => %{"state" => "seen"}})
      assert resp.status == 200, resp.resp_body
    end
  end

  describe "legitimate writes keep working" do
    test "a non-admin patch of a writable field succeeds", ctx do
      resp = patch(@writer, ctx.id, "ticket", %{"set" => %{"subject" => "Login still broken"}})

      assert resp.status == 200, resp.resp_body
      assert stored(ctx.id, "ticket", ctx.ws_id)["subject"] == "Login still broken"
    end

    test "a readOnly field sent at its stored value is not a change", ctx do
      resp =
        patch(@writer, ctx.id, "ticket", %{
          "set" => %{"key_id" => ctx.key.id, "subject" => "re-saved"}
        })

      assert resp.status == 200, resp.resp_body

      content = stored(ctx.id, "ticket", ctx.ws_id)

      resp =
        mutate(@writer, [
          %{
            "createOrReplace" => %{
              "_id" => ctx.id,
              "_type" => "ticket",
              "title" => "re-saved",
              "content" => content
            }
          }
        ])

      assert resp.status == 200, resp.resp_body
    end

    test "a non-admin create that leaves readOnly fields alone succeeds", _ctx do
      resp =
        mutate(@writer, [
          %{
            "create" => %{
              "_id" => uniq("ro-create-ok"),
              "_type" => "ticket",
              "title" => "ok",
              "content" => %{"subject" => "ok"}
            }
          }
        ])

      assert resp.status == 200, resp.resp_body
    end

    test "an admin token keeps the write", ctx do
      resp =
        patch(@admin, ctx.id, "ticket", %{
          "set" => %{"key_id" => "key-reassigned", "status" => "closed"}
        })

      assert resp.status == 200, resp.resp_body
      assert stored(ctx.id, "ticket", ctx.ws_id)["key_id"] == "key-reassigned"
    end

    test "the ticket plugin's own reply, answer and close still write readOnly fields", ctx do
      {:ok, t1} = Thread.append(ctx.ticket, {"submitter", "Kari"}, "more detail", [])
      assert t1.content["status"] == "open"
      assert length(t1.content["messages"]) == 2

      {:ok, t2} = Thread.operator_answer(t1, "Ops", "fixed")
      assert t2.content["status"] == "answered"
      assert length(t2.content["messages"]) == 3

      {:ok, t3} = Thread.operator_close(t2)
      assert t3.content["status"] == "closed"
      assert t3.content["key_id"] == ctx.key.id
    end
  end

  # The block ops door re-projects every bound block into `content`, so a block
  # bound to `key_id` is a write to `key_id`.
  describe "POST /v1/data/doc/:dataset/:type/:id/ops" do
    defp op(token, id, rev, op) do
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/v1/data/doc/#{@dataset}/ticket/#{id}/ops",
        Jason.encode!(%{"op" => op, "ifRev" => rev})
      )
    end

    defp append(block), do: %{"op" => "append-block", "block" => block}

    defp paragraph(text, extra \\ %{}) do
      Map.merge(
        %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]},
        extra
      )
    end

    test "a non-admin block bound to key_id is refused", ctx do
      resp =
        op(
          @writer,
          ctx.id,
          ctx.ticket.rev,
          append(paragraph("x", %{"fieldName" => "key_id", "value" => "key-attacker"}))
        )

      assert_read_only_refusal(resp, "key_id")
      assert stored(ctx.id, "ticket", ctx.ws_id)["key_id"] == ctx.key.id
    end

    test "a non-admin paragraph op that leaves readOnly fields alone lands", ctx do
      resp = op(@writer, ctx.id, ctx.ticket.rev, append(paragraph("internal note")))

      assert resp.status == 200, resp.resp_body
      assert stored(ctx.id, "ticket", ctx.ws_id)["key_id"] == ctx.key.id
    end

    test "an admin keeps the write through a bound block", ctx do
      resp =
        op(
          @admin,
          ctx.id,
          ctx.ticket.rev,
          append(paragraph("x", %{"fieldName" => "key_id", "value" => "key-reassigned"}))
        )

      assert resp.status == 200, resp.resp_body
      assert stored(ctx.id, "ticket", ctx.ws_id)["key_id"] == "key-reassigned"
    end
  end
end
