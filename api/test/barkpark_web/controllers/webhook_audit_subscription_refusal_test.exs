defmodule BarkparkWeb.WebhookAuditSubscriptionRefusalTest do
  @moduledoc """
  The webhook CRUD routes are gated per WORKSPACE, but the audit bridge selects
  subscriptions ORG-wide (`Webhooks.audit_webhooks_for/3`; a nil
  `organization_id` matches every org). Before this guard a workspace-bound
  admin token could POST `audit_categories` + another org's `organization_id`
  (or none) and receive that org's — or every org's — auth/token/membership/
  secret audit events. The HTTP surface now refuses those keys with a 422.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Repo, Tenancy, TenancyFixtures, Webhooks}
  alias Barkpark.Webhooks.Webhook

  import Ecto.Query, only: [from: 2]

  @token "r2c-audit-refusal-admin"

  setup do
    TenancyFixtures.ensure_default_scope!()
    ws = TenancyFixtures.create_workspace!()
    _proj = TenancyFixtures.create_project!(ws)

    {:ok, _} =
      Auth.create_token(@token, "r2c-audit", "production", ["read", "write", "admin"], ws.id)

    {:ok, victim} =
      Tenancy.create_organization(%{
        slug: "r2c-victim-#{System.unique_integer([:positive])}",
        name: "Victim"
      })

    %{ws: ws, victim: victim}
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp base_attrs(extra) do
    Map.merge(
      %{"name" => "exfil", "url" => "https://sink.example/h", "secret" => "s3cr3t-value-long"},
      extra
    )
  end

  defp exfil_rows, do: Repo.all(from(w in Webhook, where: w.name == "exfil"))

  test "a workspace admin cannot subscribe to ANOTHER org's audit stream", %{
    conn: conn,
    victim: victim
  } do
    resp =
      conn
      |> authed()
      |> post(
        "/v1/webhooks/production",
        base_attrs(%{
          "audit_categories" => ["auth", "token", "membership", "secret"],
          "organization_id" => victim.id
        })
      )

    body = json_response(resp, 422)
    assert body["error"]["code"] == "validation_failed"
    assert Map.has_key?(body["error"]["details"], "audit_categories")
    assert Map.has_key?(body["error"]["details"], "organization_id")

    assert exfil_rows() == []

    refute Enum.any?(
             Webhooks.audit_webhooks_for("auth", "login", victim.id),
             &(&1.name == "exfil")
           )
  end

  test "…nor to EVERY org's (no organization_id = global)", %{conn: conn, victim: victim} do
    resp =
      conn
      |> authed()
      |> post("/v1/webhooks/production", base_attrs(%{"audit_categories" => ["auth"]}))

    assert json_response(resp, 422)["error"]["details"] |> Map.has_key?("audit_categories")
    assert exfil_rows() == []

    refute Enum.any?(
             Webhooks.audit_webhooks_for("auth", "login", victim.id),
             &(&1.name == "exfil")
           )

    refute Enum.any?(Webhooks.audit_webhooks_for("auth", "login", nil), &(&1.name == "exfil"))
  end

  test "audit_actions and organization_id are refused on their own too", %{
    conn: conn,
    victim: victim
  } do
    for extra <- [%{"audit_actions" => ["login"]}, %{"organization_id" => victim.id}] do
      resp = conn |> authed() |> post("/v1/webhooks/production", base_attrs(extra))
      assert json_response(resp, 422)["error"]["code"] == "validation_failed"
    end

    assert exfil_rows() == []
  end

  test "an existing hook cannot be turned into an audit subscription on update", %{
    conn: conn,
    victim: victim
  } do
    created =
      conn
      |> authed()
      |> post("/v1/webhooks/production", base_attrs(%{"name" => "plain"}))
      |> json_response(201)

    id = created["webhook"]["id"]

    resp =
      build_conn()
      |> authed()
      |> put("/v1/webhooks/production/#{id}", %{
        "audit_categories" => ["secret"],
        "organization_id" => victim.id
      })

    assert json_response(resp, 422)["error"]["code"] == "validation_failed"

    row = Repo.get!(Webhook, id)
    assert row.audit_categories == []
    assert is_nil(row.organization_id)
  end

  test "CONTROL: an ordinary content webhook (empty audit fields echoed back) still creates", %{
    conn: conn,
    ws: ws
  } do
    resp =
      conn
      |> authed()
      |> post(
        "/v1/webhooks/production",
        base_attrs(%{"name" => "content-hook", "audit_categories" => [], "audit_actions" => []})
      )

    body = json_response(resp, 201)
    row = Repo.get!(Webhook, body["webhook"]["id"])
    assert row.workspace_id == ws.id
    assert row.audit_categories == []
  end
end
