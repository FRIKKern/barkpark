defmodule BarkparkWeb.ChatHostEnrollReasonTest do
  @moduledoc """
  A refused enroll says why and what to do (/papers/chat-host-enrollment-overhaul
  T1). Every refusal is still the one 401 `invalid_enrollment`, so a client that
  reads only the code is unchanged. A code that once worked also carries
  `details.reason` and a message with the next step. A code no host row holds
  gets exactly the old body, so a guesser learns nothing new.

  A second Create for a name already in use is a 409 `name_taken` that says
  whether that machine is waiting or enrolled.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability owns the /v1/chat-host routes.
  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.RegisteredHost
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  setup do
    ensure_default_scope!()
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "cerr-#{suffix}", name: "CERR #{suffix}"})
    {:ok, _project} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    {:ok, ws: ws, suffix: suffix}
  end

  defp issue(ws, name \\ "vm") do
    {:ok, issued} = ChatHosts.issue_enrollment(ws.id, %{name: name, approved_roots: [tmp()]})
    issued
  end

  defp enroll(token) do
    scoped_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/v1/chat-host/enroll", Jason.encode!(%{"enrollment_token" => token}))
  end

  defp refusal(token) do
    assert %{"error" => %{"code" => "invalid_enrollment"} = error} =
             json_response(enroll(token), 401)

    error
  end

  test "an expired code is refused as enrollment_expired, with what to do", %{ws: ws} do
    issued = issue(ws)
    past = DateTime.add(DateTime.utc_now(), -60)

    Repo.update_all(
      from(h in RegisteredHost, where: h.id == ^issued.host.id),
      set: [enrollment_expires_at: past]
    )

    error = refusal(issued.enrollment_token)
    assert error["details"]["reason"] == "expired"
    assert error["message"] =~ "expired"
    assert error["message"] =~ "Make a new code"
  end

  test "a code whose host was revoked and registered again is refused as replaced", %{ws: ws} do
    old = issue(ws)
    {:ok, _} = ChatHosts.revoke(ws.id, old.host.id)
    _new = issue(ws)

    error = refusal(old.enrollment_token)
    assert error["details"]["reason"] == "replaced"
    assert error["message"] =~ "newest code"
  end

  test "a code whose waiting host was revoked is refused as revoked", %{ws: ws} do
    issued = issue(ws)
    {:ok, _} = ChatHosts.revoke(ws.id, issued.host.id)

    error = refusal(issued.enrollment_token)
    assert error["details"]["reason"] == "revoked"
  end

  test "a code that already enrolled a machine is refused as used", %{ws: ws} do
    issued = issue(ws)
    assert enroll(issued.enrollment_token).status == 201

    error = refusal(issued.enrollment_token)
    assert error["details"]["reason"] == "used"
    assert error["message"] =~ "barkpark-chat-host run"
  end

  test "an unknown code keeps the invalid_enrollment body, with no reason" do
    error = refusal("not-a-real-code")
    refute Map.has_key?(error, "details")
    assert error["message"] == "enrollment token is invalid or expired"
  end

  test "a second Create for a waiting machine's name is 409 name_taken, state pending", %{
    ws: ws,
    suffix: suffix
  } do
    raw = "cerr-owner-#{suffix}"
    {:ok, owner} = Auth.create_token(raw, "owner", "production", ["read", "write", "admin"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, owner.id, "owner")
    pending = issue(ws)

    conn =
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/w/#{ws.slug}/v1/chat-hosts/enrollments",
        Jason.encode!(%{"name" => "vm", "approved_roots" => [tmp()]})
      )

    assert %{"error" => %{"code" => "name_taken"} = error} = json_response(conn, 409)
    assert error["details"] == %{"host_id" => pending.host.id, "state" => "pending"}
    assert error["message"] =~ "already waiting to enroll"
    refute Map.has_key?(json_response(conn, 409), "enrollment_token")
  end

  defp tmp, do: System.tmp_dir!()
end
