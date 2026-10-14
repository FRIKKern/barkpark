defmodule BarkparkWeb.Studio.UnresolvedNoticeLandmarkTest do
  @moduledoc """
  "Studio could not open this document" stands in for the editor panel, as
  the nothing-selected state does, but it carried no main region and no
  heading: axe landmark-one-main + page-has-heading-one on every link to a
  disabled plugin's section, e.g. `/studio/fact` with Grip off (run 8 plugin
  axe pass). The card stays the alert; a wrapper holds the landmark.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.StudioComponents.Editor

  for {reason, cause} <- [
        unknown_node: nil,
        not_found: nil,
        not_found: :elsewhere,
        no_schema: nil,
        not_found: :out_of_reach
      ] do
    test "#{reason}/#{inspect(cause)}: one main region holding the alert and one h1" do
      html =
        render_component(&Editor.unresolved_document_notice/1, %{
          reason: unquote(reason),
          cause: unquote(cause),
          doc_id: "x-1",
          doc_type: "fact",
          elsewhere_name: "Agency",
          elsewhere_href: "/w/agency",
          list_href: nil,
          desk_href: "/studio"
        })

      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("[role=main], main") |> Enum.count() == 1
      assert doc |> LazyHTML.query("[role=main] > [role=alert]") |> Enum.count() == 1
      assert doc |> LazyHTML.query("h1") |> Enum.count() == 1

      assert doc |> LazyHTML.query("[role=alert] h1") |> LazyHTML.text() =~
               "Studio could not open this document."
    end
  end
end
