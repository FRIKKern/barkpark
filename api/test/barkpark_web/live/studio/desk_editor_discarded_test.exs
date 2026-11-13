defmodule BarkparkWeb.Studio.DeskEditorDiscardedTest do
  @moduledoc """
  live.spec:48, the editor's side: someone else discards the draft of the
  document open in the desk's editor, and the published version stays.
  Before, the discard's frame carries the draft it removed, the Studio's
  `doc_updated` put it in the form as the new state, and the next keystroke
  wrote the dead draft back. Now the form reloads to the published version,
  says so, and a save the browser sent from the old form is dropped. The
  browser tells the page when it has the new form (`desk-discard-seen`,
  `bp-desk.js`); a save after that writes as usual.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @form "[data-pane-editing] #editor-form"
  @note "[data-pane-editing] [data-desk-discarded]"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "discard_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Discard #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "discard-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Here", "excerpt" => "Published words"},
        @dataset
      )

    {:ok, _} = Content.publish_document(id, type, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    raw = "desk-discard-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-discard", @dataset, ["read", "write", "admin"], ws.id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    path = "#{base}/#{type};#{id}"
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)

    {:ok, view: view, type: type, id: id, path: path, conn: conn}
  end

  defp eventually(fun) do
    Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)
  end

  defp title_shown(view, value),
    do: has_element?(view, ~s(#{@form} input[name="doc[title]"][value="#{value}"]))

  # What the store holds: {doc, draft?}.
  defp stored(ctx) do
    {doc, draft?, _published?} = Content.fetch_doc_with_draft(ctx.type, ctx.id, @dataset)
    {doc && doc.title, draft?}
  end

  # Someone else writes a draft over the published version, then discards it.
  defp draft_elsewhere(ctx, title) do
    {:ok, _} =
      Content.upsert_document(
        ctx.type,
        %{"doc_id" => "drafts." <> ctx.id, "title" => title, "excerpt" => "Draft words"},
        @dataset
      )
  end

  defp discard_elsewhere(ctx), do: {:ok, _} = Content.discard_draft(ctx.id, ctx.type, @dataset)

  test "a draft discarded elsewhere: the open form shows the published version and says so",
       ctx do
    draft_elsewhere(ctx, "Here elsewhere")
    assert eventually(fn -> title_shown(ctx.view, "Here elsewhere") end)

    discard_elsewhere(ctx)

    assert eventually(fn -> title_shown(ctx.view, "Here") end),
           "the form kept the discarded draft: #{inspect(ctx.view |> element(@form) |> render() |> String.slice(0, 600))}"

    assert has_element?(ctx.view, @note, "discarded")
    assert stored(ctx) == {"Here", false}
  end

  test "a save the browser sent from the old form is dropped: no draft comes back", ctx do
    draft_elsewhere(ctx, "Here elsewhere")
    assert eventually(fn -> title_shown(ctx.view, "Here elsewhere") end)
    # A types in the old form, then the discard lands before the browser has the new one.
    render_hook(ctx.view, "autosave", %{"doc" => %{"title" => "Here elsewhere!"}})
    discard_elsewhere(ctx)
    assert eventually(fn -> has_element?(ctx.view, @note) end)

    render_hook(ctx.view, "autosave", %{
      "doc" => %{"title" => "Here elsewhere!!", "excerpt" => "Draft words"}
    })

    render_hook(ctx.view, "save", %{"doc" => %{"title" => "Here elsewhere!!!"}})
    render(ctx.view)

    assert stored(ctx) == {"Here", false}
    assert title_shown(ctx.view, "Here")
    # Not silent: the pane says the typing was not saved.
    assert has_element?(ctx.view, @note, "was not saved")
  end

  test "a discard with nothing typed after it: the line does not claim lost typing", ctx do
    draft_elsewhere(ctx, "Here elsewhere")
    assert eventually(fn -> title_shown(ctx.view, "Here elsewhere") end)
    discard_elsewhere(ctx)
    assert eventually(fn -> has_element?(ctx.view, @note) end)
    refute has_element?(ctx.view, @note, "was not saved")
  end

  # Keys typed in the focused field and not yet sent (its debounce) never
  # reach the page as a save. The browser finds them: the event carries the
  # old form's values (`was`), and the focused field no longer matching them
  # is typing the discard took. It answers `lost: true`, and the line says so
  # (guerrilla, 2026-11-13: six keys typed across a discard vanished without
  # a word, 3 of 3).
  test "the event carries the old form's values, for the browser to find unsent keys", ctx do
    draft_elsewhere(ctx, "Here elsewhere")
    assert eventually(fn -> title_shown(ctx.view, "Here elsewhere") end)
    discard_elsewhere(ctx)

    assert_push_event(ctx.view, "desk:discarded", %{values: values, was: was}, 2_000)
    assert values["doc[title]"] == "Here"
    assert was["doc[title]"] == "Here elsewhere"
    assert was["doc[excerpt]"] == "Draft words"
  end

  test "the browser lost unsent keys: the line says the typing was not saved", ctx do
    draft_elsewhere(ctx, "Here elsewhere")
    assert eventually(fn -> title_shown(ctx.view, "Here elsewhere") end)
    discard_elsewhere(ctx)
    assert eventually(fn -> has_element?(ctx.view, @note) end)

    render_hook(ctx.view, "desk-discard-seen", %{"lost" => true})

    assert has_element?(ctx.view, @note, "was not saved")
    # The browser has the new form: its saves write again.
    render_hook(ctx.view, "save", %{"doc" => %{"title" => "Here, again"}})
    assert eventually(fn -> stored(ctx) == {"Here, again", true} end)
  end

  test "control: the browser lost nothing, the line stays plain", ctx do
    draft_elsewhere(ctx, "Here elsewhere")
    assert eventually(fn -> title_shown(ctx.view, "Here elsewhere") end)
    discard_elsewhere(ctx)
    assert eventually(fn -> has_element?(ctx.view, @note) end)

    render_hook(ctx.view, "desk-discard-seen", %{})
    assert has_element?(ctx.view, @note, "discarded")
    refute has_element?(ctx.view, @note, "was not saved")
  end

  # A browser that never answered `desk:discarded` is not stuck: a reconnect
  # mounts a new LiveView process, whose assigns have no `desk_discarded`.
  test "a reconnect starts clean: the new page's saves write", %{conn: conn} = ctx do
    draft_elsewhere(ctx, "Here elsewhere")
    assert eventually(fn -> title_shown(ctx.view, "Here elsewhere") end)
    discard_elsewhere(ctx)
    assert eventually(fn -> has_element?(ctx.view, @note) end)

    {:ok, again, _html} = live(conn, ctx.path)
    render_async(again, 5_000)
    assert eventually(fn -> has_element?(again, @form) end)
    refute has_element?(again, @note)

    render_hook(again, "autosave", %{"doc" => %{"title" => "Here, after the reconnect"}})
    assert eventually(fn -> stored(ctx) == {"Here, after the reconnect", true} end)
  end

  test "once the browser has the new form, a save writes as usual", ctx do
    draft_elsewhere(ctx, "Here elsewhere")
    assert eventually(fn -> title_shown(ctx.view, "Here elsewhere") end)
    discard_elsewhere(ctx)
    assert eventually(fn -> has_element?(ctx.view, @note) end)

    render_hook(ctx.view, "desk-discard-seen", %{})
    render_hook(ctx.view, "autosave", %{"doc" => %{"title" => "Here, typed after"}})

    assert eventually(fn -> stored(ctx) == {"Here, typed after", true} end)
  end

  # The mirror: the published version changes under a form nobody touched. It
  # shows, and nothing is dropped or announced.
  test "control: a published version changed elsewhere shows in a clean form", ctx do
    {:ok, _} =
      Content.upsert_document(
        ctx.type,
        %{"doc_id" => "drafts." <> ctx.id, "title" => "Here, new"},
        @dataset
      )

    {:ok, _} = Content.publish_document(ctx.id, ctx.type, @dataset)
    assert eventually(fn -> title_shown(ctx.view, "Here, new") end)
    refute has_element?(ctx.view, @note)

    render_hook(ctx.view, "autosave", %{"doc" => %{"title" => "Here, newer"}})
    assert eventually(fn -> stored(ctx) == {"Here, newer", true} end)
  end
end
