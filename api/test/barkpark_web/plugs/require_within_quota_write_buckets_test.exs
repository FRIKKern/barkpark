defmodule BarkparkWeb.Plugs.RequireWithinQuotaWriteBucketsTest do
  @moduledoc """
  task-9676ef7a58a7d112: the write buckets that skipped the quota gate — the
  `/v1/tasks` verbs and `/v1/fleet/beat` (`:token_root`), the legacy
  `/api/documents` writes and the `:ingest` plugin routes — now meet the same
  `RequireWithinQuota` as `/v1/data/mutate`: a suspended workspace gets 403
  `workspace_suspended` on every write, a full one 402 `quota_exceeded` where a
  document can be added, and reads and a normal workspace are unchanged.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Tenancy.Quota

  @dataset "quota_buckets_ds"

  setup do
    slug = "quota-buckets-#{System.unique_integer([:positive])}"
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: "Quota buckets"})
    {:ok, _} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        workspace_id: ws.id
      )

    raw = "quota-buckets-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "buckets", @dataset, ["read", "write", "admin"], ws.id)

    {:ok, ws: ws, raw: raw}
  end

  defp req(method, path, raw, body \\ %{}) do
    conn =
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")

    case method do
      :get -> get(conn, path)
      :post -> post(conn, path, Jason.encode!(body))
      :delete -> delete(conn, path)
    end
  end

  defp code(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, %{"error" => %{"code" => code}}} -> code
      _ -> nil
    end
  end

  defp beat(raw),
    do:
      req(:post, "/v1/fleet/beat", raw, %{"worker" => "w-#{System.unique_integer([:positive])}"})

  defp claim(raw), do: req(:post, "/v1/tasks/claim", raw, %{"worker_id" => "quota-test"})

  defp legacy_create(raw),
    do:
      req(:post, "/api/documents/post", raw, %{
        "id" => "lq-#{System.unique_integer([:positive])}",
        "title" => "t"
      })

  defp legacy_delete(raw),
    do: req(:delete, "/api/documents/post/missing-#{System.unique_integer([:positive])}", raw)

  defp ingest_paper(raw),
    do:
      req(:post, "/v1/plugins/bulldocs/papers", raw, %{
        "slug" => "q-#{System.unique_integer([:positive])}",
        "title" => "q",
        "body" => []
      })

  defp ingest_event(raw),
    do: req(:post, "/v1/plugins/bulldocs/sessions/missing/events", raw, %{"kind" => "note"})

  defp ingest_read(raw), do: req(:get, "/v1/plugins/bulldocs/intents", raw)

  @quota_codes ~w(workspace_suspended quota_exceeded)

  test "a normal workspace is unchanged", %{raw: raw} do
    assert beat(raw).status == 200
    assert legacy_create(raw).status in 200..299

    for conn <- [claim(raw), legacy_delete(raw), ingest_paper(raw), ingest_event(raw)],
        do: refute(code(conn) in @quota_codes)
  end

  test "a suspended workspace is refused every write, as on /v1/data/mutate", %{ws: ws, raw: raw} do
    {:ok, _} = Quota.suspend(ws, "buckets test")

    for conn <- [
          beat(raw),
          claim(raw),
          legacy_create(raw),
          legacy_delete(raw),
          ingest_paper(raw),
          ingest_event(raw)
        ] do
      assert {conn.status, code(conn)} == {403, "workspace_suspended"}, conn.request_path
    end

    refute code(ingest_read(raw)) in @quota_codes
  end

  test "a full workspace is refused only where a document can be added", %{ws: ws, raw: raw} do
    {:ok, _} = Quota.set_quota(ws, Quota.usage(ws.id))

    for conn <- [beat(raw), legacy_create(raw), ingest_paper(raw)] do
      assert {conn.status, code(conn)} == {402, "quota_exceeded"}, conn.request_path
    end

    for conn <- [claim(raw), legacy_delete(raw), ingest_event(raw)],
        do: refute(code(conn) in @quota_codes, conn.request_path)
  end
end
