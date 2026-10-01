defmodule BarkparkWeb.Studio.StudioChromeCreateProjectWriteTierTest do
  @moduledoc """
  LiveView authz sweep (r4a): the chrome's `create-project` fallback is the
  LiveView twin of `POST /api/workspaces/:slug/projects`, and it gated on the
  WRONG predicate.

  The REST door was fixed in `arpss-w10-bl-readonly-member-creates-projects`:
  `member?/2` only proves the caller is SOME member, and a read-only token is
  mapped to the `"member"` role, so a `["read"]` token could mint a real
  Project + production Dataset. The controller now asks
  `Tenancy.Auth.authorize(token, ws.id, :write)`.

  `StudioChrome.chrome_fallback("create-project", …)` — which answers the event
  on every NON-StudioLive studio surface (MediaLive, ApiTesterLive,
  AccountLive, plugin pages) — still asked `Tenancy.Auth.member?/2`. Those
  surfaces carry no `Caps` gate (that hook is StudioLive-only), so a read-only
  member forging `create-project` over the socket created a project the REST
  door refuses.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Tenancy

  @dataset "production"

  setup do
    ws = create_workspace!("chrome-cp-#{System.unique_integer([:positive])}")
    {:ok, proj} = Tenancy.create_project_with_dataset(ws, %{name: "chrome-cp-p"})
    %{ws: ws, proj: proj}
  end

  defp token_member!(ws, perms) do
    raw = "chrome-cp-" <> Ecto.UUID.generate()
    {:ok, tok} = Auth.create_token(raw, "chrome-cp", @dataset, perms, ws.id)
    # create_token binds the home workspace with a perms-derived role; make the
    # membership explicit and plain "member" either way.
    case Tenancy.Auth.membership(tok, ws.id) do
      nil -> {:ok, _} = Tenancy.Auth.create_membership(ws.id, tok.id, "member")
      _ -> :ok
    end

    raw
  end

  defp media_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/media"

  test "a READ-ONLY token member cannot create a project via the chrome fallback", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    raw = token_member!(ws, ["read"])
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, view, _html} = live(conn, media_url(ws, proj))

    name = "ro-forged-#{System.unique_integer([:positive])}"
    result = render_submit(view, "create-project", %{"name" => name})

    refute match?({:error, {:live_redirect, _}}, result),
           "a read-only member was navigated into a project it just created: #{inspect(result)}"

    refute Enum.any?(Tenancy.list_projects(ws.id), &(&1.name == name)),
           "a read-only member created a project over the socket (REST refuses this)"
  end

  test "a WRITE-capable token member still creates (positive control)", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    raw = token_member!(ws, ["read", "write"])
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, view, _html} = live(conn, media_url(ws, proj))

    name = "rw-ok-#{System.unique_integer([:positive])}"
    _ = render_submit(view, "create-project", %{"name" => name})

    assert Enum.any?(Tenancy.list_projects(ws.id), &(&1.name == name))
  end
end
