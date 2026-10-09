defmodule BarkparkWeb.Studio.ConnectorsLocaleTest do
  @moduledoc """
  task-bf92938448ca864d: the Connectors page was English in an nb-NO workspace,
  chrome and provider cards alike. The page now goes through gettext, and the
  catalog's provider texts through `ConnectorsCopy`. An English workspace reads
  exactly as before.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Connectors.Catalog
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.ConnectorsCopy

  setup %{conn: conn} do
    ensure_default_scope!()

    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "conn-loc-#{suffix}", name: "Conn Locale"})
    {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    raw = "conn-loc-admin-#{suffix}"
    {:ok, admin} = Auth.create_token(raw, "admin", "production", ["read", "write", "admin"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, admin.id, "admin")

    # No connect secret: the read-only banner renders, so its words are covered too.
    Application.put_env(:barkpark, Barkpark.Connectors,
      bridge_url: "http://127.0.0.1:4020/connectors",
      connect_secret: nil,
      bridge: Barkpark.Connectors.BridgeClient
    )

    on_exit(fn -> Application.delete_env(:barkpark, Barkpark.Connectors) end)

    {:ok, conn: init_test_session(conn, %{"api_token" => raw}), ws: ws}
  end

  defp page_html(conn, ws) do
    {:ok, _view, html} = live(conn, "/w/#{ws.slug}/p/default/studio/connectors")
    html
  end

  test "the nb-NO Connectors page is Norwegian", %{conn: conn, ws: ws} do
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")
    html = page_html(conn, ws)

    assert html =~ "Tilkoblinger"
    assert html =~ "Kanaler"
    assert html =~ "Verktøy"
    assert html =~ "Tilkobling er ikke satt opp på denne installasjonen."
    assert html =~ "Ikke tilkoblet"
    assert html =~ "Dette krever det:"
    assert html =~ "Snakk med agenten din i en Telegram-direktemelding eller -gruppe."
    assert html =~ "Omtrent 60 sekunder — send en melding til @BotFather"
    assert html =~ "Teams kjører på én Azure-bot for mange leietakere"
    assert html =~ "Slik får du et token"

    refute html =~ "Talk to your agent"
    refute html =~ "What it takes:"
    refute html =~ "Not connected"
    refute html =~ "How to get a token"
  end

  test "an English workspace keeps the English Connectors page", %{conn: conn, ws: ws} do
    html = page_html(conn, ws)

    assert html =~ "Channels"
    assert html =~ "Connect is not configured on this instance."
    assert html =~ "Not connected"
    assert html =~ "What it takes:"
    assert html =~ "Talk to your agent in a Telegram DM or group."
    assert html =~ "About 60 seconds — message @BotFather, create a bot, paste its token."
    assert html =~ "How to get a token"
    refute html =~ "Ikke tilkoblet"
  end

  # A catalog string with no marker is never extracted, so it stays English in
  # every language. This reds the day one is added without a marker.
  test "every user-facing catalog string has a translation marker" do
    providers = Catalog.providers() ++ Catalog.tool_providers()

    card_texts =
      for p <- providers,
          field <- [:blurb, :effort, :credential_label, :credential_hint, :gate],
          text = Map.get(p, field),
          is_binary(text),
          do: text

    endpoint_texts =
      for p <- providers,
          endpoint = Catalog.webhook_endpoint(p.id, "probe-key"),
          endpoint,
          field <- [:label, :help],
          text = Map.get(endpoint, field),
          is_binary(text),
          do: text

    texts = Enum.uniq(card_texts ++ endpoint_texts)
    assert length(texts) > 20, "the probe read the catalog (got #{length(texts)} strings)"

    assert texts -- ConnectorsCopy.markers() == []
  end
end
