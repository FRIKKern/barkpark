defmodule BarkparkWeb.Studio.DeskEditorDbDownTest do
  @moduledoc """
  J50, the editor's side: the database is out when a document is opened on
  the desk. The Studio's read of it (`EditorHost.edit/2`, in the page
  process) used to raise there and take the whole page down. Now the edit
  pane says it could not be read, the other panes stay, and its Retry opens
  the editor once the database is back.

  Seen in a browser first: tmp/live-w2/J50-backend-down.log (the socket
  closed, every pane went with it). The outage is the documents table
  renamed inside the test's transaction, as in that run.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "db_down_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Db down #{n}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "dd-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Outage"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    raw = "desk-db-down-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-db-down", @dataset, ["read", "write", "admin"], ws.id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, view, _html} = live(conn, "#{base}/#{type}")
    render_async(view, 5_000)

    {:ok, view: view, base: base, type: type, id: id}
  end

  # Poll for a value the view reaches after a message, never right after a send.
  defp eventually(fun) do
    Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)
  end

  defp outage!, do: Repo.query!("ALTER TABLE documents RENAME TO documents_out")
  defp restore!, do: Repo.query!("ALTER TABLE documents_out RENAME TO documents")

  test "a document opened while the database is out does not take the page down", ctx do
    outage!()
    render_patch(ctx.view, "#{ctx.base}/#{ctx.type};#{ctx.id}")

    card = "section[data-pane-editing] [data-desk-edit-failed]"
    assert eventually(fn -> Process.alive?(ctx.view.pid) and has_element?(ctx.view, card) end)
    assert has_element?(ctx.view, card, "This document could not be read.")
    # The list it was opened from is still on the desk.
    assert has_element?(ctx.view, "#desk-panes section[data-pane-index='0']")
    refute has_element?(ctx.view, "[data-pane-editing] #editor-form")

    restore!()
    ctx.view |> element("#{card} button", "Retry") |> render_click()

    assert eventually(fn -> has_element?(ctx.view, "[data-pane-editing] #editor-form") end)
    refute has_element?(ctx.view, card)
  end

  test "a Retry while the database is still out shows the card again", ctx do
    outage!()
    render_patch(ctx.view, "#{ctx.base}/#{ctx.type};#{ctx.id}")

    card = "section[data-pane-editing] [data-desk-edit-failed]"
    assert eventually(fn -> has_element?(ctx.view, card) end)

    ctx.view |> element("#{card} button", "Retry") |> render_click()
    render(ctx.view)
    assert Process.alive?(ctx.view.pid)
    assert eventually(fn -> has_element?(ctx.view, card) end)
  end
end
