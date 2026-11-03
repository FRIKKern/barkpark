defmodule BarkparkWeb.TokenSeatRestoreControllerTest do
  @moduledoc """
  `POST /v1/admin/tokens/:id/seats/restore` (task-c6185553d0bd7869): the door
  Barkpark Cloud uses to give its held admin token back the seats a rotation
  lost. Operator tier, dry run by default, and bounded by the token's revoked
  predecessors.

  async: false — the operator allowlist is Application env.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Repo}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership

  @admin ["read", "write", "admin"]

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  setup do
    put_allowlist([], [])

    home = create_workspace!(uniq("rsc-home"))
    a = create_workspace!(uniq("rsc-a"))
    other = create_workspace!(uniq("rsc-other"))

    {:ok, old} =
      Auth.create_token(uniq("old"), "barkpark cloud admin", "production", @admin, home.id)

    {:ok, _} = TenancyAuth.create_membership(a.id, old.id, "admin", "api_token")

    {:ok, {raw, new}} =
      Auth.mint_delegated_token(old, home.id, label: "barkpark cloud admin", permissions: @admin)

    {:ok, _} = Auth.revoke_token(old, old)

    # A tenant admin with the admin bit, seated only in `other`.
    raw_tenant = uniq("tenant")
    {:ok, _} = Auth.create_token(raw_tenant, "tenant admin", "production", @admin, other.id)

    %{home: home, a: a, other: other, raw: raw, new: new, old: old, tenant: raw_tenant}
  end

  defp put_allowlist(emails, ids) do
    prev_emails = Application.get_env(:barkpark, :operator_emails, [])
    prev_ids = Application.get_env(:barkpark, :operator_token_ids, [])
    Application.put_env(:barkpark, :operator_emails, emails)
    Application.put_env(:barkpark, :operator_token_ids, ids)

    on_exit(fn ->
      Application.put_env(:barkpark, :operator_emails, prev_emails)
      Application.put_env(:barkpark, :operator_token_ids, prev_ids)
    end)
  end

  defp restore(bearer, id, body) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/admin/tokens/#{id}/seats/restore", Jason.encode!(body))
  end

  defp seated?(token_id, ws_id) do
    Repo.exists?(
      from m in Membership,
        where:
          m.principal_type == "api_token" and m.principal_id == ^token_id and
            m.workspace_id == ^ws_id
    )
  end

  test "a dry run is the default and writes nothing", ctx do
    body = ctx.raw |> restore("current", %{workspaces: [ctx.a.slug]}) |> json_response(200)

    assert body["token_id"] == ctx.new.id
    assert body["predecessors"] == [ctx.old.id]

    assert body["restore"] == [
             %{"workspace" => ctx.a.slug, "role" => "admin", "from_token" => ctx.old.id}
           ]

    assert body["applied"] == false
    refute seated?(ctx.new.id, ctx.a.id)
  end

  test "apply restores the seat", ctx do
    body =
      ctx.raw
      |> restore(ctx.new.id, %{workspaces: [ctx.a.slug], apply: true})
      |> json_response(200)

    assert body["applied"] == true
    assert seated?(ctx.new.id, ctx.a.id)
    assert TenancyAuth.workspace_admin?(ctx.new.id, ctx.a.id)
  end

  test "an apply naming a workspace no predecessor held is refused 409 and writes nothing",
       ctx do
    conn = restore(ctx.raw, "current", %{workspaces: [ctx.a.slug, ctx.other.slug], apply: true})
    body = json_response(conn, 409)

    assert body["error"]["reason"] == "not_held_before"

    assert body["error"]["details"]["refused"] == [
             %{"workspace" => ctx.other.slug, "reason" => "not_held_before"}
           ]

    refute seated?(ctx.new.id, ctx.a.id)
    refute seated?(ctx.new.id, ctx.other.id)
  end

  test "a tenant admin cannot seat itself in a workspace it never held", ctx do
    conn = restore(ctx.tenant, "current", %{workspaces: [ctx.a.slug], apply: true})
    assert json_response(conn, 409)["error"]["reason"] == "not_held_before"
  end

  test "with the operator allowlist armed, only a listed token gets in", ctx do
    put_allowlist([], [ctx.new.id])

    conn = restore(ctx.tenant, ctx.new.id, %{workspaces: [ctx.a.slug], apply: true})
    assert json_response(conn, 403)["error"]["required"] == "platform_operator"
    refute seated?(ctx.new.id, ctx.a.id)

    assert ctx.raw |> restore("current", %{workspaces: [ctx.a.slug]}) |> json_response(200)
  end

  test "a token without the admin bit is refused", ctx do
    raw = uniq("reader")
    {:ok, _} = Auth.create_token(raw, "reader", "production", ["read"], ctx.home.id)
    assert restore(raw, "current", %{}).status == 403
  end

  test "bad input and unknown or revoked tokens", ctx do
    assert json_response(restore(ctx.raw, "current", %{workspaces: "x"}), 422)
    assert json_response(restore(ctx.raw, "current", %{apply: "yes"}), 422)
    assert json_response(restore(ctx.raw, Ecto.UUID.generate(), %{}), 404)

    assert json_response(restore(ctx.raw, ctx.old.id, %{}), 409)["error"]["reason"] ==
             "token_not_live"
  end
end
