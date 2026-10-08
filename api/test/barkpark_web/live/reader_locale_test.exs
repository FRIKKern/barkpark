defmodule BarkparkWeb.ReaderLocaleTest do
  @moduledoc """
  task-c84978a632220e1c: the public paper and sheet readers declared
  `<html lang="en">` and English chrome whatever the workspace wrote in, so a
  screen reader spoke a Norwegian paper with an English voice. The page now
  takes the language of the workspace that owns the document (lead ruling (a):
  the workspace's Studio language, no per-document field).

  `async: false` — one test flips the Default workspace's locale and restores it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Tenancy}
  alias Barkpark.Sharing.Links

  @dataset "production"

  defp scoped_paper!(locale) do
    ws = create_workspace!()
    proj = create_project!(ws)
    {:ok, ws} = Tenancy.set_workspace_locale(ws, locale)
    slug = "reader-loc-#{System.unique_integer([:positive])}"

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => "Etiketter",
          "blocks" => [
            %{
              "id" => "b1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Norsk brødtekst"}]
            }
          ],
          "workspace_id" => ws.id,
          "project_id" => proj.id
        })
      )

    {:ok, {raw, _link}} =
      Links.create(%{
        workspace_id: ws.id,
        project_id: proj.id,
        dataset: @dataset,
        kind: "doc",
        ref_type: "paper",
        ref_id: slug,
        access: "read"
      })

    "/w/#{ws.slug}/p/#{proj.slug}/papers/#{slug}?share=#{raw}"
  end

  defp with_default_locale(locale, fun) do
    {default_ws, _proj} = ensure_default_scope!()
    before = Tenancy.workspace_locale(default_ws)
    {:ok, _} = Tenancy.set_workspace_locale(default_ws, locale)

    try do
      fun.()
    after
      {:ok, _} = Tenancy.set_workspace_locale(Tenancy.get_workspace_by_id(default_ws.id), before)
    end
  end

  defp public_sheet! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sheet",
          "title" => "Sheets",
          "visibility" => "private",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    slug = "reader-loc-sheet-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => slug,
          "content" => %{"tabs" => [%{"name" => "Data", "cells" => %{"A1" => %{"v" => 1}}}]}
        },
        @dataset
      )

    {:ok, _} = Content.publish_document(slug, "sheet", @dataset)
    slug
  end

  test "a paper in an nb-NO workspace reads as Norwegian, page language and chrome", %{
    conn: conn
  } do
    path = scoped_paper!("nb-NO")
    html = conn |> get(path) |> html_response(200)

    assert html =~ ~s(<html lang="nb-NO")
    assert html =~ "Norsk brødtekst"
    assert html =~ ~s(<span class="bp-vt-label">E-postvisning</span>)
    assert html =~ ~s(aria-label="Lukk forstørret bilde")
    assert html =~ ~s(aria-label="Visningsvalg for artikkelen")
    # The strings the reader's scripts set at runtime ride on <body>.
    assert html =~ ~s(data-bp-t-light-mode="Lys modus")
    assert html =~ ~s(data-bp-t-go-to="Gå til %{title}")
    refute html =~ "Toggle email view"
    refute html =~ ~s(<html lang="en")

    # The connected LiveView process speaks it too (its later renders, flashes
    # and replies), not only the dead render's layout.
    {:ok, view, _html} = live(conn, path)
    {:dictionary, dict} = Process.info(view.pid, :dictionary)
    assert Enum.any?(dict, fn {_k, v} -> v == "nb_NO" end)
  end

  test "a Default-workspace paper on the flat reader stays English", %{conn: conn} do
    slug = "reader-loc-flat-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          body_html: ~s(<section id="block-1"><h1>Flat probe</h1></section>),
          event_type: "plan-written"
        })
      )

    html = conn |> get("/papers/#{slug}") |> html_response(200)

    assert html =~ ~s(<html lang="en")
    assert html =~ ~s(<span class="bp-vt-label">Email view</span>)
    assert html =~ ~s(aria-label="Close enlarged image")
    assert html =~ ~s(data-bp-t-light-mode="Light mode")
    refute html =~ "E-postvisning"
  end

  test "the public sheet reader takes the owning workspace's language", %{conn: conn} do
    slug = public_sheet!()

    en = conn |> get("/sheets/#{slug}") |> html_response(200)
    assert en =~ ~s(<html lang="en")

    with_default_locale("nb-NO", fn ->
      nb = scoped_conn() |> get("/sheets/#{slug}") |> html_response(200)
      assert nb =~ ~s(<html lang="nb-NO")
      refute nb =~ ~s(<html lang="en")
    end)
  end
end
