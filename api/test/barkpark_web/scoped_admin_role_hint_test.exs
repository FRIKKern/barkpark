defmodule BarkparkWeb.ScopedAdminRoleHintTest do
  @moduledoc """
  task-18861daee04d1328 — a `scoped_admin` refusal names what is missing.

  `RequireWorkspaceRole` admits only an `owner` or `admin` MEMBERSHIP ROLE in
  the URL's workspace; a token's global permissions do not count. It used to
  refuse with the generic `forbidden` hint, "Use a token with write/admin
  permission that is a member of this workspace". A write token that IS a
  member already satisfies every word of that, so the hint sent the caller to
  re-mint a credential the route refuses again. Every `scoped_admin` route
  runs that one plug, so one refusal serves them all: the doc actions routes
  and, as a second witness, the scoped schema upsert.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    ws = create_workspace!("role-hint-#{System.unique_integer([:positive])}")
    project = create_project!(ws)

    member_raw = "role-hint-member-#{System.unique_integer([:positive])}"
    {:ok, member} = Auth.create_token(member_raw, "write member", @dataset, ["read", "write"])
    {:ok, m} = TenancyAuth.create_membership(ws.id, member.id, "member", "api_token")
    assert m.role == "member"

    %{base: "/w/#{ws.slug}/p/#{project.slug}", member_raw: member_raw}
  end

  defp req(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp assert_role_refusal(conn, route) do
    assert conn.status == 403, "#{route}: #{conn.status} #{conn.resp_body}"
    error = Jason.decode!(conn.resp_body)["error"]

    assert error["code"] == "forbidden"
    assert error["reason"] == "workspace_role_required", "#{route}: #{inspect(error)}"

    assert error["hint"] =~ "owner or admin role",
           "#{route}: the hint must name the missing workspace role. Got: #{error["hint"]}"

    refute error["hint"] =~ "write/admin permission",
           "#{route}: a write member already holds write permission; this sends it to " <>
             "re-mint a token the route refuses again. Got: #{error["hint"]}"
  end

  test "doc actions GET refuses a write member with a hint naming the admin role", ctx do
    conn = get(req(ctx.member_raw), "#{ctx.base}/v1/data/doc/#{@dataset}/post/p1/actions")
    assert_role_refusal(conn, "GET doc actions")
  end

  test "doc run-action POST refuses a write member with a hint naming the admin role", ctx do
    url = "#{ctx.base}/v1/data/doc/#{@dataset}/post/p1/actions/publish"
    conn = post(req(ctx.member_raw), url, Jason.encode!(%{}))
    assert_role_refusal(conn, "POST run-action")
  end

  test "another scoped_admin route shares the refusal: schema upsert", ctx do
    body = %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []}
    conn = post(req(ctx.member_raw), "#{ctx.base}/v1/schemas/#{@dataset}", Jason.encode!(body))
    assert_role_refusal(conn, "POST schema upsert")
  end
end
