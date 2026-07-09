defmodule Barkpark.PortableDoc.Render.CardsEmailTest do
  # Pure, in-process render — no DB, no Phoenix boot.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.CardsEmail
  alias Barkpark.PortableDoc.Render.Compose
  alias Barkpark.PortableDoc.Render.StatusVocab

  # The card-tone light hexes are the SINGLE manifest source — the test reads them
  # the same way the emitter does, so a manifest change moves both together.
  @tones StatusVocab.tones()
  defp tone_light(t), do: @tones |> Map.fetch!(t) |> Map.fetch!("light")

  # ── the fleet takes the inline-styled email variants ─────────────────────────

  test "email style takes the inline-styled fleet variants — no bp-* classes" do
    for {block, marker} <- [
          {%{"type" => "cards", "items" => [%{"title" => "A", "text" => "one"}]}, "<table"},
          {%{"type" => "card", "tone" => "info", "title" => "C"}, "border-top:3px"},
          {%{"type" => "notes", "items" => [%{"label" => "x", "text" => "y"}]}, "<table"},
          {%{"type" => "note", "label" => "x", "text" => "y"}, "<table"},
          {%{"type" => "pipeline", "nodes" => [%{"kind" => "src", "title" => "in"}]}, "<table"},
          {%{"type" => "stage", "kind" => "src", "title" => "in"}, "border-radius:10px"}
        ] do
      %{"kind" => "_raw", "html" => html} = Compose.compose_block(block, :email)
      assert html =~ marker
      refute html =~ ~s(class="bp-)
      refute html =~ "<svg"
    end
  end

  # ── cards: 2-col table, tone top-border from the manifest hex ─────────────────

  test "cards lays items in a 2-column table with tone-coloured top borders" do
    html =
      CardsEmail.cards_email_html(%{
        "type" => "cards",
        "items" => [
          %{"title" => "Info", "text" => "note", "tone" => "info"},
          %{"title" => "OK", "text" => "good", "tone" => "ok"},
          %{"title" => "Warn", "tone" => "warn"}
        ]
      })

    assert html =~ ~s|<table role="presentation"|
    # one <td> per card + one pad cell (odd count) → 4 cells across 2 rows
    assert html |> String.split("<td") |> length() == 5
    assert html =~ "border-top:3px solid #{tone_light("info")}"
    assert html =~ "border-top:3px solid #{tone_light("ok")}"
    assert html =~ "border-top:3px solid #{tone_light("warn")}"
    assert html =~ ">Info</div>"
    assert html =~ ">note</div>"
  end

  test "cards without a recognised tone stays on the neutral rule border" do
    html = CardsEmail.cards_email_html(%{"type" => "cards", "items" => [%{"title" => "Plain"}]})
    refute html =~ "border-top:3px solid #{tone_light("info")}"
    # no status hex leaks onto an untoned card
    for t <- ~w(info ok warn danger), do: refute(html =~ tone_light(t))
  end

  test "cards with no items degrades to the honest empty box" do
    assert CardsEmail.cards_email_html(%{"type" => "cards", "items" => []}) =~ "cards — no data"
    assert CardsEmail.cards_email_html(%{"type" => "cards"}) =~ "cards — no data"
  end

  # ── card: single tone-topped box, danger tone from the manifest ───────────────

  test "singular card paints its top border the danger manifest hex" do
    html = CardsEmail.card_email_html(%{"type" => "card", "tone" => "danger", "title" => "Boom"})
    assert html =~ "border-top:3px solid #{tone_light("danger")}"
    refute html =~ "<table"
  end

  # ── notes / note: shared row, accent-tinted chip ──────────────────────────────

  test "notes renders one row per item with a bold lead and a label chip" do
    html =
      CardsEmail.notes_email_html(%{
        "type" => "notes",
        "items" => [%{"label" => "upgraded", "lead" => "Masthead", "text" => "now inline"}]
      })

    assert html =~ "<tr>"
    assert html =~ ">upgraded</span>"
    assert html =~ "<b>Masthead</b> now inline"
  end

  test "a singular note renders byte-identically to a single-item notes block" do
    fields = %{"label" => "x", "lead" => "L", "text" => "body"}
    note = CardsEmail.note_email_html(Map.put(fields, "type", "note"))
    notes = CardsEmail.notes_email_html(%{"type" => "notes", "items" => [fields]})
    assert note == notes
  end

  # ── pipeline / stage: the byte-identical twin (held in email too) ─────────────

  test "pipeline joins node cells with arrow cells in one horizontal table" do
    html =
      CardsEmail.pipeline_email_html(%{
        "type" => "pipeline",
        "nodes" => [
          %{"kind" => "source", "title" => "ingest", "detail" => "read"},
          %{"kind" => "gate", "title" => "emit", "source" => true}
        ]
      })

    assert html =~ ~s|<table role="presentation"|
    assert html =~ ">→</td>"
    # kind sits uppercase in the accent
    assert html =~ ">SOURCE</div>" or html =~ ">source</div>"
    assert html =~ "text-transform:uppercase"
  end

  test "a stage cell is byte-identical to the one pipeline node cell it twins" do
    scalars = %{"kind" => "source", "title" => "ingest", "detail" => "read", "files" => "a.ex"}

    stage = CardsEmail.stage_email_html(Map.put(scalars, "type", "stage"))
    pipeline = CardsEmail.pipeline_email_html(%{"type" => "pipeline", "nodes" => [scalars]})

    # the stage IS one pipeline node cell (no flow wrapper) — appears verbatim
    assert String.contains?(pipeline, stage)
    # and the stage carries no table/flow chrome of its own
    refute stage =~ "<table"
    refute stage =~ "→"
  end

  test "source:true takes the accent border; a source string takes a provenance line" do
    origin = CardsEmail.stage_email_html(%{"type" => "stage", "kind" => "k", "source" => true})
    prov = CardsEmail.stage_email_html(%{"type" => "stage", "kind" => "k", "source" => "seed.ex"})

    # accent-bordered origin node has NO provenance line
    refute origin =~ "seed"
    # provenance string renders as its own line
    assert prov =~ ">seed.ex</div>"
  end

  # ── the theme-aware /3 seam moves bytes (charter D1/D2) ──────────────────────

  test "compose_block/3 threads the theme through the card skin" do
    # ember paper (#fdfcfb) is the ember card surface; evergreen would be #ffffff
    %{"kind" => "_raw", "html" => ember} =
      Compose.compose_block(%{"type" => "card", "tone" => "info", "title" => "C"}, :email, :ember)

    assert ember =~ "background:#fdfcfb"
    # card tones are theme-invariant (manifest, not skin)
    assert ember =~ "border-top:3px solid #{tone_light("info")}"
  end

  # ── escaping ─────────────────────────────────────────────────────────────────

  test "author strings are escaped across the fleet" do
    html =
      CardsEmail.cards_email_html(%{"type" => "cards", "items" => [%{"title" => "<script>"}]})

    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"

    node = CardsEmail.stage_email_html(%{"type" => "stage", "title" => "<b>x</b>"})
    refute node =~ "<b>x</b>"
    assert node =~ "&lt;b&gt;x&lt;/b&gt;"
  end
end
