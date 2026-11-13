defmodule BarkparkWeb.Studio.DeskRowSubtitleTest do
  @moduledoc """
  LOOKS C4 (audit screens 2 and 11): a desk row's subtitle is the TanStack
  Studio's. A schema's `|date` subtitle prints as the day in the workspace's
  zone and format (06.09.2026, `BarkparkWeb.PreviewDay`), never the raw ISO
  instant. A type whose list preview names no subtitle shows the title alone,
  as TanStack's rows do, not the Studio's "Updated 6h ago".
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    dated = "dk_sub_dated_#{n}"
    plain = "dk_sub_plain_#{n}"

    for {type, preview} <- [{dated, %{"subtitle" => "publishedAt|date"}}, {plain, %{}}] do
      {:ok, _schema} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Subtitle notes",
            "visibility" => "public",
            "list_preview" => preview,
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{"name" => "publishedAt", "title" => "Published at", "type" => "datetime"}
            ]
          },
          @dataset
        )

      {:ok, _doc} =
        Content.create_document(
          type,
          %{
            "doc_id" => "#{type}-1",
            "title" => "Dated note",
            "publishedAt" => "2026-09-06T10:00:00Z"
          },
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: conn, base: base, dated: dated, plain: plain}
  end

  defp open(conn, path) do
    raw = "desk-row-subtitle-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-row-subtitle", @dataset, ~w(read write admin), ws.id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    view
  end

  defp row(type), do: ~s(section.pane.list a[data-desk-row][href$=";#{type}-1"])

  test "a |date subtitle is the day, as a <time> the browser puts in the workspace's zone",
       %{conn: conn, base: base, dated: type} do
    view = open(conn, "#{base}/#{type}")
    html = view |> element(row(type) <> " .dk-row-sub") |> render()

    assert html =~ ~s(<time datetime="2026-09-06T10:00:00Z" data-preview-day="">06.09.2026</time>)
    refute html =~ "\u{E000}", "the private-use marker is not printed"
  end

  test "a type with no subtitle shows the title alone, no \"Updated … ago\"",
       %{conn: conn, base: base, plain: type} do
    view = open(conn, "#{base}/#{type}")

    assert has_element?(view, row(type) <> " .dk-row-title", "Dated note")
    refute has_element?(view, row(type) <> " .dk-row-sub")
    refute render(element(view, row(type))) =~ ~r/Updated .* ago|Updated just now/
  end
end
