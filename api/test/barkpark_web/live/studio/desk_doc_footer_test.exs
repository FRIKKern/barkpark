defmodule BarkparkWeb.Studio.DeskDocFooterTest do
  @moduledoc """
  LOOKS PR 3, the edit pane's footer as the TanStack Studio draws it
  (`DocFooter`): "Last published …" or "Edited …" on the left, a Publish
  button and the "…" on the right. Publish sends the Studio's own event.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.DocFooter

  @dataset "production"
  @footer ~s([data-pane-editing] .dk-edit-footer)
  @publish ~s(#{@footer} button.dk-publish[data-desk-publish])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "ft_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Footer #{type}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "ft-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Here"}, @dataset)
    {:ok, _} = Content.publish_document(id, type, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-footer-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "desk-footer",
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

  defp status(view),
    do: view |> element(~s(#{@footer} [data-desk-footer-status])) |> render() |> strip()

  defp strip(html), do: html |> String.replace(~r/<[^>]+>/, "") |> String.trim()

  test "a published document: Last published on the left, Publish greyed out, then the …", c do
    view = open(c)

    assert status(view) == "Last published just now"
    assert has_element?(view, ~s(#{@publish}[disabled]))

    html = view |> element(@footer) |> render()

    [publish_at, menu_at] =
      for s <- ["data-desk-publish", ~s(aria-label="Open document actions")],
          do: :binary.match(html, s) |> elem(0)

    assert publish_at < menu_at
  end

  test "an edit: Edited on the left, and Publish publishes it", c do
    view = open(c)

    view |> element("#editor-form") |> render_change(%{"doc" => %{"title" => "Typed"}})
    render_async(view, 5_000)

    assert eventually(fn -> status(view) == "Edited just now" end), status(view)
    refute has_element?(view, ~s(#{@publish}[disabled]))

    view |> element(@publish) |> render_click()

    assert eventually(fn ->
             match?({:error, _}, Content.get_document("drafts." <> c.id, c.type, @dataset))
           end),
           "the draft is still there"

    assert {:ok, %{title: "Typed"}} = Content.get_document(c.id, c.type, @dataset)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, ~s(#{@publish}[disabled])) end)
  end

  test "the words: time since, or the save's own words when it did not land" do
    now = ~U[2026-11-13 12:00:00Z]
    doc = %{updated_at: ~U[2026-11-13 10:00:00Z], status: "published"}

    assert DocFooter.status(%{editor_doc: doc}, now) == "Last published 2h ago"
    assert DocFooter.status(%{editor_doc: doc, editor_is_draft: true}, now) == "Edited 2h ago"
    assert DocFooter.status(%{editor_doc: doc, save_status: "Save failed"}, now) == "Save failed"
    assert DocFooter.status(%{editor_doc: %{doc | status: "draft"}}, now) == ""
  end

  # Control: the old Studio has no such footer.
  test "the old Studio has no Publish footer", c do
    {:ok, _view, html} =
      live(c.conn, String.replace(c.base, "/_desk", "") <> "/#{c.type}/#{c.id}")

    assert html =~ ~s(id="editor-form")
    refute html =~ "dk-publish"
  end
end
