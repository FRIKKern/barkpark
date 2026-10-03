defmodule BarkparkWeb.LoginTicketOperatorGateTest do
  @moduledoc """
  OWNER RULING 2026-10-03 #6 (task-6a1e6031438a3bcd): the EMAIL form of
  `POST /v1/auth/login-tickets` — a ticket that signs its consumer in as any
  account, skipping password, two-factor and SSO, and seats it as Default
  owner — is an instance-level power. It rides the platform-operator tier
  (`RequirePlatformOperator.permits?/1`) like every other instance-level door.

  Both arms of the allowlist run, so neither can pass by accident:

    * ARMED (`BARKPARK_OPERATOR_EMAILS` / `_TOKEN_IDS` set): an admin token the
      allowlist does not name is refused 403 `required: "platform_operator"`;
      a listed token still mints.
    * UNSET (single-tenant): the admin bit alone still mints, as before.

  The token-shaped ticket (no `email`) is untouched: it signs the browser in
  as the bearer itself, which the bearer already is.

  `async: false` — the allowlist is Application env, global to the node.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  @admin_token "lt-op-gate-admin-token-abcdef"
  @operator_token "lt-op-gate-operator-token-abcdef"
  @email "victim@other.example"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "tenant admin", "production", ["read", "write", "admin"])

    {:ok, operator} =
      Auth.create_token(@operator_token, "operator", "production", ["read", "write", "admin"])

    %{operator: operator}
  end

  defp mint(token, body) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/auth/login-tickets", Jason.encode!(body))
  end

  defp arm(emails, ids) do
    prev_emails = Application.get_env(:barkpark, :operator_emails, [])
    prev_ids = Application.get_env(:barkpark, :operator_token_ids, [])
    Application.put_env(:barkpark, :operator_emails, emails)
    Application.put_env(:barkpark, :operator_token_ids, ids)

    on_exit(fn ->
      Application.put_env(:barkpark, :operator_emails, prev_emails)
      Application.put_env(:barkpark, :operator_token_ids, prev_ids)
    end)
  end

  test "armed: a non-operator admin token cannot mint an email ticket", %{operator: op} do
    arm([], [op.id])

    resp = mint(@admin_token, %{email: @email})
    assert resp.status == 403
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "forbidden"
    assert body["error"]["required"] == "platform_operator"
    refute Barkpark.Accounts.get_user_by_email(@email)
  end

  test "armed: the listed operator token still mints an email ticket", %{operator: op} do
    arm([], [op.id])

    resp = mint(@operator_token, %{email: @email})
    assert is_binary(Jason.decode!(resp.resp_body)["ticket"])
    assert resp.status == 201
  end

  test "armed: a non-operator admin token still mints a token-shaped ticket", %{operator: op} do
    arm([], [op.id])

    resp = mint(@admin_token, %{})
    assert resp.status == 201
  end

  test "armed: a read-only token keeps the generic 401 (no operator oracle)", %{operator: op} do
    arm([], [op.id])
    {:ok, _} = Auth.create_token("lt-op-gate-reader-abcdef", "reader", "production", ["read"])

    assert mint("lt-op-gate-reader-abcdef", %{email: @email}).status == 401
  end

  test "unset (single-tenant): the admin bit alone still mints an email ticket" do
    arm([], [])

    resp = mint(@admin_token, %{email: @email})
    assert resp.status == 201
  end
end
