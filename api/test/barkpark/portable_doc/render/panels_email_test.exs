defmodule Barkpark.PortableDoc.Render.PanelsEmailTest do
  # Pure, in-process render — no DB, no Phoenix boot. Clones the data_viz_test
  # email pattern for the fleet PANEL blocks (terminal / columns / status-legend).
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Compose
  alias Barkpark.PortableDoc.Render.PanelsEmail
  alias Barkpark.PortableDoc.Render.StatusVocab

  # ── terminal ─────────────────────────────────────────────────────────────────

  test "terminal email variant is a table with the three hard-coded traffic dots" do
    html =
      PanelsEmail.terminal_email_html(
        %{"type" => "terminal", "title" => "bp tasks"},
        "<p>body</p>"
      )

    assert html =~ "<table"
    refute html =~ ~s(class="bp-)
    # the ONE documented literal-hex exception — reader hard-codes the same hexes
    assert html =~ "#ef4444"
    assert html =~ "#f59e0b"
    assert html =~ "#22c55e"
    # title + child body pass through
    assert html =~ "bp tasks"
    assert html =~ "<p>body</p>"
  end

  test "terminal live flag paints a static dot in the ok tone (StatusVocab.tones)" do
    ok = StatusVocab.tones()["ok"]["light"]

    live =
      PanelsEmail.terminal_email_html(%{"type" => "terminal", "live" => true}, "")

    assert live =~ "background:#{ok}"
    assert live =~ ">live</td>"

    dead = PanelsEmail.terminal_email_html(%{"type" => "terminal"}, "")
    refute dead =~ ">live</td>"
  end

  test "terminal footer renders muted only when present" do
    with_foot =
      PanelsEmail.terminal_email_html(%{"type" => "terminal", "footer" => "q quit"}, "")

    assert with_foot =~ "q quit"

    without = PanelsEmail.terminal_email_html(%{"type" => "terminal"}, "")
    refute without =~ "border-top:1px solid"
  end

  test "compose routes terminal to the classed article markup, inline email otherwise" do
    block = %{"type" => "terminal", "title" => "T", "blocks" => []}

    %{"kind" => "_raw", "html" => article} = Compose.compose_block(block, :article)
    assert article =~ ~s(class="bp-term")

    %{"kind" => "_raw", "html" => email} = Compose.compose_block(block, :email)
    assert email =~ "<table"
    refute email =~ ~s(class="bp-)

    # top-level /3 path (render_block threads the theme) still routes email-side
    %{"kind" => "_raw", "html" => themed} = Compose.compose_block(block, :email, :evergreen)
    assert themed =~ "<table"
    refute themed =~ ~s(class="bp-)
  end

  test "a data-viz child nested in a terminal composes to ITS email variant (evergreen-nested)" do
    # A stat has an email variant independent of the fleet slices, so this proves
    # the container recurses children through their own email emitters. When w4a
    # merges, a task-list child composes to its email variant by the same path.
    block = %{
      "type" => "terminal",
      "title" => "board",
      "children" => [%{"type" => "stat", "value" => "14/14", "label" => "parity"}]
    }

    %{"kind" => "_raw", "html" => html} = Compose.compose_block(block, :email, :evergreen)

    # the stat's INLINE email variant (24px value), never its classed article form
    assert html =~ "font-size:24px"
    refute html =~ ~s(class="bp-stat")
    assert html =~ "14/14"
  end

  # ── columns ──────────────────────────────────────────────────────────────────

  test "columns email variant is a fixed equal-width table, one td per column" do
    html =
      PanelsEmail.columns_email_html(["<p>left</p>", "<p>right</p>"])

    assert html =~ "<table"
    refute html =~ ~s(class="bp-)
    # two vertical-align:top cells at equal width
    assert 2 == html |> String.split("vertical-align:top") |> length() |> Kernel.-(1)
    assert html =~ "width:50.0%"
    assert html =~ "<p>left</p>"
    assert html =~ "<p>right</p>"
  end

  test "columns with no columns degrades to an empty string" do
    assert PanelsEmail.columns_email_html([]) == ""

    %{"kind" => "_raw", "html" => html} =
      Compose.compose_block(%{"type" => "columns"}, :email)

    assert html == ""
  end

  test "compose routes columns to grid article markup, inline email otherwise" do
    block = %{
      "type" => "columns",
      "columns" => [
        [%{"type" => "paragraph", "content" => "a"}],
        [%{"type" => "paragraph", "content" => "b"}]
      ]
    }

    %{"kind" => "_raw", "html" => article} = Compose.compose_block(block, :article)
    assert article =~ ~s(class="bp-cols")

    %{"kind" => "_raw", "html" => email} = Compose.compose_block(block, :email)
    assert email =~ "<table"
    refute email =~ ~s(class="bp-)
  end

  # ── status-legend ────────────────────────────────────────────────────────────

  test "status-legend email variant is a table, one row per ladder role with tone glyphs" do
    html = PanelsEmail.status_legend_email_html(%{"type" => "status-legend"})

    assert html =~ "<table"
    refute html =~ ~s(class="bp-)

    # one <tr> per role, in manifest order
    role_count = length(StatusVocab.roles())
    assert role_count == html |> String.split("<tr>") |> length() |> Kernel.-(1)

    # every role's name + meaning is present
    for role <- StatusVocab.roles() do
      assert html =~ StatusVocab.label_for_role(role)
      assert html =~ StatusVocab.meaning_for_role(role)
    end
  end

  test "status-legend glyph colours come from StatusVocab.tones (never a literal)" do
    html = PanelsEmail.status_legend_email_html(%{"type" => "status-legend"})

    # done → ok, progress → info, blocked → warn — the reader's --st-* tones
    assert html =~ "color:#{StatusVocab.tones()["ok"]["light"]}"
    assert html =~ "color:#{StatusVocab.tones()["info"]["light"]}"
    assert html =~ "color:#{StatusVocab.tones()["warn"]["light"]}"
  end

  test "status-legend progress role degrades the animated glyph to a static ⠿" do
    html = PanelsEmail.status_legend_email_html(%{"type" => "status-legend"})
    # progress has no static manifest glyph (spinner) — email shows a static frame
    assert "" == StatusVocab.glyph_for_role("progress")
    assert html =~ "⠿"
  end

  test "compose routes status-legend to classed article markup, inline email otherwise" do
    block = %{"type" => "status-legend"}

    %{"kind" => "_raw", "html" => article} = Compose.compose_block(block, :article)
    assert article =~ ~s(class="bp-legend")

    %{"kind" => "_raw", "html" => email} = Compose.compose_block(block, :email)
    assert email =~ "<table"
    refute email =~ ~s(class="bp-)

    %{"kind" => "_raw", "html" => themed} = Compose.compose_block(block, :email, :evergreen)
    assert themed =~ "<table"
    refute themed =~ ~s(class="bp-)
  end

  # ── escaping ─────────────────────────────────────────────────────────────────

  test "author strings in terminal title/footer are escaped" do
    html =
      PanelsEmail.terminal_email_html(
        %{"type" => "terminal", "title" => "<script>", "footer" => "<b>x</b>"},
        ""
      )

    refute html =~ "<script>"
    refute html =~ "<b>x</b>"
    assert html =~ "&lt;script&gt;"
    assert html =~ "&lt;b&gt;x&lt;/b&gt;"
  end
end
