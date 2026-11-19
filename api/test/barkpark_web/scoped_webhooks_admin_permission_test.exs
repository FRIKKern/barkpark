defmodule BarkparkWeb.ScopedWebhooksAdminPermissionTest do
  @moduledoc """
  task-3e1492d5869d66b0 — every scoped webhook action needs the `admin`
  permission as well as an admin seat.

  The flat `/v1/webhooks` tier rides `:flat_admin_api` (the `admin`
  permission), and docs/auth.md lists `/v1/webhooks/*` under `admin`. The
  scoped tier rode `:scoped_admin` alone, so a token holding `read`+`write`
  whose seat was raised to admin got 201 on create and 200 on rotate with the
  signing secret in the body, enough to forge `x-barkpark-signature` to the
  receiver. Studio's webhooks page calls `Barkpark.Webhooks` over a session,
  bp's webhook verbs already declare tier `admin`, and Cloud calls these
  routes with its `barkpark cloud admin` token, which holds `admin`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    ws = create_workspace!("scoped-webhooks-perm-#{System.unique_integer([:positive])}")
    project = create_project!(ws)

    seat = fn perms ->
      raw = "scoped-webhooks-#{Enum.join(perms, "-")}-#{System.unique_integer([:positive])}"
      {:ok, tok} = Auth.create_token(raw, "webhooks #{inspect(perms)}", @dataset, perms)
      {:ok, m} = TenancyAuth.create_membership(ws.id, tok.id, "admin", "api_token")
      assert m.role == "admin"
      raw
    end

    %{
      base: "/w/#{ws.slug}/p/#{project.slug}/v1/webhooks/#{@dataset}",
      read_raw: seat.(["read"]),
      write_raw: seat.(["read", "write"]),
      admin_raw: seat.(["read", "write", "admin"])
    }
  end

  defp req(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp create_body, do: Jason.encode!(%{"name" => "w", "url" => "https://example.com/hook"})

  defp create!(ctx) do
    conn = post(req(ctx.admin_raw), ctx.base, create_body())
    assert conn.status == 201, conn.resp_body
    Jason.decode!(conn.resp_body)
  end

  defp assert_capability_refusal(conn, route) do
    assert conn.status == 403, "#{route}: #{conn.status} #{conn.resp_body}"
    refute conn.resp_body =~ "\"secret\"", "#{route}: a refusal must never carry a secret"

    error = Jason.decode!(conn.resp_body)["error"]
    assert error["reason"] == "missing_capability", "#{route}: #{inspect(error)}"

    assert error["hint"] =~ "This route needs the `admin` capability",
           "#{route}: the hint must name the missing `admin` permission. Got: #{error["hint"]}"
  end

  test "a read+write token on an admin seat is refused on create, with no secret", ctx do
    assert_capability_refusal(post(req(ctx.write_raw), ctx.base, create_body()), "POST create")
  end

  test "a read+write token on an admin seat is refused on rotate, with no secret", ctx do
    id = create!(ctx)["webhook"]["id"]
    conn = post(req(ctx.write_raw), "#{ctx.base}/#{id}/rotate", "{}")
    assert_capability_refusal(conn, "POST rotate")
  end

  test "a read+write token on an admin seat is refused on update and on the reads", ctx do
    id = create!(ctx)["webhook"]["id"]

    update = put(req(ctx.write_raw), "#{ctx.base}/#{id}", Jason.encode!(%{"secret" => "mine"}))
    assert_capability_refusal(update, "PUT update")
    assert_capability_refusal(get(req(ctx.write_raw), ctx.base), "GET list")
    assert_capability_refusal(get(req(ctx.write_raw), "#{ctx.base}/#{id}"), "GET show")
  end

  test "a read token on an admin seat is refused on show and list", ctx do
    id = create!(ctx)["webhook"]["id"]
    assert_capability_refusal(get(req(ctx.read_raw), ctx.base), "GET list")
    assert_capability_refusal(get(req(ctx.read_raw), "#{ctx.base}/#{id}"), "GET show")
  end

  test "CONTROL: a read+write+admin token on its admin seat creates and rotates, with the secret",
       ctx do
    created = create!(ctx)
    assert is_binary(created["secret"]), "create returns the generated secret once"

    rotated = post(req(ctx.admin_raw), "#{ctx.base}/#{created["webhook"]["id"]}/rotate", "{}")
    assert rotated.status == 200, rotated.resp_body
    assert is_binary(Jason.decode!(rotated.resp_body)["secret"])
  end

  test "PIN: show and list never carry the signing secret, even to an admin token", ctx do
    created = create!(ctx)
    secret = created["secret"]
    id = created["webhook"]["id"]

    for {route, conn} <- [
          {"GET show", get(req(ctx.admin_raw), "#{ctx.base}/#{id}")},
          {"GET list", get(req(ctx.admin_raw), ctx.base)}
        ] do
      assert conn.status == 200, "#{route}: #{conn.status} #{conn.resp_body}"
      refute conn.resp_body =~ secret, "#{route} leaked the signing secret"
      refute conn.resp_body =~ "\"secret\"", "#{route} carries a secret key"
    end
  end
end
