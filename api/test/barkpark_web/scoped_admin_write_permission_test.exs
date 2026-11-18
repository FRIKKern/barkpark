defmodule BarkparkWeb.ScopedAdminWritePermissionTest do
  @moduledoc """
  task-2617573f7e9fea79 — a read-only token on an admin seat must not write
  through the `scoped_admin` routes.

  `RequireWorkspaceRole` used to check the membership ROLE alone, so a token
  holding only `read`, raised to an admin seat, got 201 on scoped schema
  upsert, 200 on a secret PUT and 200 on doc run-action, while the same token
  got 403 on the flat schema upsert and on every mutate. docs/auth.md keeps
  permission and membership as separate axes, and `write` is what grants a
  mutation. The ruling: the role decides authority, and for any method other
  than GET or HEAD the token's permission must also permit `:write`. Reads
  stay role-only.

  Controls: a minted write+admin token on its admin seat still writes, the
  read token still reads, and an admin user's login-session bearer is never
  judged on a token permission (it carries none).
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Content}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @password "correct horse battery staple"

  setup do
    ws = create_workspace!("scoped-write-perm-#{System.unique_integer([:positive])}")
    project = create_project!(ws)

    read_raw = "scoped-write-perm-read-#{System.unique_integer([:positive])}"
    {:ok, read_tok} = Auth.create_token(read_raw, "read admin seat", @dataset, ["read"])
    {:ok, seat} = TenancyAuth.create_membership(ws.id, read_tok.id, "admin", "api_token")
    assert seat.role == "admin"

    write_raw = "scoped-write-perm-write-#{System.unique_integer([:positive])}"

    {:ok, write_tok} =
      Auth.create_token(write_raw, "write admin seat", @dataset, ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws.id, write_tok.id, "admin", "api_token")

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "private",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: project.id
      )

    %{
      ws: ws,
      base: "/w/#{ws.slug}/p/#{project.slug}",
      read_raw: read_raw,
      write_raw: write_raw
    }
  end

  defp req(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp schema_body,
    do:
      Jason.encode!(%{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => []
      })

  defp assert_write_refusal(conn, route) do
    assert conn.status == 403, "#{route}: #{conn.status} #{conn.resp_body}"
    error = Jason.decode!(conn.resp_body)["error"]

    assert error["code"] == "forbidden"
    assert error["reason"] == "token_write_permission_required", "#{route}: #{inspect(error)}"

    assert error["hint"] =~ "`write` permission",
           "#{route}: the hint must name the token's missing permission. Got: #{error["hint"]}"
  end

  describe "a read-only token on an admin seat" do
    test "is refused on scoped schema upsert", ctx do
      conn = post(req(ctx.read_raw), "#{ctx.base}/v1/schemas/#{@dataset}", schema_body())
      assert_write_refusal(conn, "POST schema upsert")
    end

    test "is refused on doc run-action", ctx do
      url = "#{ctx.base}/v1/data/doc/#{@dataset}/post/p1/actions/publish"
      conn = post(req(ctx.read_raw), url, Jason.encode!(%{"mode" => "real"}))
      assert_write_refusal(conn, "POST run-action")
    end

    test "is refused on a secret PUT", ctx do
      url = "#{ctx.base}/v1/secrets/SCOPED_WRITE_PERM"
      conn = put(req(ctx.read_raw), url, Jason.encode!(%{"value" => "v"}))
      assert_write_refusal(conn, "PUT secret")
    end

    test "still reads: GET members and GET doc actions stay role-only", ctx do
      members = get(req(ctx.read_raw), "#{ctx.base}/v1/members")
      assert members.status == 200, members.resp_body

      actions = get(req(ctx.read_raw), "#{ctx.base}/v1/data/doc/#{@dataset}/post/p1/actions")

      refute actions.status in [401, 403],
             "GET doc actions is a read and stays role-only: #{actions.status} #{actions.resp_body}"
    end
  end

  test "CONTROL: a minted write+admin token on its admin seat still upserts a schema", ctx do
    conn = post(req(ctx.write_raw), "#{ctx.base}/v1/schemas/#{@dataset}", schema_body())
    assert conn.status == 201, conn.resp_body
  end

  test "CONTROL: an admin user's session bearer is not judged on a token permission", ctx do
    email = "scoped-write-perm-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    Accounts.confirm_provisioned_user(user)
    {:ok, _} = TenancyAuth.create_membership(ctx.ws.id, user.id, "admin", "user")

    session =
      scoped_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/auth/login", Jason.encode!(%{email: email, password: @password}))
      |> json_response(201)
      |> Map.fetch!("token")

    write =
      post(
        req(session),
        "#{ctx.base}/v1/data/mutate/#{@dataset}",
        Jason.encode!(%{
          mutations: [%{create: %{_id: "drafts.s1", _type: "post", title: "by a session"}}]
        })
      )

    assert write.status == 200, "an admin-seat session writes: #{write.status} #{write.resp_body}"

    conn = post(req(session), "#{ctx.base}/v1/schemas/#{@dataset}", schema_body())
    body = Jason.decode!(conn.resp_body)
    reason = get_in(body, ["error", "reason"])

    refute reason == "token_write_permission_required",
           "a session carries no token permission; the new check must never answer it: " <>
             conn.resp_body
  end
end
