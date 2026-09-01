defmodule BarkparkWeb.ChatHostControllerTest do
  @moduledoc """
  The OWNER-ONLY SEAT on chat-host enrollment, at the HTTP half of the pair.

  `POST /w/:workspace_slug/v1/chat-hosts/enrollments` rides
  `:require_chat_host_admin`, whose `RequireWorkspaceRole` plug already
  establishes owner-OR-admin. `create_enrollment/2` narrows that to OWNER
  alone. Until `arpss-w10-bl-chat-hosts-owner-literal-seat-fork` the narrowing
  was spelled as a literal `TenancyAuth.membership_role(...) == "owner"` HERE
  and, byte for byte, again in `BarkparkWeb.Studio.ChatHostsLive` — one rule in
  two places with no shared predicate, so a loosening applied to one and not
  the other would diverge silently. Both now call
  `Barkpark.Tenancy.Auth.workspace_owner?/2`.

  These tests do TWO different jobs and neither substitutes for the other:

    * the BEHAVIOUR tests pin the seat semantics (owner enrolls, a workspace
      `admin` does NOT, a `member` never reaches the action) — they hold the
      refactor to no change in who is admitted;
    * the SOURCE guard pins the SHAPE — the literal is gone and the named
      predicate is called. A behaviour test cannot catch a regression to the
      literal, because the literal and the predicate are behaviourally
      IDENTICAL today; the divergence risk is a FUTURE one-sided edit, so the
      only honest guard is the one that reds when the rule is spelled by hand
      again.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @controller "lib/barkpark_web/controllers/chat_host_controller.ex"

  setup %{conn: conn} do
    ensure_default_scope!()
    suffix = System.unique_integer([:positive])
    {:ok, workspace} = Tenancy.create_workspace(%{slug: "chat-host-api-#{suffix}", name: "Hosts"})
    {:ok, _project} = Tenancy.create_project(workspace, %{slug: "default", name: "Default"})

    # All three tokens carry IDENTICAL global permissions — including "admin".
    # Only the MEMBERSHIP ROLE differs, so every difference these tests observe
    # is the seat, never the token's permissions[].
    perms = ["read", "write", "admin"]

    {:ok, owner} = Auth.create_token("chat-host-owner-#{suffix}", "owner", "production", perms)
    {:ok, _} = TenancyAuth.create_membership(workspace.id, owner.id, "owner")

    {:ok, admin} = Auth.create_token("chat-host-admin-#{suffix}", "admin", "production", perms)
    {:ok, _} = TenancyAuth.create_membership(workspace.id, admin.id, "admin")

    {:ok, member} = Auth.create_token("chat-host-member-#{suffix}", "member", "production", perms)
    {:ok, _} = TenancyAuth.create_membership(workspace.id, member.id, "member")

    {:ok,
     conn: conn,
     workspace: workspace,
     path: "/w/#{workspace.slug}/v1/chat-hosts/enrollments",
     owner_raw: "chat-host-owner-#{suffix}",
     admin_raw: "chat-host-admin-#{suffix}",
     admin_token: admin,
     member_raw: "chat-host-member-#{suffix}"}
  end

  test "the workspace OWNER can issue an enrollment", %{
    conn: conn,
    workspace: workspace,
    path: path,
    owner_raw: raw
  } do
    conn = post(as(conn, raw), path, %{"name" => "laptop", "approved_roots" => [tmp()]})

    assert %{"host" => %{"name" => "laptop"}, "enrollment_token" => token} =
             json_response(conn, 201)

    assert is_binary(token)
    assert [%{name: "laptop"}] = ChatHosts.list_hosts(workspace.id)
  end

  test "a workspace ADMIN passes the route's owner-or-admin pipeline and is STILL refused the enrollment seat",
       %{conn: conn, workspace: workspace, path: path, admin_raw: raw, admin_token: admin} do
    # The distinction this test exists for: the admin is NOT stopped by
    # RequireWorkspaceRole (it admits owner AND admin) — it reaches
    # create_enrollment/2 and is refused THERE, by the owner seat.
    assert TenancyAuth.workspace_admin?(admin, workspace.id)
    refute TenancyAuth.workspace_owner?(admin, workspace.id)

    conn = post(as(conn, raw), path, %{"name" => "laptop", "approved_roots" => [tmp()]})

    assert %{"error" => %{"code" => "forbidden", "message" => "workspace owner required"}} =
             json_response(conn, 403)

    assert ChatHosts.list_hosts(workspace.id) == []
  end

  test "a workspace MEMBER never reaches the action — the pipeline halts first, nothing is enrolled",
       %{conn: conn, workspace: workspace, path: path, member_raw: raw} do
    conn = post(as(conn, raw), path, %{"name" => "laptop", "approved_roots" => [tmp()]})

    assert json_response(conn, 403)
    assert ChatHosts.list_hosts(workspace.id) == []
  end

  test "the enrollment seat is asked at the Tenancy.Auth chokepoint, never spelled as a role literal" do
    source = File.read!(@controller)
    code = code_only(source)

    # NEGATIVE leg — the literal seat rule is gone and must not come back.
    refute code =~ ~r/membership_role\([^)]*\)\s*==\s*"owner"/,
           """
           #{@controller} spells the owner seat as a literal
           `membership_role(...) == "owner"` again. That is the defect
           arpss-w10-bl-chat-hosts-owner-literal-seat-fork removed: the same
           rule then exists here AND in BarkparkWeb.Studio.ChatHostsLive with
           nothing tying them together. Call
           Barkpark.Tenancy.Auth.workspace_owner?/2 instead.
           """

    # POSITIVE leg — the guard is not vacuous: the named predicate IS called.
    assert source =~ "TenancyAuth.workspace_owner?(conn.assigns.api_token, workspace_id)",
           "#{@controller} must gate create_enrollment/2 on Tenancy.Auth.workspace_owner?/2"
  end

  # The rationale comments AT the fixed sites name the old literal on purpose —
  # so a whole-file refute would red on the fix's own prose, the classic
  # self-refuting guard. Match CODE only: drop full-line `#` comments (Elixir
  # has no block comments) before looking for the literal. A comment can never
  # authorize anyone, so nothing enforceable is lost.
  defp code_only(source) do
    source
    |> String.split("\n")
    |> Enum.reject(fn line -> String.starts_with?(String.trim_leading(line), "#") end)
    |> Enum.join("\n")
  end

  defp as(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp tmp, do: System.tmp_dir!()
end
