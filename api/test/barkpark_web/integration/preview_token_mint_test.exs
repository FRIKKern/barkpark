defmodule BarkparkWeb.Integration.PreviewTokenMintTest do
  @moduledoc """
  task-8f7cba7f65cb343c — the admin-only HTTP mint/revoke for
  `Barkpark.PreviewToken` JWTs, and the `multi_use` reusability ruling.

  Before this, nothing minted a preview JWT over HTTP (`PreviewToken.sign/2`
  had zero production callers). This file proves:

    * `POST /v1/preview-tokens` mints a token an admin can use; a non-admin
      gets 403.
    * The DEFAULT mint is still single-use — unchanged behaviour, proven by
      reusing `preview_routes_test.exs`'s own replay assertion shape.
    * `multi_use: true` opts a token OUT of single-use: it serves many
      `/v1/preview/*` reads AND the `/v1/preview/listen/:dataset` stream,
      until `DELETE /v1/preview-tokens/:jti` revokes it or its TTL expires.
    * A `multi_use` TTL above the hard max (3600s) is clamped, never
      honoured as asked.

  `async: false` — `Application.put_env(:barkpark, :preview, …)` is global.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, PreviewToken}

  @secret "test-preview-secret-mint-1234567890"
  @admin_token "barkpark-dev-token-preview-mint"
  @reader_token "barkpark-reader-token-preview-mint"

  setup do
    prior = Application.get_env(:barkpark, :preview)

    Application.put_env(:barkpark, :preview,
      secret: @secret,
      ttl_seconds: 600,
      issuer: "barkpark"
    )

    on_exit(fn -> Application.put_env(:barkpark, :preview, prior || []) end)

    Auth.create_token(@admin_token, "dev", "preview-mint-integration", ["read", "write", "admin"])
    Auth.create_token(@reader_token, "dev", "preview-mint-integration-reader", ["read"])

    drain_task_supervisor(30_000)

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        "production"
      )

    {:ok, _} = Content.create_document("post", %{"_id" => "pm-1", "title" => "PM1"}, "production")

    :ok
  end

  defp drain_task_supervisor(deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_drain(deadline)
  end

  defp do_drain(deadline) do
    case Task.Supervisor.children(Barkpark.TaskSupervisor) do
      [] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(50)
          do_drain(deadline)
        end
    end
  end

  defp authed(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  defp preview(conn, jwt), do: put_req_header(conn, "authorization", "Preview " <> jwt)

  defp mint!(conn, body) do
    resp = conn |> authed(@admin_token) |> post("/v1/preview-tokens", body)
    assert resp.status == 201
    Jason.decode!(resp.resp_body)
  end

  # ── mint / revoke access control ────────────────────────────────────────

  test "an admin mints a token", %{conn: conn} do
    body = mint!(conn, %{"dataset" => "production"})
    assert is_binary(body["token"])
    assert is_binary(body["jti"])
    assert body["dataset"] == "production"
    assert body["multi_use"] == false
  end

  test "a non-admin (read-only) token cannot mint", %{conn: conn} do
    resp =
      conn |> authed(@reader_token) |> post("/v1/preview-tokens", %{"dataset" => "production"})

    assert resp.status == 403
  end

  test "mint without a dataset is refused", %{conn: conn} do
    resp = conn |> authed(@admin_token) |> post("/v1/preview-tokens", %{})
    assert resp.status == 422
  end

  # ── the default mint stays single-use (unchanged behaviour) ─────────────

  test "a default (non-multi_use) minted token is still single-use", %{conn: conn} do
    body = mint!(conn, %{"dataset" => "production"})
    token = body["token"]
    path = "/v1/preview/query/production/post"

    first = conn |> preview(token) |> get(path)
    assert first.status == 200

    second = conn |> preview(token) |> get(path)
    assert second.status == 401
  end

  # ── multi_use: reusable until TTL or revocation ──────────────────────────

  test "a multi_use token serves many /v1/preview reads with no replay refusal", %{conn: conn} do
    body = mint!(conn, %{"dataset" => "production", "multi_use" => true})
    token = body["token"]
    assert body["multi_use"] == true
    path = "/v1/preview/query/production/post"

    for _ <- 1..5 do
      resp = conn |> preview(token) |> get(path)
      assert resp.status == 200
    end
  end

  test "a multi_use token also serves the listen stream after being used for a read", %{
    conn: conn
  } do
    body = mint!(conn, %{"dataset" => "production", "multi_use" => true})
    token = body["token"]

    read = conn |> preview(token) |> get("/v1/preview/query/production/post")
    assert read.status == 200

    task =
      Task.async(fn ->
        conn |> preview(token) |> get("/v1/preview/listen/production", %{"lastEventId" => "0"})
      end)

    send(task.pid, :sse_overloaded)
    listen = Task.await(task, 20_000)

    assert listen.status == 200,
           "the listen stream refused a multi_use token already used for a read: #{listen.status} #{listen.resp_body}"
  end

  test "a revoked multi_use token is refused on the next request", %{conn: conn} do
    body = mint!(conn, %{"dataset" => "production", "multi_use" => true})
    token = body["token"]
    jti = body["jti"]

    first = conn |> preview(token) |> get("/v1/preview/query/production/post")
    assert first.status == 200

    revoke_resp =
      conn
      |> authed(@admin_token)
      |> delete("/v1/preview-tokens/#{jti}")

    assert revoke_resp.status == 200

    second = conn |> preview(token) |> get("/v1/preview/query/production/post")
    assert second.status == 401
  end

  test "revoking an unknown jti is a 404", %{conn: conn} do
    resp = conn |> authed(@admin_token) |> delete("/v1/preview-tokens/not-a-real-jti")
    assert resp.status == 404
  end

  test "an expired multi_use token is refused", %{conn: conn} do
    body = mint!(conn, %{"dataset" => "production", "multi_use" => true, "ttl_seconds" => 1})
    token = body["token"]

    Process.sleep(1100)

    resp = conn |> preview(token) |> get("/v1/preview/query/production/post")
    assert resp.status == 401
  end

  test "a multi_use TTL above the hard max is clamped, never honoured", %{conn: conn} do
    body =
      mint!(conn, %{"dataset" => "production", "multi_use" => true, "ttl_seconds" => 999_999})

    now = System.system_time(:second)
    {:ok, expires_at, _} = DateTime.from_iso8601(body["expires_at"])
    ttl_granted = DateTime.to_unix(expires_at) - now

    assert ttl_granted <= 3600,
           "a multi_use mint honoured a #{ttl_granted}s TTL -- the hard max (3600s) was not enforced"
  end

  test "a non-multi_use TTL is NOT clamped to the multi_use max", %{conn: conn} do
    body = mint!(conn, %{"dataset" => "production", "ttl_seconds" => 7200})

    now = System.system_time(:second)
    {:ok, expires_at, _} = DateTime.from_iso8601(body["expires_at"])
    ttl_granted = DateTime.to_unix(expires_at) - now

    assert ttl_granted > 3600,
           "a plain (single-use) mint's TTL was clamped to the multi_use ceiling -- it should not be"
  end

  test "doc_ids rides through the mint into the token's scope", %{conn: conn} do
    body = mint!(conn, %{"dataset" => "production", "doc_ids" => ["pm-1"]})
    assert body["doc_ids"] == ["pm-1"]

    token = body["token"]

    ok = conn |> preview(token) |> get("/v1/preview/doc/production/post/pm-1")
    assert ok.status == 200
  end

  # ── mint/sign still composes with the existing plug tests ───────────────
  # Not re-testing replay/expiry/revocation from scratch here -- those are
  # `preview_token_test.exs` / `preview_routes_test.exs` territory and this
  # file leaves all 4 of their scenarios byte-identical (see their own
  # moduledocs): only the multi_use OPT-OUT path above is new.
  defp also_signed_directly? do
    {_jwt, claims} = PreviewToken.sign(%{dataset: "production"}, @secret)
    is_binary(claims[:jti])
  end

  test "sanity: PreviewToken.sign/2 itself is unaffected by this change" do
    assert also_signed_directly?()
  end
end
