defmodule BarkparkWeb.MutateDryRunTest do
  @moduledoc """
  `dryRun: true` on POST /v1/data/mutate/:dataset validates and answers the
  would-be results, and persists NOTHING (task-ca600d55736bc9ca). The door used
  to ignore the flag, so a dry run committed a real draft — reported live on
  guerrilla by the barkpark-studio lead.

  Every verb is checked against the same probes: document rows, revision rows,
  mutation_events rows, the listen broadcast, the webhook fan-out and the
  after_* hook chain. Each probe has a control: the same write WITHOUT dryRun
  trips it, so a probe that can never fire cannot pass these tests.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.{Broadcast, Document, MutationEvent, Revision}
  alias Barkpark.Repo

  @dataset "test"

  setup do
    ws = Barkpark.TenancyFixtures.default_workspace_id!()

    Barkpark.Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "test",
      ["read", "write", "admin"],
      ws
    )

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @dataset
    )

    me = self()
    handler = "mutate-dry-run-#{System.unique_integer([:positive])}"

    # Both events fire in the CALLER — the request runs in this test process —
    # so `self() == me` keeps a concurrent test's writes out of the mailbox.
    :telemetry.attach_many(
      handler,
      [
        [:barkpark, :webhooks, :fan_out, :selected],
        [:barkpark, :hooks, :after_save],
        [:barkpark, :hooks, :after_publish],
        [:barkpark, :hooks, :after_unpublish],
        [:barkpark, :hooks, :after_delete]
      ],
      fn
        [_, :webhooks, :fan_out, :selected], _m, meta, _ ->
          if self() == me, do: send(me, {:webhook, meta[:doc_id]})

        [_, :hooks, event], _m, _meta, _ ->
          if self() == me, do: send(me, {:after_hook, event})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    Phoenix.PubSub.subscribe(Barkpark.PubSub, Broadcast.workspace_list_topic(@dataset, ws))

    {:ok, ws: ws}
  end

  defp mutate(body, query \\ "") do
    scoped_conn()
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}#{query}", Jason.encode!(body))
  end

  defp uid(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Everything a write can leave behind for `id` (draft + published twin).
  defp footprint(id) do
    ids = [id, "drafts." <> id]

    %{
      documents:
        Repo.all(
          from(d in Document,
            where: d.doc_id in ^ids and d.dataset == @dataset,
            order_by: d.doc_id,
            select: {d.doc_id, d.rev}
          )
        ),
      revisions:
        Repo.aggregate(
          from(r in Revision, where: r.doc_id in ^ids and r.dataset == @dataset),
          :count
        ),
      events:
        Repo.aggregate(
          from(e in MutationEvent, where: e.doc_id in ^ids and e.dataset == @dataset),
          :count
        )
    }
  end

  defp real!(mutations) do
    resp = mutate(%{"mutations" => mutations})
    assert resp.status == 200, resp.resp_body
    flush_signals()
    resp
  end

  defp flush_signals do
    receive do
      {:document_changed, _} -> flush_signals()
      {:webhook, _} -> flush_signals()
      {:after_hook, _} -> flush_signals()
    after
      50 -> :ok
    end
  end

  defp draft!(id),
    do: real!([%{"create" => %{"_id" => "drafts." <> id, "_type" => "post", "title" => "Seed"}}])

  defp published!(id) do
    draft!(id)
    real!([%{"publish" => %{"id" => id, "type" => "post"}}])
  end

  defp assert_nothing_happened(id, before, resp) do
    assert resp.status == 200, resp.resp_body
    body = Jason.decode!(resp.resp_body)
    assert body["dryRun"] == true
    assert [_ | _] = body["results"]

    assert footprint(id) == before
    refute_received {:document_changed, _}
    refute_received {:webhook, _}
    refute_received {:after_hook, _}
    body
  end

  describe "dryRun: true persists nothing" do
    test "create answers the would-be document and leaves no row, revision, event or signal" do
      id = uid("dry-create")
      before = footprint(id)
      assert before == %{documents: [], revisions: 0, events: 0}

      resp =
        mutate(%{
          "mutations" => [%{"create" => %{"_id" => id, "_type" => "post", "title" => "Would be"}}],
          "dryRun" => true
        })

      body = assert_nothing_happened(id, before, resp)
      [result] = body["results"]
      assert result["operation"] == "create"
      assert result["document"]["title"] == "Would be"
    end

    test "the ?dryRun=true query param is the same flag" do
      id = uid("dry-query")
      before = footprint(id)

      resp =
        mutate(
          %{"mutations" => [%{"create" => %{"_id" => id, "_type" => "post", "title" => "Q"}}]},
          "?dryRun=true"
        )

      assert_nothing_happened(id, before, resp)
    end

    test "createOrReplace and createIfNotExists" do
      for verb <- ["createOrReplace", "createIfNotExists"] do
        id = uid("dry-#{verb}")
        before = footprint(id)

        resp =
          mutate(%{
            "mutations" => [%{verb => %{"_id" => id, "_type" => "post", "title" => "X"}}],
            "dryRun" => true
          })

        assert_nothing_happened(id, before, resp)
      end
    end

    test "patch and replace leave the existing draft untouched" do
      id = uid("dry-patch")
      draft!(id)
      before = footprint(id)

      resp =
        mutate(%{
          "mutations" => [
            %{
              "patch" => %{
                "id" => "drafts." <> id,
                "type" => "post",
                "set" => %{"title" => "Patched"}
              }
            }
          ],
          "dryRun" => true
        })

      [result] = assert_nothing_happened(id, before, resp)["results"]
      assert result["document"]["title"] == "Patched"

      resp =
        mutate(%{
          "mutations" => [
            %{"replace" => %{"_id" => "drafts." <> id, "_type" => "post", "title" => "Replaced"}}
          ],
          "dryRun" => true
        })

      assert_nothing_happened(id, before, resp)
      {:ok, doc} = Content.get_document("drafts." <> id, "post", @dataset)
      assert doc.title == "Seed"
    end

    test "publish, discardDraft, delete and deleteExactDraft leave the draft in place" do
      for mutation <- [
            fn id, _rev -> %{"publish" => %{"id" => id, "type" => "post"}} end,
            fn id, _rev -> %{"discardDraft" => %{"id" => id, "type" => "post"}} end,
            fn id, _rev -> %{"delete" => %{"id" => id, "type" => "post"}} end,
            fn id, rev ->
              %{
                "deleteExactDraft" => %{
                  "id" => "drafts." <> id,
                  "type" => "post",
                  "ifRevisionID" => rev
                }
              }
            end
          ] do
        id = uid("dry-lifecycle")
        draft!(id)
        before = footprint(id)
        [{_draft_id, rev}] = before.documents

        resp = mutate(%{"mutations" => [mutation.(id, rev)], "dryRun" => true})
        assert_nothing_happened(id, before, resp)
      end
    end

    test "unpublish leaves the published row in place" do
      id = uid("dry-unpublish")
      published!(id)
      before = footprint(id)
      assert [{^id, _}] = before.documents

      resp =
        mutate(%{
          "mutations" => [%{"unpublish" => %{"id" => id, "type" => "post"}}],
          "dryRun" => true
        })

      assert_nothing_happened(id, before, resp)
    end

    test "a dry run that would fail answers the real error and still writes nothing" do
      id = uid("dry-invalid")
      bad = [%{"create" => %{"_id" => id, "title" => "no type"}}]

      real = mutate(%{"mutations" => bad})
      dry = mutate(%{"mutations" => bad, "dryRun" => true})

      assert dry.status == real.status
      assert dry.status == 422

      assert Jason.decode!(dry.resp_body)["error"]["code"] ==
               Jason.decode!(real.resp_body)["error"]["code"]

      assert footprint(id) == %{documents: [], revisions: 0, events: 0}
    end

    test "a dryRun value that is not a boolean is refused 400, never read as a real write" do
      for flag <- ["yes", 1, "1", %{}] do
        id = uid("dry-badflag")

        resp =
          mutate(%{
            "mutations" => [%{"create" => %{"_id" => id, "_type" => "post", "title" => "X"}}],
            "dryRun" => flag
          })

        assert resp.status == 400, resp.resp_body
        error = Jason.decode!(resp.resp_body)["error"]
        assert error["code"] == "malformed"
        assert error["message"] =~ "dryRun"
        assert footprint(id) == %{documents: [], revisions: 0, events: 0}
      end
    end
  end

  describe "control: the same write without dryRun" do
    test "writes the row, revision and event, and fires broadcast, webhook and after_save" do
      for flag <- [:absent, false, "false"] do
        id = uid("real-create")

        body = %{
          "mutations" => [%{"create" => %{"_id" => id, "_type" => "post", "title" => "Real"}}]
        }

        body = if flag == :absent, do: body, else: Map.put(body, "dryRun", flag)

        resp = mutate(body)
        assert resp.status == 200, resp.resp_body
        refute Map.has_key?(Jason.decode!(resp.resp_body), "dryRun")

        assert %{documents: [{"drafts." <> ^id, _}], revisions: 1, events: 1} = footprint(id)
        assert_received {:document_changed, %{doc_id: "drafts." <> ^id}}
        assert_received {:webhook, "drafts." <> ^id}
        assert_received {:after_hook, :after_save}
      end
    end
  end
end
