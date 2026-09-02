defmodule Barkpark.PortableDoc.Render.EmailGoldenTest do
  # Pure, in-process render — no DB, no Phoenix boot.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.ParityFixture

  # ── the Stage-2 email byte-lock (Wave 1, rail A) ────────────────────────────
  #
  # walk.ex's moduledoc pins "email output byte-identical" as a HARD contract:
  # email clients strip stylesheets, so the `:email` palette MUST keep emitting
  # inline styles, unchanged to the byte, forever. Every later Stage-2 slice
  # rewrites the `:article` emission (inline → class); this golden is the tripwire
  # that proves none of those edits leaked into the `:email` path.
  #
  # The golden is a CHARACTERISATION fixture: whatever walk.ex emits TODAY is
  # correct by definition. `email_golden.html` was generated from
  # `ParityFixture.tree/0` via `Render.render_html(_, render_opts(:email))` and
  # committed verbatim. To legitimately change email output (rare — it should
  # almost never move), regenerate the file in the SAME diff and justify why in
  # review. A diff here on an `:article`-only slice means the slice broke the
  # palette seam.
  #
  # Whitespace is NOT normalised: the assertion is raw byte identity. The golden
  # file carries NO trailing newline (it is the exact render output).

  @golden_path Path.expand("email_golden.html", __DIR__)
  @external_resource @golden_path

  describe ":email render byte-lock" do
    test "the all-kinds fixture renders byte-identical to the pinned golden" do
      # Read at RUNTIME (not a compile-time attr) so perturbing the golden file
      # is picked up on the next `mix test` without a manual recompile dance —
      # keeps the mutation-verify step honest.
      golden = File.read!(@golden_path)

      html = Render.render_html(ParityFixture.tree(), ParityFixture.render_opts(:email))

      assert html == golden, """
      :email render diverged from the pinned golden.

      This is a BYTE-LOCK. If you are on an :article Stage-2 slice, you changed
      the wrong palette — the :email path must stay inline and unchanged.

      If the email output change is intentional (rare), regenerate
      #{Path.relative_to_cwd(@golden_path)} in this same diff and justify it in
      review.

      golden bytes:  #{byte_size(golden)}
      render bytes:  #{byte_size(html)}
      first diff at: #{first_diff_index(html, golden)}
      """
    end

    test "golden is non-trivial and covers every rendered kind (guards a cleared fixture)" do
      golden = File.read!(@golden_path)
      assert byte_size(golden) > 5_000

      # One representative byte-sequence per kind / variant — a silently
      # truncated or half-built golden fails HERE with a readable message
      # instead of only as an opaque byte mismatch above.
      for needle <- [
            # container + prose
            ~s(<div style="max-width:600px),
            "<h1 style=",
            "<h2 style=",
            "<h3 style=",
            # Body copy carries its type INLINE (email clients strip
            # stylesheets). A bare `<p>` here means the paragraph leg lost its
            # stamp — see the "every body paragraph is typed" test below.
            ~s(<p style="margin:0 0 16px;font-family:),
            ">A plain body paragraph.</p>",
            # text marks (author DATA that stays inline in BOTH palettes)
            "font-weight:bold",
            "font-style:italic",
            "text-decoration:underline",
            "text-decoration:line-through",
            "color:#1e5347",
            # inline row
            ~s(<a href="https://example.com"),
            "<code style=",
            ~s(<a href="/tags/design"),
            # lists
            "<ul",
            "<ol",
            "<li",
            # internal refs
            ~s(href="/papers/doc-42"),
            "text-decoration:underline dotted",
            "data-taskchip=",
            "data-blockref=",
            ~s(<section class="paper-embed" data-embed="Embedded Note"),
            "paper-embed--unresolved",
            # valueref — all three states
            ~s(data-valueref-state="resolved"),
            ~s(data-valueref-state="drift"),
            ~s(data-valueref-state="dangling"),
            # buttons + rules + media
            "display:inline-block",
            ~s(<hr style="border:none;border-top:1px),
            ~s(<img src="https://example.com/a.png"),
            ~s( width="640"),
            # table + sheet
            "<table",
            ~s(colspan="2"),
            ~s(class="sheet-al-right"),
            ~s(class="sheet-al-center"),
            "background:#fef3c7",
            "color:#dc2626",
            # callouts (tones + collapsible)
            "border-left:3px solid #1e6b52",
            "border-left:3px solid #a63a2e",
            "<details",
            "<summary",
            # box geometry
            "flex-direction:row",
            "border:2px solid #1e5347",
            # id-pin wikilink fast path (paper pin + alias label; task pin chips)
            ~s(href="/papers/pin-1"),
            ">the pinned paper</a>",
            # sheet truncation note
            "Sheet truncated — showing the first 1 rows",
            # degrade/leaf clauses: _raw verbatim, bare-number leaf (position-
            # locked between the _raw close and the degrade div), unknown kind
            ~s(<pre class="mermaid">graph LR</pre>),
            "</pre>2026<div",
            ~s(<div class="bp-unknown-block">Unsupported block: PdHologram</div>)
          ] do
        assert String.contains?(golden, needle),
               "golden is missing coverage for: #{inspect(needle)}"
      end
    end
  end

  # ── every body paragraph carries inline type ────────────────────────────────
  #
  # The `:email` walk stamps every element kind inline BECAUSE mail clients strip
  # stylesheets — headings via heading_style/2, lists via the list clause, roles
  # via apply_text_role/4. The ordinary body `<p>` was the one leg that emitted
  # NO style attribute, so it inherited the client default (~16px/normal, a
  # system sans in Outlook) and read smaller than the 18px/1.55 ingress above it.
  #
  # This test is the named tripwire for that specific regression: if the
  # paragraph stamp is ever reverted, the byte-lock above fails opaquely on a
  # byte index, but THIS one fails saying "bare <p>".
  describe ":email body paragraphs are typed" do
    test "no bare <p> survives the walk — every one carries margin/font-size/line-height/color" do
      html = Render.render_html(ParityFixture.tree(), ParityFixture.render_opts(:email))

      # The ONLY permitted bare `<p>` is not walker output at all: it is the
      # pre-rendered embed body the fixture splices in verbatim
      # (ParityFixture @embeds => "<p>embedded body</p>"). Named exception.
      bare = Regex.scan(~r{<p>(.*?)</p>}s, html) |> Enum.map(&Enum.at(&1, 1))

      assert bare == ["embedded body"], """
      A bare <p> reached the :email render.

      Email clients strip stylesheets, so an unstyled <p> falls back to the
      client default (~16px/normal, a system sans in Outlook) and reads SMALLER
      than the 18px/1.55 ingress that introduces it. The paragraph leg must
      stamp margin / font-family / font-size / line-height / color inline —
      see Render.Walk body_type/2.

      Bare <p> bodies found: #{inspect(bare)}
      (the only allowed one is the fixture's pre-rendered embed, "embedded body")
      """
    end

    test "the plain body paragraph's stamp is palette-sourced, not a fresh literal" do
      html = Render.render_html(ParityFixture.tree(), ParityFixture.render_opts(:email))
      pal = Barkpark.PortableDoc.Render.Palettes.email_palette()

      stamp =
        "margin:0 0 16px;font-family:#{pal.font_body};font-size:17px;line-height:1.55;color:#{pal.text}"

      assert String.contains?(html, ~s(<p style="#{stamp}">A plain body paragraph.</p>)),
             """
             The plain body paragraph is not carrying the palette-sourced stamp.

             expected: <p style="#{stamp}">A plain body paragraph.</p>
             """
    end

    test ":article paragraphs stay BARE — the stylesheet owns their typography" do
      # The stamp is email-only by construction. `.bp-paper-surface p` is the
      # single source for article body type in both View and Edit; stamping
      # inline there would fork it.
      html = Render.render_html(ParityFixture.tree(), ParityFixture.render_opts(:article))
      assert String.contains?(html, "<p>A plain body paragraph.</p>")
    end
  end

  # Byte index of the first difference (or the shorter length) — a compact
  # locator to make an unexpected mismatch quick to bisect.
  defp first_diff_index(a, b) do
    a = :binary.bin_to_list(a)
    b = :binary.bin_to_list(b)

    Enum.zip(a, b)
    |> Enum.find_index(fn {x, y} -> x != y end)
    |> case do
      nil -> min(length(a), length(b))
      i -> i
    end
  end
end
