defmodule BarkparkWeb.Integration.PreviewRoutesTest do
  @moduledoc """
  Integration probe for the preview API routes (Goal `barkpark-b1m`, Task
  `barkpark-upn`, gap #4).

  Pre-s7 coverage: zero for the full HTTP route. `PreviewToken` is
  plug-unit-tested in `test/barkpark/preview_token_test.exs` and
  `test/barkpark_web/plugs/preview_token_test.exs`, but neither drove a
  real `/v1/preview/...` request end-to-end.

  This file pins the contract that the `:api_preview` pipeline:

      AcceptBarkparkVendor → accepts ["json"] → ErrorEnvelopeNegotiation
        → RateLimit → PreviewToken → QueryController

  yields drafts when the `Authorization: Preview <jwt>` header carries a
  valid JWT, and rejects every other shape with 401.

  Each successful test mints a fresh JWT — the JTI replay-protection in
  `PreviewToken.record_jti/1` means a token can be used exactly once.

  `async: false` — `Application.put_env(:barkpark, :preview, …)` is global,
  and several tests share that key.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, PreviewToken}

  @secret "test-preview-secret-integration-1234567890"

  setup do
    prior = Application.get_env(:barkpark, :preview)

    Application.put_env(:barkpark, :preview,
      secret: @secret,
      ttl_seconds: 600,
      issuer: "barkpark"
    )

    on_exit(fn -> Application.put_env(:barkpark, :preview, prior || []) end)

    # The application boot kicks off a Task.Supervisor child that runs
    # plugin codelist seeders against the DB; if that task lands while
    # this test's sandbox connection is being checked out, the seeder
    # grabs the pool and our setup blows up with a checkout timeout.
    # Drain the supervisor (same pattern as resolver_outputs_test).
    drain_task_supervisor(30_000)

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        "production"
      )

    # Seed: published `pp-1` AND draft `pp-2`. Preview perspective is drafts.
    {:ok, _} = Content.create_document("post", %{"_id" => "pp-1", "title" => "P1"}, "production")
    {:ok, _} = Content.publish_document("pp-1", "post", "production")
    {:ok, _} = Content.create_document("post", %{"_id" => "pp-2", "title" => "P2"}, "production")

    :ok
  end

  defp drain_task_supervisor(deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_drain(deadline)
  end

  defp do_drain(deadline) do
    case Task.Supervisor.children(Barkpark.TaskSupervisor) do
      [] ->
        :ok

      _children ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(50)
          do_drain(deadline)
        end
    end
  end

  defp mint_jwt(claims \\ %{}) do
    {jwt, _} =
      PreviewToken.sign(Map.merge(%{dataset: "production", doc_ids: []}, claims), @secret)

    jwt
  end

  defp with_preview(conn, jwt), do: put_req_header(conn, "authorization", "Preview " <> jwt)

  # ── GET /v1/preview/query/:dataset/:type ─────────────────────────────────

  describe "GET /v1/preview/query/:dataset/:type" do
    test "with valid Preview JWT → 200 + perspective:drafts in envelope", %{conn: conn} do
      jwt = mint_jwt()

      resp =
        conn
        |> with_preview(jwt)
        |> get(~p"/v1/preview/query/production/post")

      assert resp.status == 200
      body = json_response(resp, 200)
      assert body["result"]["perspective"] == "drafts"

      # Drafts perspective: must include the unpublished doc `drafts.pp-2`.
      ids = Enum.map(body["result"]["documents"], & &1["_id"])
      assert "drafts.pp-2" in ids
    end

    test "without Authorization header → 401", %{conn: conn} do
      resp = get(conn, ~p"/v1/preview/query/production/post")
      assert resp.status == 401
    end

    test "with `Bearer <token>` (wrong scheme) → 401", %{conn: conn} do
      resp =
        conn
        |> put_req_header("authorization", "Bearer barkpark-dev-token")
        |> get(~p"/v1/preview/query/production/post")

      assert resp.status == 401
    end

    test "with a tampered JWT → 401", %{conn: conn} do
      jwt = mint_jwt()
      [header, _payload, sig] = String.split(jwt, ".")
      bad = Base.url_encode64(~s({"leak":true,"exp":99999999999}), padding: false)
      tampered = header <> "." <> bad <> "." <> sig

      resp =
        conn
        |> with_preview(tampered)
        |> get(~p"/v1/preview/query/production/post")

      assert resp.status == 401
    end
  end

  # ── GET /v1/preview/doc/:dataset/:type/:doc_id ───────────────────────────

  describe "GET /v1/preview/doc/:dataset/:type/:doc_id" do
    test "with valid JWT → 200 returns the draft", %{conn: conn} do
      jwt = mint_jwt()

      resp =
        conn
        |> with_preview(jwt)
        |> get(~p"/v1/preview/doc/production/post/drafts.pp-2")

      assert resp.status == 200
      body = json_response(resp, 200)
      # `result` is the rendered doc directly (not nested under `document`).
      assert body["result"]["_id"] == "drafts.pp-2"
      assert body["result"]["_draft"] == true
    end

    test "without Authorization → 401", %{conn: conn} do
      resp = get(conn, ~p"/v1/preview/doc/production/post/drafts.pp-2")
      assert resp.status == 401
    end

    test "with malformed JWT (not three segments) → 401", %{conn: conn} do
      resp =
        conn
        |> with_preview("not.a.jwt.extra")
        |> get(~p"/v1/preview/doc/production/post/drafts.pp-2")

      assert resp.status == 401
    end
  end
end
