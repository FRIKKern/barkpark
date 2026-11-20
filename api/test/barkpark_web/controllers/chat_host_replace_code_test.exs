defmodule BarkparkWeb.ChatHostReplaceCodeTest do
  @moduledoc """
  `POST /w/:ws/v1/chat-hosts/:id/enrollment` makes a new one-time code for a
  host still waiting to enroll (/papers/chat-host-enrollment-overhaul T2). The
  old code stops working in the same transaction and is then refused as
  `replaced`. Only the workspace owner may do it, and only for a host of the
  URL's workspace.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability owns the chat host routes.
  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.RegisteredHost
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @perms ["read", "write", "admin"]

  setup do
    ensure_default_scope!()
    suffix = System.unique_integer([:positive])
    ws = workspace!("crc-#{suffix}")
    other = workspace!("crc-other-#{suffix}")

    {:ok, owner} = Auth.create_token("crc-owner-#{suffix}", "owner", "production", @perms)
    {:ok, _} = TenancyAuth.create_membership(ws.id, owner.id, "owner")
    {:ok, _} = TenancyAuth.create_membership(other.id, owner.id, "owner")

    {:ok, admin} = Auth.create_token("crc-admin-#{suffix}", "admin", "production", @perms)
    {:ok, _} = TenancyAuth.create_membership(ws.id, admin.id, "admin")

    {:ok,
     ws: ws, other: other, owner_raw: "crc-owner-#{suffix}", admin_raw: "crc-admin-#{suffix}"}
  end

  defp workspace!(slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    {:ok, _project} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    ws
  end

  defp issue(ws) do
    {:ok, issued} = ChatHosts.issue_enrollment(ws.id, %{name: "vm", approved_roots: [tmp()]})
    issued
  end

  defp new_code(ws, host_id, raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
    |> post("/w/#{ws.slug}/v1/chat-hosts/#{host_id}/enrollment", "{}")
  end

  defp enroll(token) do
    scoped_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/v1/chat-host/enroll", Jason.encode!(%{"enrollment_token" => token}))
  end

  test "a new code replaces the old one, which is refused as enrollment_replaced", %{
    ws: ws,
    owner_raw: raw
  } do
    old = issue(ws)

    assert %{"enrollment_token" => code, "host" => host} =
             json_response(new_code(ws, old.host.id, raw), 201)

    assert code != old.enrollment_token
    assert host["name"] == "vm"
    assert host["approved_roots"] == [tmp()]
    assert host["enrollment_expires_at"]
    refute host["enrolled"]

    assert %{"error" => %{"details" => %{"reason" => "replaced"}}} =
             json_response(enroll(old.enrollment_token), 401)

    assert %{"credential" => _} = json_response(enroll(code), 201)
    assert [%{name: "vm", enrolled: true}] = ChatHosts.list_hosts(ws.id)
  end

  test "the server stores only the new code's hash", %{ws: ws, owner_raw: raw} do
    old = issue(ws)

    %{"enrollment_token" => code, "host" => %{"id" => id}} =
      json_response(new_code(ws, old.host.id, raw), 201)

    stored = Repo.get!(RegisteredHost, id)
    assert stored.enrollment_hash == :crypto.hash(:sha256, code)
    refute stored.enrollment_hash == code
  end

  test "a workspace admin's token cannot replace a pending host's code", %{
    ws: ws,
    admin_raw: raw
  } do
    old = issue(ws)

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(new_code(ws, old.host.id, raw), 403)

    assert %{"credential" => _} = json_response(enroll(old.enrollment_token), 201)
  end

  test "replacing another workspace's host is 404 and changes nothing", %{
    ws: ws,
    other: other,
    owner_raw: raw
  } do
    old = issue(other)

    assert json_response(new_code(ws, old.host.id, raw), 404)
    assert %{"credential" => _} = json_response(enroll(old.enrollment_token), 201)
  end

  test "an enrolled host needs no code: 409 already_enrolled", %{ws: ws, owner_raw: raw} do
    old = issue(ws)
    assert enroll(old.enrollment_token).status == 201

    assert %{"error" => %{"code" => "already_enrolled"}} =
             json_response(new_code(ws, old.host.id, raw), 409)
  end

  test "a revoked host and an id that is not a UUID are both 404", %{ws: ws, owner_raw: raw} do
    old = issue(ws)
    {:ok, _} = ChatHosts.revoke(ws.id, old.host.id)
    assert json_response(new_code(ws, old.host.id, raw), 404)
    assert json_response(new_code(ws, "not-a-uuid", raw), 404)
  end

  defp tmp, do: System.tmp_dir!()
end
