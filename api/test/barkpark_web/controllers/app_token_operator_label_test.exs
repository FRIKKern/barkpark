defmodule BarkparkWeb.AppTokenOperatorLabelTest do
  @moduledoc """
  task-60ed926e61d3d048 (found by r6-lane-a hunting the ruling-#6 class):
  `RequirePlatformOperator` reads an app token's `"app:<email>"` label as its
  owner's identity, and `POST /v1/auth/app-tokens` let any minting admin pick
  that label and that email. Now a label in the `app:` namespace must name the
  token's own email, and a token for an operator-allowlisted email is minted
  only by a bearer the allowlist already names.

  `async: false`: the allowlist is node-global Application env.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias BarkparkWeb.Plugs.RequirePlatformOperator

  @operator_email "op-#{System.unique_integer([:positive])}@instance.example"

  setup do
    admin_raw = "app-label-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin_raw, "admin", "production", ["read", "write", "admin"])

    op_raw = "app-label-op-#{System.unique_integer([:positive])}"
    {:ok, op} = Auth.create_token(op_raw, "operator", "production", ["read", "write", "admin"])

    prev_e = Application.get_env(:barkpark, :operator_emails, [])
    prev_i = Application.get_env(:barkpark, :operator_token_ids, [])
    Application.put_env(:barkpark, :operator_emails, [@operator_email])
    Application.put_env(:barkpark, :operator_token_ids, [op.id])

    on_exit(fn ->
      Application.put_env(:barkpark, :operator_emails, prev_e)
      Application.put_env(:barkpark, :operator_token_ids, prev_i)
    end)

    %{admin_raw: admin_raw, op_raw: op_raw}
  end

  defp mint(raw, body) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/auth/app-tokens", Jason.encode!(body))
  end

  defp operator?(raw) do
    {:ok, token} = Auth.verify_token(raw)
    RequirePlatformOperator.permits?(token)
  end

  test "an admin cannot mint a token labelled as the operator for another email", ctx do
    resp = mint(ctx.admin_raw, %{email: "me@tenant.example", label: "app:" <> @operator_email})
    assert resp.status == 422
  end

  test "an admin cannot mint an app token FOR the operator's email", ctx do
    resp = mint(ctx.admin_raw, %{email: @operator_email})
    assert resp.status == 403
    assert Jason.decode!(resp.resp_body)["error"]["required"] == "platform_operator"
  end

  test "the operator still mints an app token for its own email", ctx do
    assert mint(ctx.op_raw, %{email: @operator_email}).status == 201
  end

  test "no app-token label makes a token the operator, whoever minted it" do
    # The root of task-60ed926e61d3d048: RequirePlatformOperator no longer
    # reads identity from the caller-chosen label at all. A token carrying the
    # operator's `app:` label but no owner user is not the operator.
    {:ok, forged} =
      Auth.create_token(
        "forged-#{System.unique_integer([:positive])}",
        "app:" <> @operator_email,
        "production",
        ["read", "write", "chat"]
      )

    assert forged.owner_user_id == nil
    refute RequirePlatformOperator.permits?(forged)
  end

  test "an operator-minted app token is the operator through its owner user, not its label",
       ctx do
    # Since #21569 (owner ruling #32 item 3) a minted app token records
    # `owner_user_id`, so the email arm recognises it by the account's real
    # email. The label plays no part: a custom label is recognised the same.
    default = json_response(mint(ctx.op_raw, %{email: @operator_email}), 201)
    assert operator?(default["token"])

    custom =
      json_response(mint(ctx.op_raw, %{email: @operator_email, label: "kitchen tablet"}), 201)

    {:ok, token} = Auth.verify_token(custom["token"])
    assert token.label == "kitchen tablet"
    assert Barkpark.Accounts.get_user(token.owner_user_id).email == @operator_email
    assert RequirePlatformOperator.permits?(token)
  end

  test "an ordinary app token (default or matching label) is unaffected", ctx do
    plain = json_response(mint(ctx.admin_raw, %{email: "phone@tenant.example"}), 201)
    refute operator?(plain["token"])

    labelled =
      mint(ctx.admin_raw, %{email: "phone2@tenant.example", label: "app:Phone2@tenant.example"})

    assert labelled.status == 201

    custom = mint(ctx.admin_raw, %{email: "phone3@tenant.example", label: "kitchen tablet"})
    assert custom.status == 201
  end
end
