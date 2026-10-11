defmodule BarkparkWeb.Components.StudioBareCopyNbTest do
  @moduledoc """
  Run-8 non-gettext audit, Studio author core: text written straight into the
  HEEx never reached the catalog, so an nb Studio showed "2 issues: 1 error ·
  1 warning" on the publish check and "Start editing to see preview" in the
  content preview. The plural forms were built by appending "s".
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.OnixPreview
  alias BarkparkWeb.StudioComponents.Editor

  defp banner(violations),
    do: render_component(&Editor.cross_violations_banner/1, %{violations: violations})

  defp nb(fun), do: Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fun)
  defp en(fun), do: Gettext.with_locale(BarkparkWeb.Gettext, "en", fun)

  @two [
    %{"name" => "isbn", "level" => "error", "title" => "ISBN"},
    %{"name" => "price", "level" => "warning", "title" => "Price"}
  ]

  test "the publish-check banner counts in Norwegian, with real plural forms" do
    html = nb(fn -> banner(@two) end)
    assert html =~ "2 problemer:"
    assert html =~ "1 feil"
    assert html =~ "1 advarsel"

    one = nb(fn -> banner([hd(@two)]) end)
    assert one =~ "1 problem:"
    refute one =~ "advarsel"
  end

  test "the banner reads as before in English" do
    html = en(fn -> banner(@two) end)
    assert html =~ "2 issues:"
    assert html =~ "1 error"
    assert html =~ "1 warning"
    assert en(fn -> banner([hd(@two)]) end) =~ "1 issue:"
  end

  test "the content preview speaks Norwegian, empty and filled" do
    empty =
      nb(fn ->
        render_component(&OnixPreview.content_preview/1, %{rendered: nil, type: "book"})
      end)

    assert empty =~ "Forhåndsvisning"
    assert empty =~ "Begynn å redigere for å se forhåndsvisningen"

    filled =
      nb(fn ->
        render_component(&OnixPreview.content_preview/1, %{rendered: "abc", type: "book"})
      end)

    assert filled =~ "3 byte"
    refute filled =~ "bytes"

    named =
      nb(fn ->
        render_component(&OnixPreview.content_preview/1, %{
          rendered: nil,
          type: "book",
          title: "ONIX"
        })
      end)

    assert named =~ ">ONIX<"
  end
end
