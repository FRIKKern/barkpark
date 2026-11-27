defmodule BarkparkWeb.Studio.RowEditorWrapIdTest do
  @moduledoc """
  #29171: the row rich text editor's wrapper id names the outer row keys,
  so a nested row's editor remounts when its outer rows change. #29206
  keeps those ids exactly (`{outer, key}`, `{[], key}` for a top-level row,
  `{[], nil}` for an object's rich text), so an open page's editors do not
  remount a second time at its deploy (#29206 review, round 1).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content

  @moduletag :studio_live

  defp rt, do: %{"name" => "rt", "title" => "rt", "type" => "richText"}

  defp member(name, fields),
    do: %{"type" => "composite", "name" => name, "title" => name, "fields" => fields}

  defp array(name, of), do: %{"name" => name, "title" => name, "type" => "arrayOf", "of" => [of]}

  setup %{conn: conn} do
    c = setup_doc(conn)

    fields = [
      %{"name" => "title", "title" => "Title", "type" => "string"},
      %{"name" => "meta", "title" => "Meta", "type" => "composite", "fields" => [rt()]},
      array("rows", member("row", [rt()])),
      array("sections", member("section", [array("items", member("item", [rt()]))]))
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => c.type, "title" => "Rows", "visibility" => "public", "fields" => fields},
        "production"
      )

    content = %{
      "meta" => %{"rt" => [block("mb", "meta")]},
      "rows" => [%{"_type" => "row", "_key" => "r1", "rt" => [block("rb", "row")]}],
      "sections" => [
        %{
          "_type" => "section",
          "_key" => "s1",
          "items" => [%{"_type" => "item", "_key" => "i1", "rt" => [block("ib", "item")]}]
        }
      ]
    }

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => "T0", "content" => content},
        "production"
      )

    c
  end

  defp wrap_id(view, name) do
    [_, wrap] =
      Regex.run(
        ~r/<div id="(bp-rt-sub-[^"]*)" phx-update="ignore"[^>]*data-pt-subfield="#{Regex.escape(name)}"/,
        render(view)
      )

    wrap
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: editor ids are main's: {[], key} for a top-level row, {outer, key} nested, {[], nil} for an object",
         c do
      path =
        case @surface do
          :desk -> "#{c.root}/_desk/#{c.type};#{c.id}"
          :studio -> "#{c.root}/#{c.type}/#{c.id}"
        end

      {:ok, view, _html} = live(c.conn, path)
      render_async(view, 5_000)
      assert eventually(fn -> has_element?(view, "#editor-form") end)

      assert String.ends_with?(
               wrap_id(view, "doc[rows][0].rt"),
               "-#{:erlang.phash2({[], "r1"})}"
             ),
             "a top-level row's editor id changed from main's"

      assert String.ends_with?(wrap_id(view, "doc[meta].rt"), "-#{:erlang.phash2({[], nil})}"),
             "an object rich text's editor id changed from main's"

      assert String.ends_with?(
               wrap_id(view, "doc[sections][0].items[0].rt"),
               "-#{:erlang.phash2({["s1"], "i1"})}"
             )
    end
  end
end
