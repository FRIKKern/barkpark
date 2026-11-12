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

    {:ok, view, _html} = live(conn, "#{base}/#{type};#{id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)

    {:ok, view: view, type: type, id: id}
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
