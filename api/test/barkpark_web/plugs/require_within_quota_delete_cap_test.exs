defmodule BarkparkWeb.Plugs.RequireWithinQuotaDeleteCapTest do
  @moduledoc """
  task-c801daf4efd35a74 — barkpark-studio's scale scout reported `POST
  /v1/data/mutate/e2e-sanity-builder` (studio-parity, a member token) with 250
  delete mutations in ONE request answering 500 `DBConnection`, while batches
  of 50 worked.

  THE MECHANISM: `delete` consumes ZERO quota room (`RequireWithinQuota`'s
  `@room_consuming_ops` excludes it), so the pre-existing `@max_mutations`
  (1000) cap never catches a delete-only batch at 250 -- it is well under
  1000. But every `"delete"` op ran `Content.Mutations.ensure_unreferenced/5`
  inside the mutate transaction, which called
  `Content.Edges.find_referencing_docs/3` -- a query PER reference-typed
  field across every schema in the dataset, PER delete. A dataset with real
  reference fields turned a batch of N deletes into O(N × reference fields)
  queries inside one transaction, unbounded by any existing gate.

  THE ORIGINAL FIX (this task, #22499): `@max_delete_mutations`, a flat,
  schema-independent cap on `RequireWithinQuota` (this gate cannot afford a
  schema query of its own just to decide whether to refuse), refusing an
  over-cap delete batch BEFORE the transaction opens. Started at 50 -- the
  size barkpark-studio measured ACTUALLY WORKING in production -- because
  100 deletes against only 3 reference fields already measured ~4.8s
  locally with zero real data and zero concurrent load, and neither
  candidate timeout (Postgres `statement_timeout` 30s; Ecto/Postgrex client
  `:timeout` 15_000ms, both per-statement/call, neither bounding a
  transaction's cumulative time) could be shown safely cleared by a looser
  number.

  THE REAL FIX (task-6b5e4b3e572d38c9): batched the reference-integrity
  query across the whole to-be-deleted id set for a consecutive run of
  deletes (`ReferenceIntegrity.referrers_for_ids/3`,
  `Content.Mutations.apply_all/4`) -- one pass per reference field for the
  WHOLE run, not per delete. Measured with the fix in place: 500 deletes /
  8 reference fields ~2.6s locally (vs. the original 100-delete / 3-field
  ~4.8s UNBATCHED measurement). `@max_delete_mutations` is raised to 500
  with that evidence -- see `RequireWithinQuota`'s own moduledoc for the
  full reasoning.

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

  test "the module's own documented cap value is 500", _ctx do
    assert RequireWithinQuota.max_delete_mutations() == 500
  end

  describe "the delete cap refuses BEFORE the transaction opens" do
    test "600 deletes in one request are refused 422 batch_too_large, naming the delete cap, never a 500",
         %{conn: conn, slug: slug, raw: raw} do
      ids = seed!(conn, slug, raw, 600)

      resp = mutate(conn, slug, raw, deletes(ids))

      refute resp.status == 500,
             "a mutate must never 500 regardless of batch size: #{resp.status} #{resp.resp_body}"

      assert resp.status == 422

      assert %{
               "error" => %{
                 "code" => "batch_too_large",
                 "details" => %{"count" => 600, "max" => 500, "kind" => "delete"}
               }
             } = body(resp)
    end

    test "nothing was deleted when the batch is refused", %{conn: conn, slug: slug, raw: raw} do
      ids = seed!(conn, slug, raw, 600)

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

    test "a batch mixing creates and 600 deletes is refused on the delete count alone, well under the overall 1000 cap",
         %{conn: conn, slug: slug, raw: raw} do
      ids = seed!(conn, slug, raw, 600)

      resp = mutate(conn, slug, raw, creates(10) ++ deletes(ids))

      assert resp.status == 422

      assert %{"error" => %{"details" => %{"count" => 600, "max" => 500, "kind" => "delete"}}} =
               body(resp)
    end

    test "exactly at the cap (500 deletes) is still admitted", %{conn: conn, slug: slug, raw: raw} do
      ids = seed!(conn, slug, raw, 500)

      resp = mutate(conn, slug, raw, deletes(ids))

      assert resp.status == 200,
             "500 deletes == the cap must fit exactly: #{resp.status} #{resp.resp_body}"

      assert length(body(resp)["results"]) == 500
    end
  end

  describe "positive control: the originally-measured production size still succeeds, comfortably" do
    test "50 deletes (the original production-measured working size) succeed", %{
      conn: conn,
      slug: slug,
      raw: raw
    } do
      ids = seed!(conn, slug, raw, 50)

      resp = mutate(conn, slug, raw, deletes(ids))

      assert resp.status == 200, "#{resp.status} #{resp.resp_body}"
      assert length(body(resp)["results"]) == 50
    end

    test "250 deletes (the batch size that originally 500'd) now succeeds", %{
      conn: conn,
      slug: slug,
      raw: raw
    } do
      ids = seed!(conn, slug, raw, 250)

      resp = mutate(conn, slug, raw, deletes(ids))

      assert resp.status == 200, "#{resp.status} #{resp.resp_body}"
      assert length(body(resp)["results"]) == 250
    end
  end
end
