defmodule BarkparkWeb.Plugs.RequireWithinQuotaBatchTest do
  @moduledoc """
  `acpc-bl-quota-batch-overshoot-unbounded` — ONE sequential request must not
  overshoot the workspace document quota by its batch size.

  The premise, as found on origin/main: `RequireWithinQuota.call/2` asked
  `Quota.check/1` exactly once per request, and `Quota.within_quota?/1` is
  `usage < quota` — "room for at least ONE more". The request behind that one
  token carries an unbounded `mutations` list that
  `Content.Mutations.apply_mutations/3` applies in ONE transaction. So a single
  request admitted at cap-1 wrote N documents: cap 3, usage 2, 25 creates →
  usage 27, an overshoot of N-1 = 24. No race, no concurrency, no scheduler
  luck — and no fix to the TOCTOU race removes it.

  Every request below goes over HTTP through the real endpoint + router, so the
  `:scoped_api` / `:scoped_mutate` pipelines run exactly as in production and
  the gate is measured where it is actually mounted (`router.ex` :454).

  The three legs:

    1. THE REPRO — the row's measured case, inverted: 402 `quota_exceeded` and
       usage UNCHANGED at 2.
    2. POSITIVE CONTROLS — the measured real callers still succeed. `bp migrate`
       posts 50 per request by constant (`internal/cli/migrate_cmd.go:18`), the
       largest committed seed fixture is 35 (`templates/search-starter/seed.json`);
       both are driven here at 50, capped and uncapped, and must be 200. A
       delete-only batch is admitted even at `usage == quota` — a document-count
       quota has no business refusing a write that lowers the count.
    3. THE HARD CAP — 1001 mutations is refused 422 `batch_too_large` before the
       quota is consulted, so the single unbounded `Repo.transaction` is bounded
       even for an UNCAPPED workspace where the quota arm can never fire.

  async: false — mirrors `require_within_quota_test.exs`; these drive the full
  endpoint and the shared sandbox connection.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Quota
  alias BarkparkWeb.Plugs.RequireWithinQuota

  @dataset "quota_batch_ds"

  setup do
    slug = "quota-batch-#{System.unique_integer([:positive])}"
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: "Quota Batch"})
    {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        workspace_id: ws.id
      )

    raw = "quota-batch-token-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "batch writer", @dataset, ["read", "write"])
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
          "_id" => "qb-#{System.unique_integer([:positive])}-#{i}",
          "title" => "batch #{i}"
        }
      }
    end
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  # Park the workspace at `n` documents, THEN set the cap — so the seeding
  # writes are never themselves subject to the cap under test.
  defp park!(conn, slug, raw, ws, n, cap) do
    resp = mutate(conn, slug, raw, creates(n))
    assert resp.status == 200, "seeding #{n} documents failed: #{resp.status} #{resp.resp_body}"
    assert Quota.usage(ws.id) == n
    {:ok, ws} = Quota.set_quota(ws, cap)
    ws
  end

  describe "leg 1 — THE REPRO: cap 3, usage 2, a 25-create batch" do
    test "is refused 402 quota_exceeded and writes NOTHING", ctx do
      %{conn: conn, ws: ws, slug: slug, raw: raw} = ctx
      ws = park!(conn, slug, raw, ws, 2, 3)

      resp = mutate(ctx.conn, slug, raw, creates(25))

      assert resp.status == 402,
             "the gate admitted a 25-document batch into a workspace with room for ONE " <>
               "(status #{resp.status}, body #{resp.resp_body})"

      assert %{"error" => %{"code" => "quota_exceeded"}} = body(resp)

      assert Quota.usage(ws.id) == 2,
             "the refused batch must write NOTHING; usage moved to #{Quota.usage(ws.id)} " <>
               "against a cap of 3 (the row measured 27 here — an overshoot of N-1 = 24)"
    end

    test "a batch that exactly FITS the headroom is still admitted", ctx do
      %{conn: conn, ws: ws, slug: slug, raw: raw} = ctx
      ws = park!(conn, slug, raw, ws, 2, 5)

      resp = mutate(ctx.conn, slug, raw, creates(3))

      assert resp.status == 200,
             "usage 2 + 3 creates == cap 5 must fit exactly; got #{resp.status} #{resp.resp_body}"

      assert Quota.usage(ws.id) == 5
    end
  end

  describe "leg 2 — POSITIVE CONTROLS: the measured real callers still succeed" do
    test "50 creates (the `bp migrate` per-request constant) succeed on an UNCAPPED workspace",
         ctx do
      %{conn: conn, ws: ws, slug: slug, raw: raw} = ctx

      resp = mutate(conn, slug, raw, creates(50))

      assert resp.status == 200, "#{resp.status} #{resp.resp_body}"
      assert Quota.usage(ws.id) == 50
    end

    test "50 creates succeed on a CAPPED workspace with room for them", ctx do
      %{conn: conn, ws: ws, slug: slug, raw: raw} = ctx
      ws = park!(conn, slug, raw, ws, 2, 100)

      resp = mutate(ctx.conn, slug, raw, creates(50))

      assert resp.status == 200, "#{resp.status} #{resp.resp_body}"
      assert Quota.usage(ws.id) == 52
    end

    test "a DELETE-only batch is admitted at usage == quota", ctx do
      %{conn: conn, ws: ws, slug: slug, raw: raw} = ctx

      seeded = mutate(conn, slug, raw, creates(2))
      assert seeded.status == 200
      [%{"id" => id_a}, %{"id" => id_b}] = body(seeded)["results"]

      {:ok, ws} = Quota.set_quota(ws, Quota.usage(ws.id))

      resp =
        mutate(ctx.conn, slug, raw, [
          %{"delete" => %{"id" => id_a, "type" => "post"}},
          %{"delete" => %{"id" => id_b, "type" => "post"}}
        ])

      refute resp.status == 402,
             "a document-count quota refused a batch that can only LOWER the count — " <>
               "a full workspace would be wedged shut with no way to free room " <>
               "(status #{resp.status}, body #{resp.resp_body})"

      assert resp.status == 200, "#{resp.status} #{resp.resp_body}"
      assert Quota.usage(ws.id) < 2
    end
  end

  describe "leg 3 — THE HARD CAP: length(mutations) is bounded" do
    test "1001 mutations are refused 422 batch_too_large even UNCAPPED, and write nothing",
         ctx do
      %{conn: conn, ws: ws, slug: slug, raw: raw} = ctx
      assert ws.quota == nil, "this leg must run against an UNCAPPED workspace"

      over = RequireWithinQuota.max_mutations() + 1
      resp = mutate(conn, slug, raw, creates(over))

      assert resp.status == 422,
             "an unbounded batch entered the single Repo.transaction on an uncapped " <>
               "workspace, where the quota arm can never fire (status #{resp.status})"

      assert %{"error" => %{"code" => "batch_too_large", "details" => details}} = body(resp)
      assert details["count"] == over
      assert details["max"] == RequireWithinQuota.max_mutations()

      assert Quota.usage(ws.id) == 0,
             "the refused batch must write NOTHING; usage is #{Quota.usage(ws.id)}"
    end

    test "exactly the cap is admitted — the bound is not off by one", ctx do
      # Driven at the PLUG, not over HTTP: the boundary is a length check, and
      # actually writing 1000 documents costs ~4.5 s and would put the batch
      # inside Ecto's 15 s transaction timeout on a loaded box (the row measured
      # both numbers). The two HTTP legs above already prove the plug is mounted.
      at_cap = RequireWithinQuota.max_mutations()

      conn =
        ctx.conn
        |> Plug.Conn.assign(:current_workspace, %Barkpark.Tenancy.Workspace{
          id: Ecto.UUID.generate(),
          quota: nil,
          suspended: false
        })
        |> Map.put(:body_params, %{"mutations" => creates(at_cap)})
        |> RequireWithinQuota.call(RequireWithinQuota.init([]))

      refute conn.halted,
             "a batch of exactly #{at_cap} was refused — the cap is off by one " <>
               "(status #{inspect(conn.status)})"
    end
  end
end
