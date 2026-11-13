defmodule BarkparkWeb.Studio.DeskReadOnlyFormTest do
  @moduledoc """
  A document pane that is not the last one is read-only. The TanStack Studio
  draws it as its form, and so does the desk: the Published / Draft pills in
  the header (no Status row), the type line and the big title, then each
  field's label over its value in a ringed box. The values stay a list of
  terms, so each is found by its label.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @pane ~s([data-pane-index="2"])
  @css BarkparkWeb.Studio.Desk.Style.sheet(%{}) |> rendered_to_string()

  # The declaration block of the rule whose selector list is exactly `selector`.
  defp rule(selector) do
    case Regex.run(~r/(?:^|[}\s])#{Regex.escape(selector)}\s*\{([^}]*)\}/, @css) do
      [_, body] -> body
      nil -> flunk("no rule for #{selector}")
    end
  end

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "ro_#{n}"
    target = "ro_t_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => target,
          "title" => "Writer #{n}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Name", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Story #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "text"},
            %{"name" => "author", "title" => "Author", "type" => "reference", "to" => [target]}
          ]
        },
        @dataset
      )

    author = "ro-a-#{n}"
    {:ok, _} = Content.create_document(target, %{"doc_id" => author, "title" => "Ada"}, @dataset)

    id = "ro-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "First story",
          "content" => %{
            "excerpt" => "Short.",
            "author" => %{"_ref" => author, "_type" => "reference"}
          }
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-ro-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "desk-ro",
        @dataset,
        ~w(read write admin),
        Tenancy.get_default_workspace().id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    # The story, then its author opened beside it: the story is read-only.
    path = "#{base}/#{type};#{id};#{author},type=#{target},parentRefPath=author"
    {:ok, conn: conn, path: path, n: n}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, c.path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#{@pane} dl.dk-fields") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  # Each term's label and the text of its value, in order.
  defp terms(view) do
    html = view |> element("#{@pane} dl.dk-fields") |> render()

    for [_, label, value] <- Regex.scan(~r{<dt>(.*?)</dt>\s*<dd[^>]*>(.*?)</dd>}s, html) do
      {String.trim(label), value |> String.replace(~r/<[^>]*>/, "") |> String.trim()}
    end
  end

  test "the read-only pane's header holds the Published and Draft pills, and no Status row", c do
    view = open(c)

    refute has_element?(view, "#{@pane}[data-pane-editing]")

    assert has_element?(
             view,
             ~s(#{@pane} > .pane-header > .dk-chips[data-desk-status] .dk-chip),
             "Published"
           )

    assert has_element?(
             view,
             ~s(#{@pane} > .pane-header > .dk-chips[data-desk-status] .dk-chip),
             "Draft"
           )

    refute Enum.any?(terms(view), fn {label, _} -> label == "Status" end)
  end

  test "its body is the form's column: the type, the big title, each value under its label", c do
    view = open(c)

    assert has_element?(view, "#{@pane} .dk-ro[data-desk-read-only] > .dk-kind", "Story #{c.n}")
    assert has_element?(view, "#{@pane} .dk-ro > .dk-big-title", "First story")
    # The pane's own heading stays, for screen readers.
    assert has_element?(view, "#{@pane} > .pane-header .pane-header-title", "First story")

    assert terms(view) == [{"Title", "First story"}, {"Excerpt", "Short."}, {"Author", "Ada"}]

    assert has_element?(
             view,
             "#{@pane} dd.dk-refs > a.dk-ref[data-desk-ref][aria-current=true]",
             "Ada"
           )

    # The close is one of the header's 25 px icon buttons.
    assert has_element?(view, "#{@pane} > .pane-header a.dk-close.icon-btn")
  end

  describe "the sheet" do
    test "draws the column, the title, the labels and the ringed values as the form's" do
      assert rule(".dk .dk-ro") =~ "padding: 28px max(20px, calc(50% - 300px)) 161px"

      assert rule(".dk .dk-ro .dk-big-title") =~
               "font-size: 33px; line-height: 41px; font-weight: 700"

      assert rule(".dk .dk-fields dt") =~ "font-size: 13px; line-height: 19px; font-weight: 500"
      assert rule(".dk .dk-fields") =~ "gap: 59px"

      for sel <- [".dk .dk-fields dd", ".dk .dk-fields .dk-refs > *"] do
        body = rule(sel)
        assert body =~ "box-shadow: inset 0 0 0 1px var(--dk-field-ring)"
        assert body =~ "background: var(--dk-field-fill)"
        assert body =~ "border-radius: 3px"
        assert body =~ "font-size: 15px; line-height: 23px"
      end

      # The pane and its header are the edit pane's: #13141b in dark, 51 px.
      assert rule(".dk .dk-doc:not(.dk-edit)") =~ "background: var(--dk-bg)"
      assert rule(".dk .dk-doc > .pane-header") =~ "height: 51px"
    end
  end
end
