defmodule BarkparkWeb.Studio.DeskListPreviewTest do
  @moduledoc """
  J56, the list-row part (barkpark-studio JOURNEYS.md): a desk list row shows
  its preview as the schema's `list_preview` selects and prepares it (a
  referenced title as subtitle, a formatted date, a fallback when empty), and
  its status mark says, as Sanity's tooltip does, "Published {ago}" or "Not
  published", then "Edited {ago}" or "No unpublished edits".

  Reference values, array item rows and the header chips are the editing
  lane's, not tested here.

  The status mark is `[data-desk-status]` inside the row; its `title` holds
  the tooltip text.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_list_pv_book"
  @person "desk_list_pv_person"

  # An "ago" is matched by its hours: Barkpark's "3h ago" or Sanity's "3 hr. ago".
  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @person,
          "title" => "People",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Name", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Books",
          "visibility" => "public",
          "list_preview" => %{
            "subtitle" => %{
              "parts" => ["author.title", "releasedAt|date", "publishedOn|date"],
              "empty" => "No author yet"
            }
          },
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "author", "title" => "Author", "type" => "reference", "to" => [@person]},
            %{"name" => "publishedOn", "title" => "Published on", "type" => "date"},
            %{"name" => "releasedAt", "title" => "Released at", "type" => "datetime"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        @person,
        %{"doc_id" => "pv-ada", "title" => "Ada Lovelace"},
        @dataset
      )

    {:ok, _} = Content.publish_document("pv-ada", @person, @dataset)

    ref = %{"_ref" => "pv-ada", "_type" => "reference"}

    # pv-pub: published only. pv-draft: never published. pv-both: published,
    # then edited (a newer draft). pv-blank: no title, no author.
    book("pv-pub", "Engines of Thought", %{
      "author" => ref,
      "releasedAt" => "2024-03-05T23:30:00Z"
    })

    book("pv-draft", "Binary Tales", %{"author" => ref, "publishedOn" => "2023-11-20"})
    book("pv-both", "Cipher Days", %{"author" => ref})
    book("pv-blank", "", %{})

    for id <- ~w(pv-pub pv-both pv-blank),
        do: {:ok, _} = Content.publish_document(id, @type_name, @dataset)

    {:ok, _} =
      Content.upsert_document(
        @type_name,
        %{
          "doc_id" => "drafts.pv-both",
          "title" => "Cipher Days",
          "content" => %{"author" => ref}
        },
        @dataset
      )

    # Aged, so an "ago" can only come from the stored times.
    age("pv-pub", 3)
    age("pv-draft", 5)
    age("pv-both", 6)
    age("drafts.pv-both", 2)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    {:ok, conn: admin(conn), base: base}
  end

  defp book(id, title, content) do
    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"doc_id" => id, "title" => title, "content" => content},
        @dataset
      )
  end

  defp age(doc_id, hours) do
    at = DateTime.add(DateTime.utc_now(), -hours * 3_600, :second)
    Repo.query!("UPDATE documents SET updated_at = $1 WHERE doc_id = $2", [at, doc_id])
  end

  defp admin(conn) do
    raw = "desk-list-preview-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-list-preview", @dataset, ~w(read write admin), ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp open_list(conn, base) do
    {:ok, view, _html} = live(conn, "#{base}/#{@type_name}")
    render_async(view, 5_000)
    view
  end

  defp row(id), do: ~s([data-pane-kind="list"] a[data-desk-row][href$=";#{id}"])

  defp row_text(view, id) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(row(id))
    |> LazyHTML.text()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp status_tip(view, id) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(row(id) <> " [data-desk-status]")
    |> LazyHTML.attribute("title")
    |> Enum.join(" | ")
  end

  test "a row's subtitle is the referenced document's title", %{conn: conn, base: base} do
    view = open_list(conn, base)
    assert row_text(view, "pv-pub") =~ "Engines of Thought"
    assert row_text(view, "pv-pub") =~ "Ada Lovelace", "row text: #{row_text(view, "pv-pub")}"
  end

  test "a date in the subtitle shows as a formatted day", %{conn: conn, base: base} do
    view = open_list(conn, base)
    assert row_text(view, "pv-draft") =~ "20.11.2023", "row text: #{row_text(view, "pv-draft")}"
  end

  test "a date-time in the subtitle shows as its day, never a raw timestamp", %{
    conn: conn,
    base: base
  } do
    view = open_list(conn, base)
    text = row_text(view, "pv-pub")

    refute text =~ "2024-03-05T23:30", "the row shows a raw timestamp: #{inspect(text)}"
    refute text =~ "\u{E000}", "the row shows a date marker: #{inspect(text)}"
    # The UTC day, which the browser turns into the workspace zone's day.
    assert has_element?(view, row("pv-pub") <> " time[datetime]", "05.03.2024")
  end

  test "a row with no title says Untitled", %{conn: conn, base: base} do
    view = open_list(conn, base)
    assert row_text(view, "pv-blank") =~ "Untitled", "row text: #{row_text(view, "pv-blank")}"
  end

  test "a row whose subtitle has nothing to show shows the declared fallback", %{
    conn: conn,
    base: base
  } do
    view = open_list(conn, base)

    assert row_text(view, "pv-blank") =~ "No author yet",
           "row text: #{row_text(view, "pv-blank")}"
  end

  test "a published row's status says when it was published and that it has no unpublished edits",
       %{conn: conn, base: base} do
    view = open_list(conn, base)
    tip = status_tip(view, "pv-pub")
    assert tip =~ ~r/Published 3\s?h/, "status tooltip: #{inspect(tip)}"
    assert tip =~ "No unpublished edits", "status tooltip: #{inspect(tip)}"
  end

  test "a never-published row's status says Not published and when it was edited", %{
    conn: conn,
    base: base
  } do
    view = open_list(conn, base)
    tip = status_tip(view, "pv-draft")
    assert tip =~ "Not published", "status tooltip: #{inspect(tip)}"
    assert tip =~ ~r/Edited 5\s?h/, "status tooltip: #{inspect(tip)}"
  end

  test "a published row with newer edits says both when it was published and when edited", %{
    conn: conn,
    base: base
  } do
    view = open_list(conn, base)
    tip = status_tip(view, "pv-both")
    # The published version's time and the draft's, each its own.
    assert tip =~ ~r/Published 6\s?h/, "status tooltip: #{inspect(tip)}"
    assert tip =~ ~r/Edited 2\s?h/, "status tooltip: #{inspect(tip)}"
    refute tip =~ "Not published", "status tooltip: #{inspect(tip)}"
  end
end
