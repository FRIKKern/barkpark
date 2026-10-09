defmodule BarkparkWeb.Plugs.RequireWithinQuotaDeleteCapTest do
  @moduledoc """
  task-c801daf4efd35a74 — barkpark-studio's scale scout reported `POST
  /v1/data/mutate/e2e-sanity-builder` (studio-parity, a member token) with 250
  delete mutations in ONE request answering 500 `DBConnection`, while batches
  of 50 worked.

  THE MECHANISM: `delete` consumes ZERO quota room (`RequireWithinQuota`'s
  `@room_consuming_ops` excludes it), so the pre-existing `@max_mutations`
  (1000) cap never catches a delete-only batch at 250 -- it is well under
  1000. But every `"delete"` op runs
  `Content.Mutations.ensure_unreferenced/5` inside the mutate transaction,
  which calls `Content.Edges.find_referencing_docs/3` -- a query PER
  reference-typed field across every schema in the dataset, PER delete. A
  dataset with real reference fields turns a batch of N deletes into O(N ×
  reference fields) queries inside one transaction, unbounded by any
  existing gate.

  Confirmed the mechanism directly (not merely theorized): a single
  `Content.Edges.find_referencing_docs/3` call, run against a dataset schema
  carrying 8 reference fields on an otherwise-empty corpus, measured ~14ms;
  paired with `ReferenceIntegrity.referrers/3`'s own scan, ~33ms total for
  ONE delete's reference check. 250 of those, serially, inside one
  transaction, is seconds of work from reference-checking ALONE, before the
  delete writes, hooks, broadcast or audit lines run at all -- and that is on
  a trivial local corpus; a real dataset's size, a busier box and network
  latency to Postgres only make it worse, which is the gap between "50
  works" and "250 500s" on barkpark-studio's own measurement.

  THE FIX: `@max_delete_mutations` (50) on the SAME `RequireWithinQuota` gate
  that already refuses an oversize batch before the transaction opens -- a
  flat, schema-independent cap (this gate cannot afford a schema query of
  its own just to decide whether to refuse). Set to 50, not a looser number:
  the candidate timeouts a long-held connection could cross in prod
  (Postgres `statement_timeout` 30s, Ecto/Postgrex client `:timeout`
  15_000ms, both PER STATEMENT/CALL, neither bounding a transaction making
  many fast sequential ones) are not provably cleared by a bigger cap on an
  empty local table -- 100 deletes against only 3 reference fields already
  measured ~4.8s locally, with zero real data and zero concurrent load. 50
  is the size barkpark-studio measured ACTUALLY WORKING in production, so
  it is proven, not merely hoped-for. The real fix -- batching the
  reference-integrity query across the whole to-be-deleted id set instead
  of once per id -- is a separate, larger follow-up; this cap is the
  unconditional backstop so no mutate batch size reaches a 500 in the
  meantime.

  Every request below goes over HTTP through the real endpoint + router,
  same discipline as `require_within_quota_batch_test.exs`.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Plugs.RequireWithinQuota

  @dataset "quota_delete_cap_ds"

  setup do
    slug = "quota-delcap-#{System.unique_integer([:positive])}"
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: "Quota Delete Cap"})
    {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "author", "type" => "reference", "refType" => "author"},
            %{"name" => "reviewer", "type" => "reference", "refType" => "author"},
            %{"name" => "related", "type" => "reference", "refType" => "post"}
          ]
        },
        @dataset,
        workspace_id: ws.id
      )

    raw = "quota-delcap-token-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "delete writer", @dataset, ["read", "write"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id)

    {:ok, ws: ws, slug: slug, raw: raw}
  end

  defp mutate(conn, slug, raw, mutations) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/w/#{slug}/p/default/v1/data/mutate/#{@dataset}",
      Jason.encode!(%{"mutations" => mutations})
    )
  end

  defp creates(n) do
    for i <- 1..n do
      %{
        "create" => %{
          "_type" => "post",
          "_id" => "delcap-#{System.unique_integer([:positive])}-#{i}",
          "title" => "doc #{i}"
        }
      }
    end
  end

  defp deletes(ids) do
    Enum.map(ids, fn id -> %{"delete" => %{"id" => id, "type" => "post"}} end)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp seed!(conn, slug, raw, n) do
    resp = mutate(conn, slug, raw, creates(n))
    assert resp.status == 200, "seeding #{n} documents failed: #{resp.status} #{resp.resp_body}"
    Enum.map(body(resp)["results"], & &1["id"])
  end

  test "the module's own documented cap value is 50", _ctx do
    assert RequireWithinQuota.max_delete_mutations() == 50
  end

  describe "the delete cap refuses BEFORE the transaction opens" do
    test "250 deletes in one request are refused 422 batch_too_large, naming the delete cap, never a 500",
         %{conn: conn, slug: slug, raw: raw} do
      ids = seed!(conn, slug, raw, 250)

      resp = mutate(conn, slug, raw, deletes(ids))

      refute resp.status == 500,
             "a mutate must never 500 regardless of batch size: #{resp.status} #{resp.resp_body}"

      assert resp.status == 422

      assert %{
               "error" => %{
                 "code" => "batch_too_large",
                 "details" => %{"count" => 250, "max" => 50, "kind" => "delete"}
               }
             } = body(resp)
    end

    test "nothing was deleted when the batch is refused", %{conn: conn, slug: slug, raw: raw} do
      ids = seed!(conn, slug, raw, 75)

      resp = mutate(conn, slug, raw, deletes(ids))
      assert resp.status == 422

      # The refusal runs in the PLUG, before Content.apply_mutations is ever
      # called -- confirm the transaction never opened by proving every
      # document is still readable.
      [first_id | _] = ids

      still_there =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get("/w/#{slug}/p/default/v1/data/doc/#{@dataset}/post/#{first_id}")

      assert still_there.status == 200
    end

    test "a batch mixing creates and 75 deletes is refused on the delete count alone, well under the overall 1000 cap",
         %{conn: conn, slug: slug, raw: raw} do
      ids = seed!(conn, slug, raw, 75)

      resp = mutate(conn, slug, raw, creates(10) ++ deletes(ids))

      assert resp.status == 422

      assert %{"error" => %{"details" => %{"count" => 75, "max" => 50, "kind" => "delete"}}} =
               body(resp)
    end

    test "exactly at the cap (50 deletes) is still admitted", %{conn: conn, slug: slug, raw: raw} do
      ids = seed!(conn, slug, raw, 50)

      resp = mutate(conn, slug, raw, deletes(ids))

      assert resp.status == 200,
             "50 deletes == the cap must fit exactly: #{resp.status} #{resp.resp_body}"

      assert length(body(resp)["results"]) == 50
    end
  end

  describe "positive control: the measured real caller still succeeds" do
    test "25 deletes (comfortably under the production-measured working size of 50) succeed", %{
      conn: conn,
      slug: slug,
      raw: raw
    } do
      ids = seed!(conn, slug, raw, 25)

      resp = mutate(conn, slug, raw, deletes(ids))

      assert resp.status == 200, "#{resp.status} #{resp.resp_body}"
      assert length(body(resp)["results"]) == 25
    end
  end
end
