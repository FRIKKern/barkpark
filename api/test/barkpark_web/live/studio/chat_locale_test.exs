defmodule BarkparkWeb.Studio.ChatLocaleTest do
  @moduledoc """
  task-d8d62b2a851e381b: the chat page of an nb-NO workspace rendered its
  chrome in English (sidebar, composer, palette, empty states). The chrome now
  rides gettext; the workspace locale comes from `BarkparkWeb.StudioChrome`.
  Model output, transcript notes and tool names stay as authored.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability (and the /studio/chat routes).
  @moduletag :requires_plugins

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  # Each pair is {Norwegian, English} for one piece of chat chrome.
  @pairs [
    {"Ingen chatter ennå", "No chats yet"},
    {~s(aria-label="Send melding"), ~s(aria-label="Send message")},
    {~s(aria-label="Skråstrekkommandoer"), ~s(aria-label="Slash commands")},
    {~s(aria-label="Øktmodus"), ~s(aria-label="Session mode")},
    {~s(<span class="sr-only">Legg ved et bilde</span>),
     ~s(<span class="sr-only">Attach an image</span>)},
    {"Vis arkiverte", "Show archived"},
    # The sidebar heading and its New button follow an icon's </svg>.
    {"</svg> chatter", "</svg> chats"},
    {"</svg> Ny", "</svg> New"},
    # The context band: the field name and the absence marker are words.
    {"vert (lokalt på serveren)", "host (server-local)"},
    # task-e9866733f6217e28: the context ring's tooltip before the first result.
    {~s(title="Kontekstvinduet er ukjent til det første resultatet"),
     ~s(title="Context window unknown until the first result")}
  ]

  setup %{conn: conn} do
    Barkpark.ChatSessionResidue.purge!()

    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "chat-loc-#{suffix}", name: "Chat Locale"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")

    raw = "chat-loc-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "chat-loc", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj}
  end

  test "the chat page of an nb-NO workspace is Norwegian", %{conn: conn, ws: ws, proj: proj} do
    path = "/w/#{ws.slug}/p/#{proj.slug}/studio/chat"

    assert conn |> get(path) |> html_response(200) =~ ~s(<html lang="nb-NO")

    {:ok, view, html} = live(conn, path)

    for {nb, en} <- @pairs do
      assert html =~ nb
      refute html =~ en
    end

    # The tab title is capitalised like every other Studio tab.
    assert page_title(view) == "Chat · Barkpark"
  end

  # task-42d4ac3dbd2b7b64: aria-label is prohibited on a <label> (axe
  # aria-prohibited-attr), and opacity on the dim status read below AA.
  test "the attach control names its input in hidden text, and the status is not dimmed further",
       %{conn: conn, ws: ws, proj: proj} do
    {:ok, _view, html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/studio/chat")
    doc = LazyHTML.from_fragment(html)

    [label] = doc |> LazyHTML.query("label.bp-iconbtn") |> Enum.to_list()
    assert LazyHTML.attribute(label, "aria-label") == []
    assert label |> LazyHTML.query(".sr-only") |> LazyHTML.text() == "Legg ved et bilde"

    assert [span] =
             doc
             |> LazyHTML.query("span.text-xs.text-dim")
             |> Enum.filter(&(LazyHTML.text(&1) =~ "ny chat"))

    [style] = LazyHTML.attribute(span, "style")
    refute style =~ "opacity"
  end

  test "the default workspace's chat page stays English", %{conn: conn} do
    {default_ws, default_proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    path = "/w/#{default_ws.slug}/p/#{default_proj.slug}/studio/chat"

    {:ok, _view, html} = live(conn, path)

    for {nb, en} <- @pairs do
      assert html =~ en
      refute html =~ nb
    end
  end
end
