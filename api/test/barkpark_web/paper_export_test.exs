defmodule BarkparkWeb.PaperExportTest do
  @moduledoc """
  The paper header's Export button (task-a5ba0a62b64635ac): what
  `PaperExport.export_button/1` hands to bp-paper-export.js, and the menu's
  words.

  The script reads everything off the button's wrapper, so a missing attribute
  is a silent failure in the browser: a block between two canvases would leave
  the file without a word, and Print would open a page that does not exist.
  Its words come from `StudioLocale.component_strings(:paper_hooks)`, keyed by
  the English text it falls back to; one the map lacks would stay English in a
  Norwegian Studio without any error.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias BarkparkWeb.Studio.StudioLive.Components.PaperExport
  alias BarkparkWeb.StudioLocale

  @script Path.join(:code.priv_dir(:barkpark), "static/assets/bp-paper-export.js")

  setup do
    on_exit(fn -> Gettext.put_locale(BarkparkWeb.Gettext, "en") end)
  end

  defp attr(html, name) do
    [_, value] = Regex.run(~r/\s#{name}="([^"]*)"/, html)

    value
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
  end

  @blocks [
    %{"id" => "p1", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "One"}]},
    %{"id" => "t1", "type" => "table", "head" => [["A"]], "rows" => [[["1"]]]},
    %{"id" => "p2", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "Two"}]},
    %{"id" => "s1", "type" => "steps", "steps" => [%{"title" => "Claim"}]}
  ]

  test "the button carries the blocks no canvas holds, in order, and names the file and the editor" do
    html =
      render_component(&PaperExport.export_button/1,
        slug: "drafts.field-notes",
        title: "Field notes",
        blocks: @blocks,
        draft: true,
        has_published: true,
        scope_prefix: "/w/acme/p/site"
      )

    assert html =~ ~s(aria-haspopup="menu")
    assert html =~ ~s(aria-expanded="false")
    assert html =~ ~s(phx-update="ignore")
    assert attr(html, "data-paper-export-editor") == "paper-editor-drafts.field-notes"
    assert attr(html, "data-paper-export-file") == "field-notes"
    assert attr(html, "data-paper-export-title") == "Field notes"

    kept = html |> attr("data-paper-export-blocks") |> Jason.decode!()
    assert Enum.map(kept, & &1["id"]) == ["t1", "s1"]
    assert Enum.at(kept, 0)["rows"] == [[["1"]]]

    # A draft with a published version prints that version, under the published id.
    assert attr(html, "data-paper-export-print") == "/w/acme/p/site/papers/field-notes"
    assert attr(html, "data-paper-export-print-state") == "draft"
  end

  test "a paper that was never published has no page to print" do
    html =
      render_component(&PaperExport.export_button/1,
        slug: "drafts.new",
        blocks: [],
        draft: true,
        has_published: false
      )

    refute html =~ "data-paper-export-print="
    assert attr(html, "data-paper-export-blocks") == "[]"
  end

  test "every word the menu asks for is in the map, and is Norwegian in a Norwegian Studio" do
    words =
      ~r/(?<![\w.])t\("([^"]+)"/
      |> Regex.scan(File.read!(@script), capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert length(words) >= 11, "the scan found only #{length(words)} words: #{inspect(words)}"

    Gettext.put_locale(BarkparkWeb.Gettext, "nb_NO")
    nb = Jason.decode!(StudioLocale.component_strings(:paper_hooks))

    for word <- words do
      assert is_binary(nb[word]), "the map has no #{inspect(word)}"
      assert nb[word] != word, "#{inspect(word)} is not translated to Norwegian"
    end

    assert nb["%{block}: not included in Markdown export"] =~ "%{block}"
  end

  test "the Studio layout loads the menu without holding the page" do
    root = File.read!("lib/barkpark_web/layouts/root.html.heex")

    assert root =~
             ~s|<script src={BarkparkWeb.StaticAssets.path("bp-paper-export.js")} async></script>|
  end
end
