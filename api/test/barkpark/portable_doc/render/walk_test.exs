defmodule Barkpark.PortableDoc.Render.WalkTest do
  # Pure, in-process walker — no DB, no side-effects.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Walk
  alias Barkpark.PortableDoc.Render.Palettes
  alias Barkpark.PortableDoc.Render.StatusVocab

  @email Palettes.email_palette()
  @article Palettes.article_palette()
  @width 600

  # ── render_body/3 ──────────────────────────────────────────────────────────

  describe "render_body/3 — PdHr" do
    test "emits hr with default thickness 1 and palette rule colour" do
      html = Walk.render_body(%{"kind" => "PdHr"}, @width, @email)
      assert html == ~s(<hr style="border:none;border-top:1px solid #dde7e2;margin:30px 0 26px">)
    end

    test "respects explicit thickness" do
      html = Walk.render_body(%{"kind" => "PdHr", "thickness" => 3}, @width, @email)
      assert html =~ "border-top:3px solid"
    end

    # Stage 2 wave 2: the article rule is class-driven (`.bp-hr` owns the
    # reset/colour/margin); ONLY the author thickness (DATA) rides inline, as
    # `border-top-width` so it layers over the class's `border-top` shorthand.
    test "article emits bp-hr with the thickness inline as border-top-width" do
      assert Walk.render_body(%{"kind" => "PdHr"}, @width, @article) ==
               ~s(<hr class="bp-hr" style="border-top-width:1px">)

      assert Walk.render_body(%{"kind" => "PdHr", "thickness" => 3}, @width, @article) ==
               ~s(<hr class="bp-hr" style="border-top-width:3px">)
    end

    test "article thickness can't break out of the style attribute (own escape path)" do
      html =
        Walk.render_body(%{"kind" => "PdHr", "thickness" => ~s(1" onload="x)}, @width, @article)

      assert html =~ "&quot;"
      refute html =~ ~s(onload=")
    end
  end

  describe "render_body/3 — PdInlineCode" do
    test "escapes HTML entities inside value" do
      html = Walk.render_body(%{"kind" => "PdInlineCode", "value" => "a & <b>"}, @width, @email)
      assert html =~ "a &amp; &lt;b&gt;"
      assert html =~ "<code style="
    end

    test "uses empty string when value is absent" do
      html = Walk.render_body(%{"kind" => "PdInlineCode"}, @width, @email)
      assert html =~ "<code style="
      refute html =~ "nil"
    end

    test "@email chip pins the 1px 5px / 0.88em rounded palette" do
      html = Walk.render_body(%{"kind" => "PdInlineCode", "value" => "x"}, @width, @email)
      assert html =~ "padding:1px 5px"
      assert html =~ "font-size:0.88em"
      assert html =~ "border-radius:4px"
    end

    test "@article chip is a BARE <code> — the .bp-paper-surface code rule owns the chip" do
      # Stage 2: article inline code drops ALL inline styling; the surface
      # element rule (font/size/bg/padding/radius, single-sourced from --bp-*
      # code tokens) styles it identically in View and Edit by construction.
      html = Walk.render_body(%{"kind" => "PdInlineCode", "value" => "x"}, @width, @article)
      assert html == "<code>x</code>"
      refute html =~ "style="
      # And it still escapes its value (no markup injection through the chip).
      esc = Walk.render_body(%{"kind" => "PdInlineCode", "value" => "a & <b>"}, @width, @article)
      assert esc == "<code>a &amp; &lt;b&gt;</code>"
    end
  end

  describe "render_body/3 — PdText" do
    test "emits bare span with no style when node has no decoration" do
      html = Walk.render_body(%{"kind" => "PdText", "children" => ["hello"]}, @width, @email)
      assert html == "<span>hello</span>"
    end

    test "combines bold + strike into correct style attributes" do
      node = %{
        "kind" => "PdText",
        "weight" => "bold",
        "strike" => true,
        "children" => ["x"]
      }

      html = Walk.render_body(node, @width, @email)
      assert html =~ "font-weight:bold"
      assert html =~ "text-decoration:line-through"
    end

    test "escapes HTML in string children" do
      node = %{"kind" => "PdText", "children" => ["<script>"]}
      html = Walk.render_body(node, @width, @email)
      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>"
    end
  end

  describe "render_body/3 — PdParagraph reader boundary" do
    test "an empty scaffold emits no public or email HTML" do
      node = %{"kind" => "PdParagraph", "children" => []}

      assert Walk.render_body(node, @width, @article) == ""
      assert Walk.render_body(node, @width, @email) == ""
    end

    test "an authored paragraph remains byte-faithful" do
      node = %{"kind" => "PdParagraph", "children" => ["Some prose"]}

      # `:article` stays BARE — `.bp-paper-surface p` is the single source of
      # body typography in both View and Edit.
      assert Walk.render_body(node, @width, @article) == "<p>Some prose</p>"

      # `:email` carries the type INLINE (mail clients strip stylesheets), from
      # the palette rather than a re-typed literal.
      pal = Barkpark.PortableDoc.Render.Palettes.email_palette()

      assert Walk.render_body(node, @width, @email) ==
               ~s(<p style="margin:0 0 16px;font-family:#{pal.font_body};font-size:17px;) <>
                 ~s(line-height:1.55;color:#{pal.text}">Some prose</p>)
    end
  end

  describe "render_body/3 — PdLink" do
    test "wraps children in anchor with safe href" do
      node = %{"kind" => "PdLink", "href" => "https://example.com", "children" => ["go"]}
      html = Walk.render_body(node, @width, @email)
      assert html =~ ~s(href="https://example.com")
      assert html =~ "go"
      assert html =~ "<a "
      # Email keeps the real underline — the correct convention off-surface.
      assert html =~ "text-decoration:underline"
    end

    test "article link drops the inline decoration/border — the .bp-paper-surface a rule owns it" do
      node = %{"kind" => "PdLink", "href" => "https://example.com", "children" => ["go"]}
      html = Walk.render_body(node, @width, @article)
      # Stage 2: no inline text-decoration or border-bottom at all; the surface
      # element rule paints the soft-border at-rest look in View and Edit alike.
      refute html =~ "text-decoration"
      refute html =~ "border-bottom"
      # The accent link colour stays inline (the same --paper-accent token the
      # CSS rule resolves — data-adjacent, no drift).
      assert html ==
               ~s|<a href="https://example.com" style="color:var(--paper-accent, #1e5347)">go</a>|
    end

    test "javascript: href is sanitised by safe_url (returns # sentinel)" do
      node = %{"kind" => "PdLink", "href" => "javascript:alert(1)", "children" => ["bad"]}
      html = Walk.render_body(node, @width, @email)
      # safe_url returns "#" for unsafe schemes — never a bare javascript: in the DOM
      assert html =~ ~s(href="#")
      refute html =~ "javascript:"
    end
  end

  describe "render_body/3 — PdWikilink" do
    test "renders unresolved target as dotted span (no href)" do
      node = %{
        "kind" => "PdWikilink",
        "target" => "Missing Page",
        "children" => ["Missing Page"]
      }

      html = Walk.render_body(node, @width, @email)
      assert html =~ ~s(data-wikilink="Missing Page")
      assert html =~ "text-decoration:underline dotted"
      refute html =~ "<a "
    end

    test "renders resolved target as <a href=/papers/:id>" do
      pal = Map.put(@email, :wikilinks, %{"Home" => %{id: "doc-42"}})

      node = %{
        "kind" => "PdWikilink",
        "target" => "Home",
        "children" => ["Home"]
      }

      html = Walk.render_body(node, @width, pal)
      assert html =~ ~s(href="/papers/doc-42")
      assert html =~ "<a "
    end

    test "id-pin: a carried doc_id resolves to /papers/:id with an EMPTY :wikilinks palette" do
      # Proves the id-pin bypasses title resolution — the palette has no entry
      # for "Setup" (in fact it has no entries at all), yet the pin still links.
      pal = Map.put(@email, :wikilinks, %{})

      node = %{
        "kind" => "PdWikilink",
        "target" => "Setup",
        "doc_id" => "p-pinned-99",
        "children" => ["Setup"]
      }

      html = Walk.render_body(node, @width, pal)
      assert html =~ ~s(href="/papers/p-pinned-99")
      assert html =~ ~s(data-wikilink="Setup")
      assert html =~ "text-decoration:none"
      refute html =~ "dotted"
    end

    test "id-pin: doc_id wins over a clashing title entry (duplicate-title hole)" do
      # Two papers share the title "Setup"; the palette resolves the title to
      # the WRONG one. The pinned doc_id must override and link the picked paper.
      pal = Map.put(@email, :wikilinks, %{"Setup" => %{id: "wrong-doc"}})

      node = %{
        "kind" => "PdWikilink",
        "target" => "Setup",
        "doc_id" => "right-doc",
        "children" => ["Setup"]
      }

      html = Walk.render_body(node, @width, pal)
      assert html =~ ~s(href="/papers/right-doc")
      refute html =~ "wrong-doc"
    end

    test "no doc_id: empty/missing pin is byte-identical to the pre-pin render" do
      # A typed-not-picked wikilink (no doc_id) must round-trip exactly as
      # before — resolved via palette, dotted span when absent, and an empty
      # "" doc_id must NOT trigger the fast path.
      node = %{"kind" => "PdWikilink", "target" => "Home", "children" => ["Home"]}
      node_empty = Map.put(node, "doc_id", "")
      pal = Map.put(@email, :wikilinks, %{"Home" => %{id: "doc-42"}})

      # Resolved-via-palette path is untouched whether doc_id is absent or "".
      assert Walk.render_body(node, @width, pal) == Walk.render_body(node_empty, @width, pal)
      assert Walk.render_body(node, @width, pal) =~ ~s(href="/papers/doc-42")

      # Unresolved (empty palette) still degrades to the dotted span.
      bare = Map.put(@email, :wikilinks, %{})
      assert Walk.render_body(node, @width, bare) =~ "text-decoration:underline dotted"
      assert Walk.render_body(node_empty, @width, bare) == Walk.render_body(node, @width, bare)
    end
  end

  describe "render_body/3 — PdWikilink task chip (lvw-t7)" do
    @task_hit %{
      id: "lvw-t7",
      title: "Type-aware resolver",
      kind: "task",
      status: "open",
      priority: 1,
      criteria: %{met: 2, total: 5}
    }

    test "a target resolving to a task renders the live chip, not a link" do
      pal = Map.put(@email, :wikilinks, %{"Type-aware resolver" => @task_hit})

      node = %{
        "kind" => "PdWikilink",
        "target" => "Type-aware resolver",
        "children" => ["the resolver task"]
      }

      html = Walk.render_body(node, @width, pal)
      assert html =~ ~s(data-taskchip="Type-aware resolver")
      assert html =~ ~s(data-task-id="lvw-t7")
      assert html =~ ~s(data-task-status="open")
      assert html =~ "○ open · P1 · 2/5"
      assert html =~ "Type-aware resolver"
      refute html =~ "<a "
    end

    test "id-pin: a picker-stamped TASK link renders the chip, never /papers/<task-id>" do
      pal = Map.put(@email, :wikilinks, %{{:id, "lvw-t7"} => @task_hit})

      node = %{
        "kind" => "PdWikilink",
        "target" => "Type-aware resolver",
        "doc_id" => "lvw-t7",
        "children" => ["chip"]
      }

      html = Walk.render_body(node, @width, pal)
      assert html =~ "data-taskchip="
      assert html =~ "○ open · P1 · 2/5"
      refute html =~ "/papers/lvw-t7"
      refute html =~ "<a "
    end

    test "id-pin without a palette task hit keeps the existing /papers/ link" do
      # A pinned PAPER (or a palette-less render, e.g. the body_html cache path)
      # is byte-identical to the pre-chip fast path.
      pal =
        Map.put(@email, :wikilinks, %{{:id, "p-9"} => %{id: "p-9", title: "P", kind: "paper"}})

      node = %{"kind" => "PdWikilink", "target" => "P", "doc_id" => "p-9", "children" => ["P"]}

      html = Walk.render_body(node, @width, pal)
      assert html =~ ~s(href="/papers/p-9")
      refute html =~ "data-taskchip"
    end

    test "criteria-absent OMITS the m/n segment — never 0/0" do
      hit = %{@task_hit | criteria: nil, priority: 2}
      pal = Map.put(@email, :wikilinks, %{"T" => hit})
      node = %{"kind" => "PdWikilink", "target" => "T", "children" => ["T"]}

      html = Walk.render_body(node, @width, pal)
      refute html =~ "0/0"
      assert html =~ "○ open · P2"
      refute html =~ "P2 ·"
    end

    test "priority 0 is VALID (the highest) and renders P0" do
      hit = %{@task_hit | priority: 0, criteria: nil}
      pal = Map.put(@email, :wikilinks, %{"T" => hit})
      node = %{"kind" => "PdWikilink", "target" => "T", "children" => ["T"]}

      assert Walk.render_body(node, @width, pal) =~ "P0"
    end

    test "garbage-tolerant: missing status/priority degrade to the neutral glyph alone" do
      hit = %{id: "t-x", title: "Bare", kind: "task", status: nil, priority: nil, criteria: nil}
      pal = Map.put(@email, :wikilinks, %{"Bare" => hit})
      node = %{"kind" => "PdWikilink", "target" => "Bare", "children" => ["Bare"]}

      html = Walk.render_body(node, @width, pal)
      assert html =~ "▸"
      refute html =~ "P0"
      refute html =~ "data-task-status"
      assert html =~ "Bare"
    end

    test "status glyphs cover the lifecycle; unknown gets the neutral pointer" do
      # Human-readable pin of the ladder as the chip actually renders it (charter
      # D5 / D114): the `in_progress` spinner degrades to the ⠿ still-frame, and
      # `blocked`/`done` carry the manifest glyphs ! / ✓. open (○), cancelled (✕)
      # and the unknown sentinel (▸) are unchanged. This table is the readable
      # twin of the manifest-derived delegation test below.
      for {status, glyph} <- [
            {"open", "○"},
            {"in_progress", "⠿"},
            {"blocked", "!"},
            {"done", "✓"},
            {"cancelled", "✕"},
            {"someday", "▸"}
          ] do
        hit = %{@task_hit | status: status, criteria: nil, priority: nil}
        pal = Map.put(@email, :wikilinks, %{"T" => hit})
        node = %{"kind" => "PdWikilink", "target" => "T", "children" => ["T"]}
        assert Walk.render_body(node, @width, pal) =~ "#{glyph} #{status}"
      end
    end

    test "task_glyph DELEGATES to the StatusVocab manifest — glyphs derived, spinner degraded to ⠿" do
      # Expected glyphs are DERIVED from design/status-manifest.json via
      # StatusVocab, never hardcoded here — the chip cannot silently drift from
      # the one source of truth. The single deliberate transform is charter D5:
      # the `progress` (in_progress) spinner role renders the ⠿ still-frame on
      # this Elixir surface, matching the sibling emitter fleet_email.ex and
      # DELIBERATELY unlike Go pdrender's terminal ⠋ frame — a per-surface
      # consistency choice, not drift.
      for {status, role} <- StatusVocab.statuses() do
        expected =
          if StatusVocab.spinner?(role), do: "⠿", else: StatusVocab.glyph_for_role(role)

        hit = %{@task_hit | status: status, criteria: nil, priority: nil}
        pal = Map.put(@email, :wikilinks, %{"T" => hit})
        node = %{"kind" => "PdWikilink", "target" => "T", "children" => ["T"]}

        assert Walk.render_body(node, @width, pal) =~ "#{expected} #{status}",
               "chip drifted from the manifest for status #{inspect(status)} (role #{inspect(role)})"
      end

      # The spinner role specifically resolves to the ⠿ still-frame — NOT the raw
      # manifest glyph (which is "" for the animated role) and NOT Go's ⠋ frame.
      hit = %{@task_hit | status: "in_progress", criteria: nil, priority: nil}
      pal = Map.put(@email, :wikilinks, %{"T" => hit})
      node = %{"kind" => "PdWikilink", "target" => "T", "children" => ["T"]}
      html = Walk.render_body(node, @width, pal)
      assert html =~ "⠿ in_progress"
      refute html =~ "⠋"
    end

    test "chip escapes hostile resolver strings (title/status/id)" do
      hit = %{
        id: ~s(t"><script>),
        title: "<script>alert(1)</script>",
        kind: "task",
        status: ~s(open"onmouseover="x),
        priority: nil,
        criteria: nil
      }

      pal = Map.put(@email, :wikilinks, %{"T" => hit})
      node = %{"kind" => "PdWikilink", "target" => "T", "children" => ["T"]}

      html = Walk.render_body(node, @width, pal)
      refute html =~ "<script>"
      refute html =~ ~s(onmouseover="x")
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "render_body/3 — PdWikilink label fallback (alias → children → target)" do
    test "CHILDLESS aliased wikilink shows the alias VISIBLY (rendered empty before)" do
      # The chip-shaped node (alias set, children []) — with an empty palette it
      # must degrade to the dotted span containing the alias text.
      pal = Map.put(@email, :wikilinks, %{})

      node = %{
        "kind" => "PdWikilink",
        "target" => "lvw-t7",
        "alias" => "the resolver task",
        "children" => []
      }

      html = Walk.render_body(node, @width, pal)
      assert html =~ "text-decoration:underline dotted"
      assert html =~ "the resolver task"
    end

    test "childless, alias-less wikilink falls back to the target text" do
      pal = Map.put(@email, :wikilinks, %{})
      node = %{"kind" => "PdWikilink", "target" => "Orphan Target", "children" => []}

      html = Walk.render_body(node, @width, pal)
      assert html =~ ">Orphan Target</span>"
    end

    test "alias outranks children when both are present" do
      pal = Map.put(@email, :wikilinks, %{})

      node = %{
        "kind" => "PdWikilink",
        "target" => "T",
        "alias" => "display alias",
        "children" => ["typed text"]
      }

      html = Walk.render_body(node, @width, pal)
      assert html =~ "display alias"
      refute html =~ "typed text"
    end
  end

  describe "render_body/3 — PdEmbed" do
    test "renders the transclusion container with the injected, pre-rendered html" do
      # The :embeds entry IS renderer output — injected verbatim inside the
      # <section class="paper-embed"> with the data-embed pointing at the target.
      pal = Map.put(@email, :embeds, %{"Note A" => "<p>hello world</p>"})
      node = %{"kind" => "PdEmbed", "target" => "Note A"}

      html = Walk.render_body(node, @width, pal)
      assert html =~ ~s(<section class="paper-embed" data-embed="Note A")
      assert html =~ "<p>hello world</p>"
      refute html =~ "paper-embed--unresolved"
    end

    test "renders the unresolved fallback when the target is absent from :embeds" do
      # No matching entry → a NON-navigating broken-embed placeholder (no <a>,
      # since a raw human title is not a slug and would 404), mirroring the
      # wikilink dotted-span treatment.
      pal = Map.put(@email, :embeds, %{})
      node = %{"kind" => "PdEmbed", "target" => "Ghost Note"}

      html = Walk.render_body(node, @width, pal)
      assert html =~ "paper-embed paper-embed--unresolved"
      assert html =~ ~s(data-embed="Ghost Note")
      assert html =~ "↪ Ghost Note"
      refute html =~ "<a "
      refute html =~ "/papers/"
      refute html =~ "<p>"
    end

    test "no :embeds key at all degrades to the unresolved fallback" do
      # Byte-identical to a caller who never opts in — empty map ≡ missing key.
      node = %{"kind" => "PdEmbed", "target" => "Note A"}
      with_empty = Map.put(@email, :embeds, %{})

      assert Walk.render_body(node, @width, @email) =~ "paper-embed--unresolved"
      assert Walk.render_body(node, @width, @email) == Walk.render_body(node, @width, with_empty)
    end

    test "injected html is NOT double-escaped — it appears verbatim inside the section" do
      # The resolver already produced safe HTML; the walker emits it as-is. A
      # raw "<p>hi</p>" must survive intact, NOT become "&lt;p&gt;hi&lt;/p&gt;".
      pal = Map.put(@email, :embeds, %{"Note A" => "<p>hi</p>"})
      node = %{"kind" => "PdEmbed", "target" => "Note A"}

      html = Walk.render_body(node, @width, pal)
      assert html =~ "<p>hi</p>"
      refute html =~ "&lt;p&gt;"
    end

    test "the data-embed attr value IS escaped" do
      # The target string flows through escape_html — quotes/brackets can't
      # break out of the attribute, even though the injected body is verbatim.
      pal = Map.put(@email, :embeds, %{~s(A "quote" & <b>) => "<p>ok</p>"})
      node = %{"kind" => "PdEmbed", "target" => ~s(A "quote" & <b>)}

      html = Walk.render_body(node, @width, pal)
      assert html =~ ~s(data-embed="A &quot;quote&quot; &amp; &lt;b&gt;")
      # The injected body is still verbatim — only the attr was escaped.
      assert html =~ "<p>ok</p>"
    end
  end

  describe "render_body/3 — PdTag" do
    test "renders a navigable <a href=/tags/:name> chip with #name text" do
      node = %{"kind" => "PdTag", "name" => "design"}

      html = Walk.render_body(node, @width, @email)
      assert html =~ ~s(<a href="/tags/design")
      assert html =~ ~s(data-tag="design")
      assert html =~ "#design"
      # Chip styling survives the span → anchor conversion.
      assert html =~ "border-radius:3px"
      assert html =~ "font-size:0.9em"
      assert html =~ "text-decoration:none"
    end

    test "url-encodes the name in the href but shows it decoded in the chip" do
      node = %{"kind" => "PdTag", "name" => "my tag"}

      html = Walk.render_body(node, @width, @email)
      # Space is percent-encoded in the href…
      assert html =~ ~s(href="/tags/my%20tag")
      # …but the visible text + data-tag attr stay decoded.
      assert html =~ ">#my tag</a>"
      assert html =~ ~s(data-tag="my tag")
    end

    test "url-encodes a unicode tag name in the href" do
      node = %{"kind" => "PdTag", "name" => "café"}

      html = Walk.render_body(node, @width, @email)
      assert html =~ "href=\"/tags/caf%C3%A9"
      assert html =~ ">#café</a>"
    end

    test "component-encodes a NESTED tag so it stays one path segment" do
      # Obsidian's signature nested tag: the slash MUST be percent-encoded
      # (%2F), or /tags/project/active would split into two path segments and
      # 404 the single-segment [tag] route. The visible chip stays decoded.
      node = %{"kind" => "PdTag", "name" => "project/active"}

      html = Walk.render_body(node, @width, @email)
      assert html =~ ~s(href="/tags/project%2Factive")
      refute html =~ ~s(href="/tags/project/active")
      assert html =~ ">#project/active</a>"
      assert html =~ ~s(data-tag="project/active")
    end
  end

  describe "render_body/3 — PdHeading (article only)" do
    test "emits a BARE <h2> for level 2 — the .bp-paper-surface h2 rule owns typography" do
      # Stage 2: article headings carry NO inline style; the surface element
      # rule (size/line-height/weight/margin, single-sourced from --bp-* tokens)
      # renders them identically in View and Edit by construction.
      node = %{"kind" => "PdHeading", "level" => 2, "children" => ["Title"]}
      html = Walk.render_body(node, @width, @article)
      assert html == "<h2>Title</h2>"
      # Negative: the level-sized inline rule is gone (no style attr at all).
      refute html =~ ~r/<h2[^>]*style=/
      refute html =~ "font-size"
    end

    test "level 1 / 3 also emit bare tags" do
      assert Walk.render_body(
               %{"kind" => "PdHeading", "level" => 1, "children" => ["A"]},
               @width,
               @article
             ) ==
               "<h1>A</h1>"

      assert Walk.render_body(
               %{"kind" => "PdHeading", "level" => 3, "children" => ["C"]},
               @width,
               @article
             ) ==
               "<h3>C</h3>"
    end

    test "clamps unknown level to a bare h2" do
      node = %{"kind" => "PdHeading", "level" => 99, "children" => ["H?"]}
      html = Walk.render_body(node, @width, @article)
      assert html == "<h2>H?</h2>"
    end

    test "escapes heading text and recurses child marks (bare tag, marks stay inline)" do
      node = %{
        "kind" => "PdHeading",
        "level" => 2,
        "children" => [
          "A < B ",
          %{"kind" => "PdText", "color" => "#ff0000", "children" => ["red"]}
        ]
      }

      html = Walk.render_body(node, @width, @article)
      assert html =~ "A &lt; B "
      # POSITIVE control: a user-set colour mark on an inline child still rides
      # inline (author DATA), even though the heading frame itself is bare.
      assert html =~ ~s(<span style="color:#ff0000">red</span>)
      refute html =~ ~r/<h2[^>]*style=/
    end
  end

  describe "render_body/3 — PdParagraph (Reader-Owned Spacing Doctrine)" do
    # /papers/mechanical-spacing-doctrine (flipped 2026-07-31): published
    # readers emit only visible semantic groups — an empty PdParagraph scaffold
    # (Enter, Enter) renders NOTHING, never `<p></p>`. Compose keeps the
    # scaffold in the Pd-tree (invariant 1); the walker skips it (invariant 2).
    test "an exact empty paragraph (children []) renders NOTHING — no element at all" do
      assert Walk.render_body(%{"kind" => "PdParagraph", "children" => []}, @width, @article) ==
               ""

      assert Walk.render_body(%{"kind" => "PdParagraph"}, @width, @article) == ""
    end

    test "a whitespace-only paragraph is scaffold, not layout — renders NOTHING" do
      node = %{"kind" => "PdParagraph", "children" => ["   ", " \n\t "]}
      assert Walk.render_body(node, @width, @article) == ""
    end

    test "the skip is style-independent: email emits no empty <p> either" do
      assert Walk.render_body(%{"kind" => "PdParagraph", "children" => []}, @width, @email) == ""
    end

    test "suppression is exact and narrow (invariant 4): any composed inline node keeps its <p>" do
      # A PdText wrapper (a marked run) is authored content, even around blanks.
      marked = %{
        "kind" => "PdParagraph",
        "children" => [%{"kind" => "PdText", "weight" => "bold", "children" => [" "]}]
      }

      assert Walk.render_body(marked, @width, @article) =~ "<p"

      # Non-empty prose stays byte-faithful.
      prose = %{"kind" => "PdParagraph", "children" => ["Store meaning; render rhythm."]}
      assert Walk.render_body(prose, @width, @article) == "<p>Store meaning; render rhythm.</p>"
    end

    test "skipped scaffolds contribute nothing between the remaining blocks (invariant 3)" do
      blocks = [
        %{"kind" => "PdParagraph", "children" => ["One."]},
        %{"kind" => "PdParagraph", "children" => []},
        %{"kind" => "PdParagraph", "children" => ["Two."]}
      ]

      html = blocks |> Enum.map(&Walk.render_body(&1, @width, @article)) |> Enum.join("")
      assert html == "<p>One.</p><p>Two.</p>"
    end
  end

  describe "render_body/3 — unhandled kind degrades" do
    # PROCESS RULE: this test used to assert the old `raise ArgumentError` crash
    # contract. A schemaless paper can persist a Pd-node kind the walker has no
    # clause for; crashing there 500'd every render surface (Studio crash-loop,
    # ingest 500, body_html rebuild 500). The walker now degrades to a visible
    # `bp-unknown-block` placeholder — the same node compose.ex emits for unknown
    # blocks (#857) and the Go twin's fallbackRenderer.
    test "unknown kind degrades to a visible bp-unknown-block node (no raise)" do
      html = Walk.render_body(%{"kind" => "PdUnknownWidget"}, @width, @email)
      assert html =~ ~s(class="bp-unknown-block")
      assert html =~ "Unsupported block: PdUnknownWidget"
    end

    test "unknown kind HTML-escapes the kind name (no markup injection)" do
      html = Walk.render_body(%{"kind" => "<script>x"}, @width, @email)
      assert html =~ "Unsupported block: &lt;script&gt;x"
      refute html =~ "<script>"
    end
  end

  describe "render_body/3 — _raw passthrough" do
    test "emits pre-rendered HTML byte-exact" do
      raw = "<figure><pre class=\"mermaid\">graph LR; A-->B</pre></figure>"
      html = Walk.render_body(%{"kind" => "_raw", "html" => raw}, @width, @email)
      assert html == raw
    end
  end

  # ── stored-XSS: raw block attribute breakout ────────────────────────────────
  # Numeric/color block fields (image width/height, hr thickness, every
  # box_style/1 field) are spliced into inline HTML attributes. A stray double
  # quote in the value must be neutralized to &quot; so it can't close the attr
  # and inject an event handler against every viewer of the public paper.

  describe "render_body/3 — attribute-breakout escaping" do
    test "PdImage width can't break out of the attribute" do
      node = %{
        "kind" => "PdImage",
        "src" => "https://example.com/a.png",
        "width" => ~s(1" onerror="x)
      }

      html = Walk.render_body(node, @width, @email)

      assert html =~ "&quot;"
      # The only literal double-quotes are the attribute delimiters; the
      # injected payload's quotes are escaped, so no `onerror` handler survives.
      refute html =~ ~s(onerror=")
    end

    test "PdBox backgroundColor can't break out of the style attribute" do
      node = %{
        "kind" => "PdBox",
        "style" => %{"backgroundColor" => ~s(red" onclick="x)},
        "children" => []
      }

      html = Walk.render_body(node, @width, @email)

      assert html =~ "&quot;"
      refute html =~ ~s(onclick=")
    end

    test "PdHr thickness can't break out of the style attribute" do
      node = %{"kind" => "PdHr", "thickness" => ~s(1" onload="x)}
      html = Walk.render_body(node, @width, @email)

      assert html =~ "&quot;"
      refute html =~ ~s(onload=")
    end

    test "legit integer dimensions render byte-identically (no escaping noise)" do
      node = %{"kind" => "PdImage", "src" => "https://example.com/a.png", "width" => 640}
      html = Walk.render_body(node, @width, @email)
      assert html =~ ~s( width="640")
      refute html =~ "&quot;"
    end
  end

  describe "render_body/3 — PdSheet merge cap" do
    test "an oversized author-crafted merge is dropped (no rowspan/colspan, no OOM)" do
      node = %{
        "kind" => "PdSheet",
        "rows" => [["a", "b"], ["c", "d"]],
        "merges" => [[0, 0, 1_000_000, 1_000_000]]
      }

      # Must render promptly — the guard drops the merge before it can expand
      # a ~10^12-element covered set. A generous timeout still fails on OOM.
      task = Task.async(fn -> Walk.render_body(node, @width, @email) end)
      html = Task.await(task, 5_000)

      # All four cells emit as plain <td>s; the oversized merge left no anchor,
      # so no rowspan/colspan attribute is stamped and nothing is suppressed.
      refute html =~ "rowspan"
      refute html =~ "colspan"

      for cell <- ~w(a b c d) do
        assert html =~ ">#{cell}</td>"
      end
    end

    test "a small legal merge still emits rowspan and suppresses the covered cell" do
      node = %{
        "kind" => "PdSheet",
        "rows" => [["a", "b"], ["c", "d"]],
        "merges" => [[0, 0, 2, 1]]
      }

      html = Walk.render_body(node, @width, @email)

      assert html =~ ~s(rowspan="2")
      refute html =~ "colspan"
      # The anchor cell renders; the cell it covers ({1,0} = "c") is dropped.
      assert html =~ ">a</td>"
      refute html =~ ">c</td>"
    end
  end

  describe "render_body/3 — PdSheet truncation note" do
    test "a truncated snapshot appends a muted 'showing the first N rows' note" do
      node = %{"kind" => "PdSheet", "rows" => [["a"], ["b"]], "truncated" => true}
      html = Walk.render_body(node, @width, @email)

      assert html =~ "Sheet truncated — showing the first 2 rows"
      # The note lands after the table body.
      assert html =~ "</table><p"
    end

    test "an untruncated snapshot appends no note" do
      node = %{"kind" => "PdSheet", "rows" => [["a"], ["b"]]}
      html = Walk.render_body(node, @width, @email)

      refute html =~ "Sheet truncated"
    end

    test "the article palette also renders the note" do
      node = %{"kind" => "PdSheet", "rows" => [["a"]], "truncated" => true}
      html = Walk.render_body(node, @width, @article)

      assert html =~ "Sheet truncated — showing the first 1 rows"
    end
  end

  describe "render_body/3 — PdList/PdListItem (article)" do
    test "unordered list is a BARE <ul>/<li> — the surface ul/li rules own spacing" do
      # Stage 2: article lists carry NO inline structure; the .bp-paper-surface
      # ul/ol (margin + --bp-list-indent), the VIEW-only bottom-margin, and the
      # li rule (--bp-li-gap) style them identically in View and Edit.
      node = %{
        "kind" => "PdList",
        "children" => [
          %{"kind" => "PdListItem", "children" => [%{"kind" => "PdText", "children" => ["x"]}]}
        ]
      }

      html = Walk.render_body(node, @width, @article)

      assert html == "<ul><li><span>x</span></li></ul>"
      # Negative: no structural inline survives on the list or its item.
      refute html =~ "margin"
      refute html =~ "padding-left"
      refute html =~ "line-height"
      refute html =~ ~r/<(ul|ol|li)[^>]*style=/
    end

    test "ordered list emits a bare <ol>" do
      node = %{
        "kind" => "PdList",
        "ordered" => true,
        "children" => [
          %{"kind" => "PdListItem", "children" => [%{"kind" => "PdText", "children" => ["x"]}]}
        ]
      }

      html = Walk.render_body(node, @width, @article)

      assert html == "<ol><li><span>x</span></li></ol>"
      refute html =~ ~r/<(ol|li)[^>]*style=/
    end

    test "author marks inside a list item still ride inline (bare frame, data inline)" do
      # POSITIVE control: a bold+coloured inline child keeps its inline style
      # even though the <ul>/<li> frame is bare — proves DATA is not stripped.
      node = %{
        "kind" => "PdList",
        "children" => [
          %{
            "kind" => "PdListItem",
            "children" => [%{"kind" => "PdText", "weight" => "bold", "children" => ["hot"]}]
          }
        ]
      }

      html = Walk.render_body(node, @width, @article)
      assert html =~ ~s(<span style="font-weight:bold">hot</span>)
      refute html =~ ~r/<(ul|li)[^>]*style=/
    end

    test "@email palette keeps the pre-Stage-2 self-styled list byte-frozen" do
      # A PdList under a stylesheet-less palette stays self-styled — email
      # clients may strip stylesheets, so semantic list structure carries its
      # spacing inline. Exact pre-Stage-2 walker bytes.
      node = %{
        "kind" => "PdList",
        "children" => [
          %{"kind" => "PdListItem", "children" => [%{"kind" => "PdText", "children" => ["x"]}]}
        ]
      }

      html = Walk.render_body(node, @width, @email)

      assert html ==
               ~s(<ul style="margin:0 0 24px;padding-left:24px;) <>
                 ~s(font-family:'Iowan Old Style','Palatino Linotype',Palatino,Georgia,serif;) <>
                 ~s(color:#15211d;line-height:1.7">) <>
                 ~s(<li style="margin:4pt 0 0"><span>x</span></li></ul>)
    end
  end
end
