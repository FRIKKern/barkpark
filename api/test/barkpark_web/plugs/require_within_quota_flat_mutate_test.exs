defmodule BarkparkWeb.Plugs.RequireWithinQuotaFlatMutateTest do
  @moduledoc """
  The FLAT document write doors — `POST /v1/data/mutate/:dataset` and
  `POST /v1/data/doc/:dataset/:type/:doc_id/ops` — must meet the same
  per-workspace quota gate as their scoped twins (`:scoped_mutate`).

  On origin/main they rode `[:api, :require_token, :require_write,
  :idempotent]` with no `RequireWithinQuota`, so a workspace-bound token kept
  writing after its workspace was suspended, past its document quota, and in
  batches above the 1000-mutation cap that bounds the single transaction
  (task-29d335e489b8cf0b). `:api` already derives `:current_workspace` from the
  token, so the gate meters the token's OWN workspace.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Tenancy.Quota

  @dataset "quota_flat_ds"

  setup do
    slug = "quota-flat-#{System.unique_integer([:positive])}"
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: "Quota Flat"})
    {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        workspace_id: ws.id
      )

    raw = "quota-flat-token-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "flat writer", @dataset, ["read", "write"], ws.id)

    {:ok, ws: ws, raw: raw}
  end

  defp flat_mutate(conn, raw, mutations) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp creates(n) do
    for i <- 1..n do
      %{
        "create" => %{
          "_type" => "post",
          "_id" => "qf-#{System.unique_integer([:positive])}-#{i}",
          "title" => "flat #{i}"
        }
      }
    end
  end

  test "an unsuspended, uncapped workspace still writes (control)", %{conn: conn, raw: raw} do
    assert flat_mutate(conn, raw, creates(2)).status == 200
  end

  test "a suspended workspace is refused 403 workspace_suspended", %{
    conn: conn,
    ws: ws,
    raw: raw
  } do
    {:ok, _} = Quota.suspend(ws, "flat door test")

    resp = flat_mutate(conn, raw, creates(1))
    assert resp.status == 403
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "workspace_suspended"
    assert Quota.usage(ws.id) == 0
  end

  test "a batch past the quota is refused 402 and writes nothing", %{
    conn: conn,
    ws: ws,
    raw: raw
  } do
    {:ok, _} = Quota.set_quota(ws, 3)

    resp = flat_mutate(conn, raw, creates(5))
    assert resp.status == 402
    assert Quota.usage(ws.id) == 0
  end

  test "more than 1000 mutations is refused 422 batch_too_large", %{conn: conn, raw: raw} do
    resp = flat_mutate(conn, raw, creates(1001))
    assert resp.status == 422
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "batch_too_large"
  end

  test "the flat block-op door refuses a suspended workspace", %{conn: conn, ws: ws, raw: raw} do
    {:ok, _} = Quota.suspend(ws, "flat ops test")

    resp =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")
      |> post(
        "/v1/data/doc/#{@dataset}/post/qf-ops/ops",
        Jason.encode!(%{"op" => "insert", "block" => %{"type" => "paragraph"}})
      )

    assert resp.status == 403
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "workspace_suspended"
  end
end
