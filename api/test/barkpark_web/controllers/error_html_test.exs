defmodule BarkparkWeb.ErrorHTMLTest do
  use BarkparkWeb.ConnCase, async: true

  # Without a working ErrorHTML module even a routine 404 on an unknown browser
  # route crashes the error renderer. These prove it renders a real, minimal
  # page instead — for 404, 500, and the catch-all. render/2 must return SAFE
  # iodata ({:safe, _}) or the HTML format encoder escapes the markup into
  # literal text (caught live in the integration probe).

  defp render_to_string(template) do
    assert {:safe, _} = safe = BarkparkWeb.ErrorHTML.render(template, %{})
    Phoenix.HTML.safe_to_string(safe)
  end

  test "renders a 404 page" do
    html = render_to_string("404.html")
    assert html =~ "<h1>404</h1>"
    assert html =~ "Not Found"
    assert html =~ "<!DOCTYPE html>"
  end

  test "renders a 500 page with no leaked detail" do
    html = render_to_string("500.html")
    assert html =~ "<h1>500</h1>"
    assert html =~ "Internal Server Error"
  end

  test "catch-all renders any other status from the template name" do
    html = render_to_string("503.html")
    assert html =~ "<h1>503</h1>"
    assert html =~ "Service Unavailable"
  end
end
