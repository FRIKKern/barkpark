defmodule BarkparkWeb.Studio.DeskJustSavedTest do
  @moduledoc """
  J04, as the TanStack Studio's (`DocumentPane.tsx` `justSaved`): the desk
  footer says "Saved" for about 3 s after this editor's own save lands, then
  "Edited N ago" (`Desk.JustSaved`, `DocFooter.status/2`). A change from
  another editor says "Edited", never "Saved". live-edit.spec.ts waits for
  "Saved" in both browsers before its reset.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.DocFooter
  alias BarkparkWeb.Studio.Desk.JustSaved

  @dataset "production"
  @status ~s([data-pane-editing] .dk-edit-footer [data-desk-footer-status] .save-state-text)

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "js_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Saved #{type}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "js-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Here"}, @dataset)
    {:ok, _} = Content.publish_document(id, type, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-saved-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "desk-saved",
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

  defp type(view, title) do
    view |> element("#editor-form") |> render_change(%{"doc" => %{"title" => title}})
    render_async(view, 5_000)
  end

  defp eventually(fun), do: Enum.any?(1..300, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp status(view), do: view |> element(@status) |> render() |> strip()
  defp strip(html), do: html |> String.replace(~r/<[^>]+>/, "") |> String.trim()

  # The mark the view holds (its timer's ref).
  defp mark(view), do: :sys.get_state(view.pid).socket.assigns[:desk_just_saved]

  test "an own save says Saved; when its window is over, Edited just now", c do
    view = open(c)
    assert status(view) == "Last published just now"

    type(view, "Typed")
    assert eventually(fn -> status(view) == "Saved" end), status(view)

    # The window's end, as its timer sends it. An older timer's end leaves a
    # newer save's "Saved" as it is.
    {ref, _id} = mark(view)
    send(view.pid, {:desk_saved_over, make_ref()})
    assert status(view) == "Saved"

    send(view.pid, {:desk_saved_over, ref})
    assert eventually(fn -> status(view) == "Edited just now" end), status(view)

    # The next save says "Saved" again, with a timer of its own.
    type(view, "Typed again")
    assert eventually(fn -> status(view) == "Saved" end), status(view)
    assert {new_ref, _} = mark(view)
    refute new_ref == ref
  end

  test "the window ends by itself", c do
    Application.put_env(:barkpark, :desk_saved_ms, 150)
    on_exit(fn -> Application.delete_env(:barkpark, :desk_saved_ms) end)

    view = open(c)
    type(view, "Typed")
    assert eventually(fn -> status(view) == "Edited just now" end), status(view)
  end

  test "another editor's change says Edited, never Saved", c do
    a = open(c)
    b = open(c)

    type(a, "From A")
    assert eventually(fn -> status(a) == "Saved" end), status(a)
    assert eventually(fn -> status(b) == "Edited just now" end), status(b)
    assert mark(b) == nil
  end

  test "the words: Saved only for the open document's own mark" do
    now = ~U[2026-11-13 12:00:00Z]
    doc = %{doc_id: "drafts.p", updated_at: ~U[2026-11-13 10:00:00Z], status: "draft"}
    base = %{editor_doc: doc, editor_is_draft: true}

    assert DocFooter.status(Map.put(base, :desk_just_saved, {make_ref(), "p"}), now) == "Saved"

    assert DocFooter.status(Map.put(base, :desk_just_saved, {make_ref(), "q"}), now) ==
             "Edited 2h ago"

    assert DocFooter.status(base, now) == "Edited 2h ago"

    # A save that did not land says its own words.
    failed = Map.merge(base, %{desk_just_saved: {make_ref(), "p"}, save_status: "Save failed"})
    assert DocFooter.status(failed, now) == "Save failed"
    refute JustSaved.on?(%{desk_just_saved: nil, editor_doc: doc})
  end
end
