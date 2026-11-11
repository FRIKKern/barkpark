defmodule BarkparkWeb.Studio.DeskEditorGoneTest do
  @moduledoc """
  J32, the editor's side: someone else deletes the document open in the
  desk's editor. Before, the form stayed, and the next keystroke's autosave
  wrote the document back as a draft (the page said "Saved"; found by a
  probe 2026-11-11). Now the edit pane says it was deleted, keeps no form,
  and a save still in flight is dropped.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "gone_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Gone #{n}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "gone-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Here"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    raw = "desk-gone-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-gone", @dataset, ["read", "write", "admin"], ws.id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, view, _html} = live(conn, "#{base}/#{type};#{id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)

    {:ok, view: view, type: type, id: id}
  end

  # Poll for a value the view reaches after a message, never right after a send.
  defp eventually(fun) do
    Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)
  end

  defp stored(ctx) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(ctx.type, ctx.id, @dataset)
    doc
  end

  defp delete_elsewhere(ctx) do
    {:ok, _} = Content.delete_document(ctx.id, ctx.type, @dataset)

    send(
      ctx.view.pid,
      {:document_changed, %{type: ctx.type, doc_id: ctx.id, mutation: "delete"}}
    )
  end

  test "the open document deleted elsewhere: the edit pane says so and keeps no form", ctx do
    delete_elsewhere(ctx)

    assert eventually(fn ->
             has_element?(ctx.view, "[data-pane-editing] [data-desk-edit-gone]", "deleted")
           end)

    refute has_element?(ctx.view, "[data-pane-editing] #editor-form")
  end

  test "a save in flight after the delete does not write the document back", ctx do
    delete_elsewhere(ctx)
    assert eventually(fn -> has_element?(ctx.view, "[data-desk-edit-gone]") end)

    render_hook(ctx.view, "autosave", %{"doc" => %{"title" => "Typed after delete"}})
    render_hook(ctx.view, "save", %{"doc" => %{"title" => "Saved after delete"}})
    render(ctx.view)

    assert stored(ctx) == nil, "the deleted document was written back: #{inspect(stored(ctx))}"
  end

  # Control: the same event on a document that is still there writes, so the
  # test above is not green because the event never reached the editor.
  test "control: the same autosave on a document still there writes it", ctx do
    render_hook(ctx.view, "autosave", %{"doc" => %{"title" => "Typed while here"}})
    assert eventually(fn -> stored(ctx) && stored(ctx).title == "Typed while here" end)
  end
end
