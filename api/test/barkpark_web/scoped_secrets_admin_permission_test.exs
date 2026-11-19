defmodule BarkparkWeb.ScopedSecretsAdminPermissionTest do
  @moduledoc """
  task-23ed7ba485104620 — every scoped secret action needs the `admin`
  permission as well as an admin seat.

  The flat `/v1/secrets` tier rides `:flat_admin_api` (RequireAdmin, the
  `admin` permission). The scoped tier rode `:scoped_admin` alone, which
  checks the seat ROLE, so a token holding `read` or `read`+`write` whose seat
  was raised to admin got 200 on the reveal with the secret value in the
  body. The ruling: index, show (reveal), the per-secret audit, PUT and
  DELETE all need `TenancyAuth.authorize(token, ws, :admin)`, the predicate
  the scoped workspace audit already uses, refused with `missing_capability`.

  `SecretController` is the only HTTP reader of the secret store, so it is
  the only place this rule lives.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Secrets}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @name "SCOPED_ADMIN_PERM"
  @value "s3cret-scoped-admin-perm"

  setup do
    ws = create_workspace!("scoped-secrets-perm-#{System.unique_integer([:positive])}")
    project = create_project!(ws)

    seat = fn perms ->
      raw = "scoped-secrets-#{Enum.join(perms, "-")}-#{System.unique_integer([:positive])}"
      {:ok, tok} = Auth.create_token(raw, "secrets #{inspect(perms)}", @dataset, perms)
      {:ok, m} = TenancyAuth.create_membership(ws.id, tok.id, "admin", "api_token")
      assert m.role == "admin"
      raw
    end

    {:ok, _} = Secrets.put(@name, @value, scope: ws.id)

    %{
      ws: ws,
      base: "/w/#{ws.slug}/p/#{project.slug}/v1/secrets",
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

  defp assert_capability_refusal(conn, route) do
    assert conn.status == 403, "#{route}: #{conn.status} #{conn.resp_body}"

    refute conn.resp_body =~ @value,
           "#{route}: a refusal must never carry the secret value"

    error = Jason.decode!(conn.resp_body)["error"]
    assert error["code"] == "forbidden"
    assert error["reason"] == "missing_capability", "#{route}: #{inspect(error)}"

    assert error["hint"] =~
             "This route needs the `admin` capability: an API token needs `admin` in its " <>
               "permissions as well as an owner or admin seat. Call with a token that carries `admin`.",
           "#{route}: the hint must name the missing `admin` permission. Got: #{error["hint"]}"

    refute error["hint"] =~ "user account",
           "#{route}: only API tokens reach this check (RequireToken runs first). Got: #{error["hint"]}"

    refute error["hint"] =~ "needs `read`",
           "#{route}: the caller already holds read; the generic hint sends it the wrong way. " <>
             "Got: #{error["hint"]}"
  end

  for {label, key} <- [{"a read token", :read_raw}, {"a read+write token", :write_raw}] do
    describe "#{label} on an admin seat" do
      test "is refused on the reveal", ctx do
        conn = get(req(ctx[unquote(key)]), "#{ctx.base}/#{@name}")
        assert_capability_refusal(conn, "GET reveal")
      end

      test "is refused on the list and the per-secret audit", ctx do
        assert_capability_refusal(get(req(ctx[unquote(key)]), ctx.base), "GET list")

        assert_capability_refusal(
          get(req(ctx[unquote(key)]), "#{ctx.base}/#{@name}/audit"),
          "GET secret audit"
        )
      end
    end
  end

  test "a read+write token on an admin seat is refused on PUT and DELETE", ctx do
    put_conn = put(req(ctx.write_raw), "#{ctx.base}/#{@name}", Jason.encode!(%{"value" => "x"}))
    assert_capability_refusal(put_conn, "PUT secret")

    assert_capability_refusal(delete(req(ctx.write_raw), "#{ctx.base}/#{@name}"), "DELETE secret")

    assert @value == Secrets.get(@name, ctx.ws.id),
           "a refused write must leave the stored value unchanged"
  end

  test "CONTROL: a read+write+admin token on its admin seat reveals, lists and writes", ctx do
    reveal = get(req(ctx.admin_raw), "#{ctx.base}/#{@name}")
    assert reveal.status == 200, reveal.resp_body
    assert Jason.decode!(reveal.resp_body)["value"] == @value

    assert get(req(ctx.admin_raw), ctx.base).status == 200
    assert get(req(ctx.admin_raw), "#{ctx.base}/#{@name}/audit").status == 200

    put_conn = put(req(ctx.admin_raw), "#{ctx.base}/#{@name}", Jason.encode!(%{"value" => "v2"}))
    assert put_conn.status == 200, put_conn.resp_body
  end
end
