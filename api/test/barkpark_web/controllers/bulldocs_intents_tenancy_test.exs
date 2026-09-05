defmodule BarkparkWeb.BulldocsIntentsTenancyTest do
  @moduledoc """
  `task-18b31997d93e322c` — the pending-intents drain must not hand one
  workspace's `payload_html` to another workspace's token.

  ## The seam

  `BulldocsIntentsController.index/2` called `Events.list_pending_intents()` —
  the ZERO-ARG form — while the scoping leg already existed one arity up
  (`list_pending_intents/1` threads `:workspace_id` through
  `Content.Scope.scope_to_workspace_or_global/3`). `mark_processed/2` called
  `Events.mark_processed/1`, which has no scope leg at all, so a caller could
  stamp ANY workspace's intent processed and silently drain it from the owning
  workspace's own loop.

  ## Why an ordinary token reaches this door

  Both mounts ride the `:ingest` pipeline, whose `RequireIngestToken` plug
  authorizes on EITHER the instance shared secret OR any live api_token that
  satisfies the WORKSPACE-BLIND `Tenancy.Auth.permits?(token, :admin)`. So a
  token BOUND to workspace A, holding `"admin"`, passes the gate — and before
  this change it read every other workspace's intents.

  ## The fixture stands up TWO workspaces on purpose

  The sibling suite (`bulldocs_intents_controller_test.exs`) seeds events with
  a NULL workspace and authenticates with the shared secret, so it structurally
  cannot see a cross-tenant leak: the same rows come back whether or not the
  boundary is enforced. Every test below crosses a real seam, and each
  cross-tenant refusal is paired with a POSITIVE CONTROL in the same run — the
  A-bound token SEES A's own intent — so an empty result can never be mistaken
  for a clean one.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Plugins.Bulldocs.Events

  @index_path "/v1/plugins/bulldocs/intents"
  @dataset "production"
  # Set in config/test.exs — the instance-operator shared secret.
  @ingest_secret "barkpark-test-ingest-token"

  setup do
    ws_a = create_workspace!()
    ws_b = create_workspace!()

    admin_a = "adm-a-#{System.unique_integer([:positive])}"
    admin_b = "adm-b-#{System.unique_integer([:positive])}"

    {:ok, _} = Auth.create_token(admin_a, "adm-a", @dataset, ["read", "write", "admin"], ws_a.id)
    {:ok, _} = Auth.create_token(admin_b, "adm-b", @dataset, ["read", "write", "admin"], ws_b.id)

    {:ok, intent_a} =
      Events.create_event(%{
        "goal_id" => "goal-a-#{System.unique_integer([:positive])}",
        "event_type" => "action:build",
        "payload_html" => "<p>WORKSPACE-A-PAYLOAD</p>",
        "workspace_id" => ws_a.id
      })

    {:ok, intent_b} =
      Events.create_event(%{
        "goal_id" => "goal-b-#{System.unique_integer([:positive])}",
        "event_type" => "action:build",
        "payload_html" => "<p>WORKSPACE-B-PAYLOAD</p>",
        "workspace_id" => ws_b.id
      })

    %{
      ws_a: ws_a,
      ws_b: ws_b,
      admin_a: admin_a,
      admin_b: admin_b,
      intent_a: intent_a,
      intent_b: intent_b
    }
  end

  defp bearer(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  describe "GET /v1/plugins/bulldocs/intents" do
    test "an A-bound admin token sees A's intent and NEVER B's payload_html", ctx do
      conn = bearer(ctx.admin_a) |> get(@index_path)

      assert conn.status == 200
      body = json_response(conn, 200)
      ids = Enum.map(body["intents"], & &1["id"])

      # POSITIVE CONTROL, same run: an empty seed would pass the refusal below
      # for the wrong reason. A's own row must be present.
      assert ctx.intent_a.id in ids

      # The refusal.
      refute ctx.intent_b.id in ids

      payloads = Enum.map(body["intents"], & &1["payload_html"])
      assert "<p>WORKSPACE-A-PAYLOAD</p>" in payloads
      refute "<p>WORKSPACE-B-PAYLOAD</p>" in payloads

      # Belt-and-braces on the raw wire bytes: no framing of the response can
      # smuggle B's sidecar HTML past the per-row assertion above.
      refute conn.resp_body =~ "WORKSPACE-B-PAYLOAD"
    end

    test "the mirror direction: a B-bound token sees B's intent, not A's", ctx do
      conn = bearer(ctx.admin_b) |> get(@index_path)

      ids = json_response(conn, 200)["intents"] |> Enum.map(& &1["id"])

      assert ctx.intent_b.id in ids
      refute ctx.intent_a.id in ids
    end

    test "the instance shared secret keeps its deliberate cross-workspace drain", ctx do
      conn = bearer(@ingest_secret) |> get(@index_path)

      ids = json_response(conn, 200)["intents"] |> Enum.map(& &1["id"])

      assert ctx.intent_a.id in ids
      assert ctx.intent_b.id in ids
    end
  end

  describe "POST /v1/plugins/bulldocs/intents/:id/processed" do
    test "an A-bound token cannot stamp B's intent processed", ctx do
      conn =
        bearer(ctx.admin_a)
        |> post("/v1/plugins/bulldocs/intents/#{ctx.intent_b.id}/processed")

      assert conn.status == 404
      body = json_response(conn, 404)
      assert body["ok"] == false
      assert body["error"] == "not_found"

      # The row is UNTOUCHED — a 404 that still drained B's loop would be worse
      # than a 200.
      assert is_nil(Events.get_event(ctx.intent_b.id).processed_at)
    end

    test "POSITIVE CONTROL: the same token DOES stamp its own workspace's intent", ctx do
      conn =
        bearer(ctx.admin_a)
        |> post("/v1/plugins/bulldocs/intents/#{ctx.intent_a.id}/processed")

      assert conn.status == 200
      assert json_response(conn, 200)["ok"] == true
      refute is_nil(Events.get_event(ctx.intent_a.id).processed_at)
    end
  end
end
