defmodule BarkparkWeb.WebhookCreateSecretTest do
  @moduledoc """
  task-c8214d77e91e73d5: a webhook created with no secret (`bp webhook create
  <url> <name>`, or POST /v1/webhooks/:dataset without "secret") was stored
  secretless and delivered UNSIGNED. @barkpark/nextjs `createWebhookHandler`
  refuses an unsigned delivery, so every delivery 401'd in the receiver's app,
  and the 201 gave the caller no secret to configure.

  Now:
    * no/blank secret → one is GENERATED and returned ONCE as `secret` in the
      201 (rotate's contract), and deliveries are signed with it;
    * a caller-supplied secret is stored as given and never echoed;
    * the rendered webhook says `signed: true|false`, so a pre-existing
      secretless webhook (kept unsigned, never silently rotated) is findable.

  The signature is checked with `Dispatcher.verify_signature/5`, the byte-for-
  byte twin of `@barkpark/core` `verifyWebhookSignature`, which
  `createWebhookHandler` calls.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo
  alias Barkpark.Webhooks.{Dispatcher, Webhook}

  defmodule RecordingHTTP do
    def post(url, body, headers) do
      pid = Application.get_env(:barkpark, :test_recv_pid)
      if pid, do: send(pid, {:webhook_post, url, body, headers})
      {:ok, 200}
    end
  end

  setup do
    {:ok, _} = Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    prev_adapter = Application.get_env(:barkpark, :webhook_http_adapter)
    Application.put_env(:barkpark, :webhook_http_adapter, RecordingHTTP)
    Application.put_env(:barkpark, :test_recv_pid, self())

    on_exit(fn ->
      case prev_adapter do
        nil -> Application.delete_env(:barkpark, :webhook_http_adapter)
        v -> Application.put_env(:barkpark, :webhook_http_adapter, v)
      end

      Application.delete_env(:barkpark, :test_recv_pid)
    end)

    :ok
  end

  defp create(conn, body) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/webhooks/test", Jason.encode!(body))
  end

  # "discardDraft" never auto-dispatches here, so creating the hook fires
  # nothing on its own (no draft is discarded in this file's tests).
  @base %{"name" => "Hook", "url" => "http://example.test/hook", "events" => ["discardDraft"]}

  test "no secret → the 201 returns a generated secret once, and deliveries are signed with it",
       %{conn: conn} do
    resp = create(conn, @base)
    assert resp.status == 201
    body = Jason.decode!(resp.resp_body)

    secret = body["secret"]
    assert is_binary(secret) and String.starts_with?(secret, "whsec_")
    assert body["webhook"]["signed"] == true

    wh = Repo.get!(Webhook, body["webhook"]["id"])
    assert wh.secret == secret

    # A real delivery: replay a stored event to the new webhook.
    {:ok, ev} =
      %MutationEvent{}
      |> Ecto.Changeset.change(%{
        dataset: "test",
        # Same workspace as the hook: a workspace-less event replays only to a
        # shared-layer webhook (owner ruling #51, RQ2).
        workspace_id: wh.workspace_id,
        type: "widget",
        doc_id: "d1",
        mutation: "publish",
        rev: "r1",
        document: %{"_id" => "d1"},
        inserted_at: DateTime.utc_now()
      })
      |> Repo.insert()

    replayed =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> post("/v1/webhooks/test/#{wh.id}/deliveries/#{ev.id}/replay")

    assert replayed.status == 200

    assert_receive {:webhook_post, _url, sent, headers}, 2_000
    hmap = Map.new(headers)
    assert sig = hmap["x-barkpark-signature"]
    ts = String.to_integer(hmap["x-barkpark-timestamp"])
    assert Dispatcher.verify_signature(sent, ts, sig, [secret])
  end

  test "a blank secret is treated as none — generated and returned", %{conn: conn} do
    resp = create(conn, Map.put(@base, "secret", "   "))
    assert resp.status == 201
    assert "whsec_" <> _ = Jason.decode!(resp.resp_body)["secret"]
  end

  test "CONTROL: a caller-supplied secret is stored as given and never echoed", %{conn: conn} do
    resp = create(conn, Map.put(@base, "secret", "caller-chosen"))
    assert resp.status == 201
    body = Jason.decode!(resp.resp_body)

    refute Map.has_key?(body, "secret")
    assert body["webhook"]["signed"] == true
    assert Repo.get!(Webhook, body["webhook"]["id"]).secret == "caller-chosen"
  end

  test "a pre-existing secretless webhook is kept as is and reads signed: false", %{conn: conn} do
    resp = create(conn, Map.put(@base, "secret", "tmp"))
    id = Jason.decode!(resp.resp_body)["webhook"]["id"]
    Repo.get!(Webhook, id) |> Ecto.Changeset.change(secret: nil) |> Repo.update!()

    shown =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> get("/v1/webhooks/test/#{id}")

    assert shown.status == 200
    assert Jason.decode!(shown.resp_body)["webhook"]["signed"] == false
    assert Repo.get!(Webhook, id).secret == nil
  end
end
