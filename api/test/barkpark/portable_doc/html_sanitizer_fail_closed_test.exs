defmodule Barkpark.PortableDoc.HtmlSanitizerFailClosedTest do
  # task-6428a147dd5c0cd4 (#28404 r6 review): a body that never settles is
  # served as its text in one <p>. That text ran adjacent blocks' words
  # together (`<p>a</p><p>b</p>` read `ab`).
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Barkpark.PortableDoc.HtmlSanitizer, as: S

  # One pass is not enough for this tail (the B5 unwrap): with the cap at one,
  # the body fails closed.
  @unsettled ~s(<ul><li>z<div><aside><li>y</li></aside></div></li></ul>)

  defp closed(html) do
    {out, _log} = with_log(fn -> S.sanitize(html <> @unsettled, max_passes: 1, id: "p") end)
    out
  end

  test "adjacent blocks keep a word boundary" do
    assert closed(~s(<p>a</p><p>b</p>)) == "<p>a b z y</p>"
  end

  test "headings, list items, cells and line breaks are boundaries too" do
    assert closed(~s(<h2>Title</h2><ul><li>one</li><li>two</li></ul>)) ==
             "<p>Title one two z y</p>"

    assert closed(~s(<table><tr><td>c1</td><td>c2</td></tr></table>)) == "<p>c1 c2 z y</p>"
    assert closed(~s(<p>line<br>next</p>)) == "<p>line next z y</p>"
  end

  test "inline elements do not split a word, and a run of whitespace is one space" do
    assert closed(~s(<p>wo<b>r</b>d<em>s</em>  and\n\tmore</p>)) == "<p>words and more z y</p>"
  end

  test "a non-breaking space is text, not a boundary to collapse" do
    assert closed(~s(<p>a&nbsp;&nbsp;b</p>)) == "<p>a&nbsp;&nbsp;b z y</p>"
  end

  test "the fail-closed text is itself a fixed point" do
    out = closed(~s(<p>a</p><div><p>b &lt;c&gt;</p></div>))
    assert S.sanitize(out) == out
  end
end
