defmodule BarkparkWeb.Studio.StudioEditorPolishTest do
  # task-a69f860810cbcfc3: three small Studio frictions found dogfooding.
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BarkparkWeb.PaperEditorTestHelpers, only: [pin_paper_canvas!: 1, seed_paper_schema!: 0]
  alias Barkpark.Content

  @dataset "production"

  setup do
    pin_paper_canvas!("1")
    seed_paper_schema!()
    :ok
  end

  defp para(text),
    do: %{
      "id" => "p-1",
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => text}]
    }

  defp upsert_paper(slug, title, body) do
    title_block = %{
      "id" => "tpl-title",
      "type" => "heading",
      "level" => 1,
      "role" => "title",
      "locked" => true,
      "text" => title
    }

    Content.upsert_paper(
      Barkpark.LabelFixtures.paper_attrs(%{
        slug: slug,
        dataset: @dataset,
        title: title,
        blocks: [title_block | body]
      })
    )
  end

  defp open(conn, path), do: live(conn, scoped_studio("/d/#{@dataset}/studio/#{path}"))

  defp query(html, selector), do: html |> LazyHTML.from_document() |> LazyHTML.query(selector)

  defp standalone_hrefs(html),
    do: html |> query(~s([data-test-id="paper-open-standalone"])) |> LazyHTML.attribute("href")

  describe "Open standalone" do
    test "a never-published paper has no standalone link", %{conn: conn} do
      {:ok, _} =
        Content.create_document(
          "paper",
          %{"doc_id" => "paper-polish-draft", "content" => %{}},
          @dataset
        )

      {:ok, _view, html} = open(conn, "paper/paper-polish-draft")
      assert standalone_hrefs(html) == []
    end

    test "a draft whose paper is published links to the published id", %{conn: conn} do
      {:ok, _} = upsert_paper("paper-polish-pub", "Publisert", [para("Tekst")])

      {:ok, _} =
        Content.create_document(
          "paper",
          %{"doc_id" => "drafts.paper-polish-pub", "title" => "Utkast", "content" => %{}},
          @dataset
        )

      {:ok, _view, html} = open(conn, "paper/paper-polish-pub")
      assert [href] = standalone_hrefs(html)
      assert href =~ ~r{/papers/paper-polish-pub$}
    end
  end

  test "the paper footer pluralises its counts", %{conn: conn} do
    title_block = %{
      "id" => "tpl-title",
      "type" => "heading",
      "level" => 1,
      "role" => "title",
      "locked" => true,
      "text" => "Fjell"
    }

    {:ok, _} =
      Content.create_document(
        "paper",
        %{"doc_id" => "paper-polish-count", "content" => %{"blocks" => [title_block]}},
        @dataset
      )

    {:ok, _view, html} = open(conn, "paper/paper-polish-count")
    footer = html |> query(~s([data-test-id="bp-paper-footer"])) |> LazyHTML.text()

    assert footer =~ ~r/1 word(?!s)/
    refute footer =~ "1 words"
    assert footer =~ ~r/1 block(?!s)/
  end

  test "Duplicate names the copy by its title", %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "polishdup",
          "title" => "Dup",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "polishdup",
        %{"doc_id" => "polishdup-1", "title" => "Fjellet", "content" => %{"title" => "Fjellet"}},
        @dataset
      )

    {:ok, view, _} = open(conn, "polishdup/polishdup-1")
    view |> element(~s(button[phx-click="duplicate-doc"])) |> render_click()
    assert render(view) =~ "Duplicated as “Fjellet (copy)”"
  end

  # task-141c0bba8070ef02: the copy suffix is STORED in the title, so an
  # English " (copy)" read English in every surface of a Norwegian Studio.
  test "a Norwegian Studio stores the copy with its own suffix; an untitled source stays untitled",
       %{conn: conn} do
    {:ok, _} =
      Barkpark.Tenancy.set_workspace_locale(Barkpark.Tenancy.get_default_workspace(), "nb-NO")

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "polishdupnb",
          "title" => "Dup",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "polishdupnb",
        %{
          "doc_id" => "polishdupnb-1",
          "title" => "Fjellet",
          "content" => %{"title" => "Fjellet"}
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "polishdupnb",
        %{"doc_id" => "polishdupnb-2", "content" => %{}},
        @dataset
      )

    {:ok, view, _} = open(conn, "polishdupnb/polishdupnb-1")
    view |> element(~s(button[phx-click="duplicate-doc"])) |> render_click()
    assert render(view) =~ "Duplisert som «Fjellet (kopi)»"

    titles = fn ->
      Content.list_documents("polishdupnb", @dataset, perspective: :drafts)
      |> Enum.map(& &1.title)
    end

    assert "Fjellet (kopi)" in titles.()
    refute Enum.any?(titles.(), &(&1 && &1 =~ "(copy)"))

    before = length(titles.())
    {:ok, view2, _} = open(conn, "polishdupnb/polishdupnb-2")
    view2 |> element(~s(button[phx-click="duplicate-doc"])) |> render_click()
    assert length(titles.()) == before + 1, "the untitled source was duplicated"
    refute Enum.any?(titles.(), &(&1 && &1 =~ "Untitled"))
  end
end
