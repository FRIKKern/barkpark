defmodule BarkparkWeb.Studio.DeskLiveUpdatesOfflineTypingTest do
  @moduledoc """
  J20 (JOURNEYS.md): ten seconds offline while typing in the desk's editor
  pane, then back: nothing typed is lost.

  While the socket is down, LiveView's client drops every `phx-change` push
  ("no connection"); the keystrokes stay only in the browser's form. When the
  socket comes back, the LiveView mounts again and the only way those
  keystrokes reach the server is LiveView's form recovery: on the rejoin the
  client re-sends each `form[phx-change]` that (a) is in the FIRST render of
  the rejoin, matched by id, and (b) is not marked `phx-auto-recover="ignore"`.

  These tests pin the server half of that contract. The browser half (the
  keystrokes are re-sent and land) is a Playwright drive:
  `$ORCH/tmp/live-w2/offline.mjs`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_offline_note"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk offline notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "don-#{System.unique_integer([:positive])}"

    {:ok, _doc} =
      Content.create_document(
        @type_name,
        %{"doc_id" => id, "title" => "Offline note", "content" => %{"summary" => "As saved"}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    raw = "desk-offline-token-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "desk-offline", @dataset, ~w(read write admin), ws.id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, url: "#{base}/#{@type_name};#{id}", id: id}
  end

  defp settle(view), do: render_async(view, 5_000)

  # The <form id="editor-form" ...> start tag in a render, or nil.
  defp editor_form_tag(html) do
    case Regex.run(~r/<form\b[^>]*\bid="editor-form"[^>]*>/, html) do
      [tag] -> tag
      _ -> nil
    end
  end

  test "the first answer to a (re)join already carries the document's editor form", %{
    conn: conn,
    url: url
  } do
    # `live/2`'s html is the join reply: what a reconnecting browser compares
    # its own forms against. A form that only arrives in a later diff is
    # never recovered, so what was typed offline is dropped.
    {:ok, _view, join_html} = live(conn, url)

    assert is_binary(editor_form_tag(join_html)),
           "the join render of a desk URL that ends in a document has no #editor-form: " <>
             "the editor is sent a message later (DeskLive.handle_params -> {:desk_edit, target}), " <>
             "so LiveView's rejoin recovery finds no form to hand the typed text back to"
  end

  test "the editor form is one LiveView's client recovers on a rejoin", %{conn: conn, url: url} do
    {:ok, view, _html} = live(conn, url)
    settle(view)

    tag = editor_form_tag(render(view))
    assert is_binary(tag), "the desk never drew the editor form"

    refute tag =~ ~s(phx-auto-recover="ignore"),
           "#editor-form opts out of rejoin recovery, so keystrokes typed while the socket was " <>
             "down are never re-sent: #{tag}"
  end

  test "a rejoin that hands back the untouched form makes no draft", %{
    conn: conn,
    url: url,
    id: id
  } do
    # The reason the form opted out of recovery (Gyldendal friction 65/66):
    # a rejoin re-posting an UNTOUCHED editor wrote a draft nobody typed.
    # Whatever brings recovery back must keep this true.
    {:ok, view, _html} = live(conn, url)
    settle(view)

    view
    |> form("#editor-form")
    |> render_change(%{"doc" => %{"title" => "Offline note", "summary" => "As saved"}})

    {_doc, draft?, _published?} = Content.fetch_doc_with_draft(@type_name, id, @dataset)
    assert draft? == false, "re-sending the stored values wrote a draft"

    # And a value typed while offline does land once it is re-sent.
    view
    |> form("#editor-form")
    |> render_change(%{"doc" => %{"title" => "Offline note", "summary" => "Typed offline"}})

    {doc, draft?, _published?} = Content.fetch_doc_with_draft(@type_name, id, @dataset)
    assert draft? == true
    assert doc.content["summary"] == "Typed offline"
  end
end
