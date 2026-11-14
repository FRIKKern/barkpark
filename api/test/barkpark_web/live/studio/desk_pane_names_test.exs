defmodule BarkparkWeb.Studio.DeskPaneNamesTest do
  @moduledoc """
  The names the TanStack Studio's e2e specs find a document pane by
  (`DocumentPane.tsx:603-609`, `:640`): `data-testid="document-pane"`,
  `data-pane="doc:<id>"`, `.pane-header .chip` on the pills, and the hidden
  holder an inspector is later drawn in.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "pn_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Names #{type}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "pn-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Here"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-pane-names-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "desk-pane-names",
        @dataset,
        ~w(read write admin),
        Tenancy.get_default_workspace().id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, base: base, type: type, id: id}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.type};#{c.id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  test "the edit pane is the document pane, named doc:<id>, with .chip pills", c do
    view = open(c)
    pane = ~s([data-pane-editing][data-testid="document-pane"][data-pane="doc:#{c.id}"])

    assert has_element?(view, pane)
    assert has_element?(view, ~s(#{pane} .pane-header .chip.dk-chip), "Published")
    assert has_element?(view, ~s(#{pane} .pane-header .chip.dk-chip), "Draft")
  end

  test "a document pane that only reads carries the same names; the types pane keeps its own",
       c do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.type};#{c.id}|,")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)

    reads = ~s|[data-pane-kind="doc"]:not([data-pane-editing])|

    assert eventually(fn -> has_element?(view, ~s(#{reads} .pane-header .chip)) end)
    assert has_element?(view, ~s(#{reads}[data-testid="document-pane"][data-pane="doc:#{c.id}"]))
    assert has_element?(view, ~s|[data-pane-kind="types"][data-pane="types"]:not([data-testid])|)
    refute has_element?(view, ~s([data-pane-kind="list"][data-pane]))
  end

  test "the inspector's holder is beside the form, hidden and empty", c do
    view = open(c)
    holder = ~s([data-pane-editing] .pane-body > aside[data-desk-inspector][hidden])

    assert has_element?(view, holder)
    assert view |> element(holder) |> render() =~ ~r{<aside[^>]*>\s*</aside>}
    refute view |> element(holder) |> render() =~ "data-inspect"
  end

  test "the holder says which inspector the URL asks for; Inspect (inspect=on) is not one", c do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.type};#{c.id},inspect=history")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)

    assert has_element?(
             view,
             ~s([data-pane-editing] aside[data-desk-inspector][data-inspect="history"][hidden])
           )

    render_patch(view, "#{c.base}/#{c.type};#{c.id},inspect=on")
    render_async(view, 5_000)

    assert has_element?(
             view,
             ~s|[data-pane-editing] aside[data-desk-inspector][hidden]:not([data-inspect])|
           )
  end
end
