defmodule BarkparkWeb.Plugs.ResolveWorkspaceStudioHtmlRefusalTest do
  @moduledoc """
  task-47ab98b3226672ef — a signed-in user who opens another workspace's
  Studio URL got the raw JSON 403 envelope
  (`{"error":{"code":"forbidden","message":"caller is not a member of this
  workspace",...}}`) instead of a page in their own language. Dogfood repro:
  an agency-only admin navigating to `/w/default/p/default/d/production/studio`.

  `ResolveWorkspace` now renders a generic HTML refusal page for a SIGNED-IN
  browser request on the Studio pipelines (`allow_anonymous_default:
  :studio_demo` — the flag both `:scoped_browser` and `:shared_studio_browser`
  already carry) — and the SAME page for an unknown workspace slug as for a
  real one the caller is not a member of (NO EXISTENCE LEAK): nothing in the
  response distinguishes "this workspace does not exist" from "it exists and
  you are not in it".

  Untouched, proven by control: anonymous requests (existing redirect/demo
  behaviour), API/token callers (JSON envelope), and an actual member
  (admitted as before).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Accounts
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"
  @dataset "production"

  setup do
    prev = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, false)
    on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, prev) end)
    :ok
  end

  defp signed_in_conn(conn, email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    conn = post(conn, "/login/account", %{"email" => email, "password" => @password})
    {recycle(conn), user}
  end

  defp studio_path(ws_slug), do: "/w/#{ws_slug}/p/default/d/#{@dataset}/studio"

  test "a signed-in NON-member gets the generic HTML refusal page, not the JSON envelope",
       %{conn: conn} do
    n = System.unique_integer([:positive])
    {:ok, agency} = Tenancy.create_workspace(%{slug: "rw-agency-#{n}", name: "Agency #{n}"})
    {:ok, _} = Tenancy.create_project(agency, %{slug: "default", name: "Default"})

    {:ok, other} = Tenancy.create_workspace(%{slug: "rw-other-#{n}", name: "Other #{n}"})
    {:ok, _} = Tenancy.create_project(other, %{slug: "default", name: "Default"})

    {conn, user} = signed_in_conn(conn, "agency-admin-#{n}@example.com")
    {:ok, _} = TenancyAuth.create_membership(agency.id, user.id, "admin", "user")

    conn = get(conn, studio_path(other.slug))

    assert conn.status == 403
    refute conn.resp_body =~ "\"error\""
    refute conn.resp_body =~ "not_a_member"
    assert conn.resp_body =~ "not a member of this workspace"
    assert conn.resp_body =~ ~s(href="/")
    assert conn.resp_body =~ ~s(href="/login")
    assert get_resp_header(conn, "content-type") |> Enum.any?(&(&1 =~ "text/html"))
  end

  test "an UNKNOWN workspace slug gets the IDENTICAL page (no existence leak)", %{conn: conn} do
    n = System.unique_integer([:positive])
    {:ok, agency} = Tenancy.create_workspace(%{slug: "rw-agency2-#{n}", name: "Agency #{n}"})
    {:ok, _} = Tenancy.create_project(agency, %{slug: "default", name: "Default"})

    {conn, user} = signed_in_conn(conn, "agency-admin2-#{n}@example.com")
    {:ok, _} = TenancyAuth.create_membership(agency.id, user.id, "admin", "user")

    conn = get(conn, studio_path("rw-nonexistent-#{n}"))

    # Byte-identical shape to the "real workspace, not a member" case in the
    # test above: same status, same body, no 404, no hint that this slug
    # never existed at all.
    assert conn.status == 403
    refute conn.resp_body =~ "\"error\""
    assert conn.resp_body =~ "not a member of this workspace"
    assert get_resp_header(conn, "content-type") |> Enum.any?(&(&1 =~ "text/html"))
  end

  test "the page renders in the CALLER's own workspace locale (nb-NO), never the target's",
       %{conn: conn} do
    n = System.unique_integer([:positive])

    # The caller's OWN workspace carries the nb-NO locale — the refusal page
    # must speak it. The locale comes from the VIEWER (ScopeResolver's
    # ordinary first-membership fallback), never from the TARGET workspace
    # below, which stays plain English/unconfigured: using the target's
    # locale would itself be an existence leak (a real nb-NO workspace would
    # render Norwegian, an unknown slug would fall back to English, and that
    # difference IS the leak).
    {:ok, home} =
      Tenancy.create_workspace(%{
        slug: "rw-home-nb-#{n}",
        name: "Home #{n}",
        settings: %{"locale" => "nb-NO"}
      })

    {:ok, _} = Tenancy.create_project(home, %{slug: "default", name: "Default"})

    {:ok, other} = Tenancy.create_workspace(%{slug: "rw-other-nb-#{n}", name: "Other #{n}"})
    {:ok, _} = Tenancy.create_project(other, %{slug: "default", name: "Default"})

    {conn, user} = signed_in_conn(conn, "nb-caller-#{n}@example.com")
    {:ok, _} = TenancyAuth.create_membership(home.id, user.id, "member", "user")

    conn = get(conn, studio_path(other.slug))

    assert conn.status == 403
    assert get_resp_header(conn, "content-type") |> Enum.any?(&(&1 =~ "text/html"))
    assert conn.resp_body =~ "lang=\"nb-NO\""
    assert conn.resp_body =~ "Du er ikke medlem av dette arbeidsområdet"
    refute conn.resp_body =~ "You're not a member"
  end

  test "a signed-in MEMBER still enters (control)", %{conn: conn} do
    n = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "rw-member-ws-#{n}", name: "WS #{n}"})
    {:ok, _} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    {conn, user} = signed_in_conn(conn, "member-#{n}@example.com")
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")

    conn = get(conn, studio_path(ws.slug))

    refute conn.status == 403
  end

  # task-c1ccdbfaa26876cb changed the Studio arm on purpose: a signed-out
  # BROWSER is sent to sign in (studio_signed_out_redirect_test.exs pins it).
  # The workspace's JSON API keeps the envelope for an anonymous caller.
  test "an ANONYMOUS API request to a non-Default workspace keeps the JSON envelope", %{
    conn: conn
  } do
    n = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "rw-anon-#{n}", name: "WS #{n}"})
    {:ok, _} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    conn = get(conn, "/w/#{ws.slug}/p/default/v1/data/query/#{@dataset}/post")

    refute conn.status in [301, 302]
    assert conn.resp_body =~ "\"error\""
  end

  test "an API token caller on the same route keeps the JSON envelope (control)", %{conn: conn} do
    n = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "rw-api-#{n}", name: "WS #{n}"})
    {:ok, _} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    raw = "rw-outsider-tok-#{n}"
    {:ok, _} = Barkpark.Auth.create_token(raw, "outsider", @dataset, ["read", "write"])

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> get("/w/#{ws.slug}/p/default/v1/data/query/#{@dataset}/post")

    assert conn.status == 403
    assert conn.resp_body =~ "\"error\""
  end
end
