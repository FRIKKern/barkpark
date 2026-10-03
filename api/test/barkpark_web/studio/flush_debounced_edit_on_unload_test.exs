defmodule BarkparkWeb.Studio.FlushDebouncedEditOnUnloadTest do
  @moduledoc """
  task-63aed3de024fc151 — the last keystrokes typed into a Classic field must
  survive a reload, Back, a typed URL or a closed tab.

  THE DEFECT. Classic inputs post `phx-change="autosave"` behind a
  `phx-debounce` of 300–500 ms, and LiveView flushes a debounce only on blur.
  A click inside the page blurs first, so in-app navigation kept the edit; a
  page leave that never blurs (reload, Back, a typed URL, Cmd+W) dropped
  whatever was typed in the last half-second. Found in headless Chrome: type
  into a post's Excerpt, navigate at once — the draft never received it.

  HOW THIS IS PINNED. The flush is client JS that `mix test` cannot run, so the
  test pins both halves it depends on: the served page carries a
  `beforeunload` listener that blurs the focused control of a `phx-change`
  form, and the Classic editor's form and fields are exactly that shape (a
  `phx-change` form whose text controls are debounced). The headless-Chrome
  reproduction is recorded on the task.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "note",
          "title" => "Note",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "text"}
          ]
        },
        @dataset
      )

    {:ok, _} = Content.create_document("note", %{"doc_id" => "n1", "title" => "N"}, @dataset)
    :ok
  end

  test "the served Studio page blurs a focused phx-change control on beforeunload", %{conn: conn} do
    html = conn |> get(scoped_studio("/d/#{@dataset}/studio/note/n1")) |> html_response(200)

    found = Regex.run(~r/addEventListener\("beforeunload",[^}]*\}\);/s, html)

    assert match?([_], found),
           "the page must register a beforeunload listener that flushes the focused field"

    [listener] = found
    assert listener =~ "document.activeElement"
    assert listener =~ ~s|hasAttribute("phx-change")|
    assert listener =~ "blur()"
  end

  test "the Classic editor is the debounced phx-change form the listener targets", %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/note/n1"))

    assert html =~ ~r/<form[^>]*phx-change="autosave"[^>]*id="editor-form"/
    assert html =~ ~r/<textarea[^>]*name="doc\[excerpt\]"[^>]*phx-debounce="\d+"/
  end
end
