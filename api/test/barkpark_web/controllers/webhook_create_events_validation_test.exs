defmodule BarkparkWeb.WebhookCreateEventsValidationTest do
  @moduledoc """
  task-2195336df2daf576: `Webhook`'s `@valid_events` listed `"patch"`, but
  `Content.Writer`/`Content.Broadcast` never dispatch a webhook with that
  action — a patch mutation is reported with the generic storage-shaped
  action it actually took ("update" for an existing draft, "create" for a
  fresh fork). A hook created with `events: ["patch"]` was therefore accepted
  (HTTP 201) and could never fire. `POST /v1/webhooks/:dataset` now refuses
  it at creation (422), matching every other bad `events` entry.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  setup do
    {:ok, _} = Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    %{
      conn:
        build_conn()
        |> put_req_header("authorization", "Bearer barkpark-dev-token")
        |> put_req_header("content-type", "application/json")
    }
  end

  defp create(conn, events) do
    body = %{"name" => "Hook", "url" => "http://example.test/hook", "events" => events}
    post(conn, "/v1/webhooks/test", Jason.encode!(body))
  end

  test "patch is refused — no dispatch call ever emits it", %{conn: conn} do
    resp = create(conn, ["patch"])
    assert resp.status == 422

    body = json_response(resp, 422)
    assert body["error"]["code"] == "validation_failed"
    assert get_in(body, ["error", "details", "events"])
  end

  test "a real event the dispatcher does emit still creates the hook (control)", %{conn: conn} do
    resp = create(conn, ["discardDraft"])
    assert resp.status == 201
  end
end
