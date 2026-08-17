defmodule Barkpark.PortableDoc.BpmlTest do
  @moduledoc """
  The BPML proof suite (masterplan `2026-08-13-portabledoc-source-masterplan`,
  W1 gate). Three pillars:

    1. **Isomorphism on real papers** — the published masterplan and proposal
       blocks (fixture snapshots) round-trip `parse(print(blocks)) == blocks`,
       id-stable and key-stable.
    2. **Isomorphism under generation** — 60 deterministic pseudo-random docs
       over the kernel vocabulary round-trip, including escaping-hostile text.
    3. **Teaching errors** — every wrong HTML prior (`<div>`, `class=`, stray
       text, `<h5>`, links-in-marks) returns a structured error carrying the
       fix, and sibling errors are collected, not first-only.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml

  @fixtures Path.expand("../../support/fixtures/bpml", __DIR__)

  defp fixture!(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp roundtrip!(blocks) do
    bpml = Bpml.print_blocks(blocks)
    assert {:ok, parsed} = Bpml.parse_blocks(bpml)
    {bpml, parsed}
  end

  defp p_node(content), do: %{"id" => "p1", "type" => "paragraph", "content" => content}

  # ── 1 · isomorphism on real published papers ────────────────────────────────

  describe "isomorphism on real papers" do
    test "the BPML masterplan round-trips byte-equal" do
      blocks = fixture!("masterplan-blocks.json")
      {_bpml, parsed} = roundtrip!(blocks)
      assert parsed == blocks
    end

    test "the guerrilla proposal round-trips byte-equal" do
      blocks = fixture!("proposal-blocks.json")
      {_bpml, parsed} = roundtrip!(blocks)
      assert parsed == blocks
    end

    test "printing is deterministic (same blocks, same bytes)" do
      blocks = fixture!("masterplan-blocks.json")
      assert Bpml.print_blocks(blocks) == Bpml.print_blocks(blocks)
    end
  end

  # ── the canonical example pair (the masterplan's own §example) ─────────────

  describe "the two-spellings example" do
    @example_blocks [
      %{"id" => "b1", "type" => "eyebrow", "text" => "OPS · LIVE"},
      %{"id" => "b2", "type" => "heading", "level" => 1, "text" => "Rollout"},
      %{
        "id" => "b3",
        "type" => "stats",
        "items" => [
          %{
            "label" => "p95 latency",
            "value" => "182ms",
            "body" => "Across all API routes, last 24h."
          },
          %{"label" => "error rate", "value" => "0.3%", "body" => "5xx over total."}
        ]
      },
      %{
        "id" => "b4",
        "type" => "callout",
        "tone" => "warning",
        "title" => "Attention",
        "content" => [%{"type" => "text", "value" => "3 failing checks — see below."}]
      },
      %{
        "id" => "b5",
        "type" => "section",
        "title" => "Detail",
        "blocks" => [
          %{
            "id" => "b6",
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "value" => "Canary at "},
              %{"type" => "text", "marks" => ["strong"], "value" => "5%"},
              %{"type" => "text", "value" => " — full plan in "},
              %{
                "type" => "link",
                "href" => "/papers/rollout-plan",
                "children" => [%{"type" => "text", "value" => "the rollout paper"}]
              },
              %{"type" => "text", "value" => "."}
            ]
          }
        ]
      }
    ]

    test "blocks → BPML → blocks, exactly" do
      {bpml, parsed} = roundtrip!(@example_blocks)
      assert parsed == @example_blocks
      assert bpml =~ ~s(<callout id="b4" tone="warning" title="Attention">)
      assert bpml =~ ~s(<b>5%</b>)
      assert bpml =~ ~s(<a href="/papers/rollout-plan">the rollout paper</a>)
    end

    test "hand-written BPML parses to the same blocks (minus ids it omits)" do
      bpml = """
      <eyebrow>OPS · LIVE</eyebrow>
      <h1>Rollout</h1>
      <callout tone="warning" title="Attention">3 failing checks — see below.</callout>
      """

      assert {:ok, [eyebrow, heading, callout]} = Bpml.parse_blocks(bpml)
      assert eyebrow == %{"type" => "eyebrow", "text" => "OPS · LIVE"}
      assert heading == %{"type" => "heading", "level" => 1, "text" => "Rollout"}
      assert callout["tone"] == "warning"

      assert callout["content"] == [
               %{"type" => "text", "value" => "3 failing checks — see below."}
             ]
    end
  end

  # ── whole papers with meta ──────────────────────────────────────────────────

  describe "paper documents" do
    test "paper with meta round-trips" do
      paper = %{
        "slug" => "q3-audit",
        "title" => "Q3 audit",
        "description" => "What the Q3 deploy data says about our rollback rate.",
        "tags" => [
          %{"tag" => "deploy", "strength" => 90, "rationale" => "The subject of the audit"},
          %{
            "tag" => "measurement",
            "strength" => 60,
            "rationale" => "Every claim carries a meter"
          }
        ],
        "blocks" => [
          %{"id" => "t", "type" => "heading", "level" => 1, "text" => "Q3 audit"},
          %{
            "id" => "p",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "All quiet."}]
          }
        ]
      }

      bpml = Bpml.print_paper(paper)
      assert {:ok, parsed} = Bpml.parse_paper(bpml)
      assert parsed == paper
    end
  end

  # ── escaping ────────────────────────────────────────────────────────────────

  describe "escaping" do
    test "hostile text round-trips through text, code, attributes" do
      blocks = [
        %{
          "id" => "a",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => ~s(a < b && c > "d" — <tag>)}]
        },
        %{"id" => "b", "type" => "code", "value" => ~s(<paper slug="x">\n  1 && 2 > 0\n</paper>)},
        %{
          "id" => "c",
          "type" => "callout",
          "title" => ~s(the "big" <one> & co),
          "content" => [%{"type" => "text", "value" => "x"}]
        }
      ]

      {_bpml, parsed} = roundtrip!(blocks)
      assert parsed == blocks
    end
  end

  describe "table head cells" do
    test "canonical inline-list heads round-trip; legacy text-map heads canonicalize" do
      canonical = [
        %{
          "id" => "t1",
          "type" => "table",
          "head" => [
            [%{"type" => "text", "value" => "Claim"}],
            [%{"type" => "text", "value" => "Meter"}]
          ],
          "rows" => [
            [[%{"type" => "text", "value" => "a"}], [%{"type" => "text", "value" => "b"}]]
          ]
        }
      ]

      {_bpml, parsed} = roundtrip!(canonical)
      assert parsed == canonical

      # the write chokepoint's pre-normalization shape: accepted as printer
      # input, emitted identically, canonicalized by the round-trip
      legacy = [
        %{
          "id" => "t1",
          "type" => "table",
          "head" => [%{"text" => "Claim"}, %{"text" => "Meter"}],
          "rows" => [
            [[%{"type" => "text", "value" => "a"}], [%{"type" => "text", "value" => "b"}]]
          ]
        }
      ]

      assert Bpml.print_blocks(legacy) == Bpml.print_blocks(canonical)
      assert {:ok, ^canonical} = Bpml.parse_blocks(Bpml.print_blocks(legacy))
    end
  end

  # ── inline vocabulary: the corpus's real inline shapes now print ────────────

  describe "node-spelled inline marks (wave-3 inline vocabulary)" do
    test "code/strong/em nodes print to canonical mark form, byte-stable on reprint" do
      blocks = [
        %{
          "id" => "p1",
          "type" => "paragraph",
          "content" => [
            %{"type" => "text", "value" => "run "},
            %{"type" => "code", "value" => "mix test"},
            %{"type" => "text", "value" => " then "},
            %{"type" => "strong", "children" => [%{"type" => "text", "value" => "commit"}]},
            %{"type" => "text", "value" => " and "},
            %{"type" => "em", "children" => [%{"type" => "text", "value" => "push"}]}
          ]
        }
      ]

      bpml1 = Bpml.print_blocks(blocks)
      assert bpml1 =~ "<code>mix test</code>"
      assert bpml1 =~ "<b>commit</b>"
      assert bpml1 =~ "<i>push</i>"

      # print → parse → print is byte-stable in canonical form: the parser
      # re-reads b/i/code into text-node marks, and printing those emits the
      # SAME bytes.
      assert {:ok, parsed} = Bpml.parse_blocks(bpml1)
      assert Bpml.print_blocks(parsed) == bpml1
    end

    test "a code node escapes its value, no children read" do
      blocks = [p_node([%{"type" => "code", "value" => ~s(a < b && c)}])]
      assert Bpml.print_blocks(blocks) =~ "<code>a &lt; b &amp;&amp; c</code>"
    end

    test "strong/em recurse their children (nested marks)" do
      blocks = [
        p_node([
          %{
            "type" => "strong",
            "children" => [%{"type" => "code", "value" => "x"}]
          }
        ])
      ]

      bpml1 = Bpml.print_blocks(blocks)
      assert bpml1 =~ "<b><code>x</code></b>"
      assert {:ok, parsed} = Bpml.parse_blocks(bpml1)
      assert Bpml.print_blocks(parsed) == bpml1
    end
  end

  describe "raw-string and non-list inline content (wave-3 coercion)" do
    test "a raw-string list element prints escaped" do
      blocks = [p_node(["hi < there ", %{"type" => "text", "value" => "friend"}])]
      assert Bpml.print_blocks(blocks) =~ ~s(<p id="p1">hi &lt; there friend</p>)
    end

    test "non-list inline content (a single node) is coerced through the node printer" do
      blocks = [
        %{
          "id" => "p1",
          "type" => "paragraph",
          "content" => %{"type" => "text", "value" => "solo"}
        }
      ]

      assert Bpml.print_blocks(blocks) =~ ~s(<p id="p1">solo</p>)
    end

    test "a bare-string head cell prints (census: 6 papers, formerly a 500)" do
      blocks = [
        %{
          "id" => "t1",
          "type" => "table",
          "head" => ["Claim", "Status"],
          "rows" => [
            [[%{"type" => "text", "value" => "a"}], [%{"type" => "text", "value" => "b"}]]
          ]
        }
      ]

      assert Bpml.print_blocks(blocks) =~ "<th>Claim</th><th>Status</th>"
    end
  end

  # ── divider and expandable join the kernel (wave-3) ─────────────────────────

  describe "divider (the kernel's <hr/> leaf)" do
    test "a divider round-trips through <hr/>" do
      blocks = [
        %{
          "id" => "a",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "above"}]
        },
        %{"id" => "d", "type" => "divider"},
        %{
          "id" => "b",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "below"}]
        }
      ]

      {bpml, parsed} = roundtrip!(blocks)
      assert bpml =~ ~s(<hr id="d"/>)
      assert parsed == blocks
    end

    test "a divider with no id round-trips" do
      blocks = [%{"type" => "divider"}]
      {bpml, parsed} = roundtrip!(blocks)
      assert bpml =~ "<hr/>"
      assert parsed == blocks
    end
  end

  describe "expandable (the kernel's disclosure)" do
    test "expandable round-trips with summary and children" do
      blocks = [
        %{
          "id" => "e",
          "type" => "expandable",
          "summary" => "Details",
          "blocks" => [
            %{
              "id" => "p",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "hidden"}]
            }
          ]
        }
      ]

      {bpml, parsed} = roundtrip!(blocks)
      assert bpml =~ ~s(<expandable id="e" summary="Details">)
      assert parsed == blocks
    end

    test "an empty expandable round-trips as a self-closed tag" do
      blocks = [%{"id" => "e", "type" => "expandable", "summary" => "Empty", "blocks" => []}]
      {bpml, parsed} = roundtrip!(blocks)
      assert bpml =~ ~s(<expandable id="e" summary="Empty"/>)
      assert parsed == blocks
    end

    test "a children-keyed expandable prints its body (renderer key preference, never empty)" do
      # compose.ex container_children/1 reads "children" first — the web renders
      # this shape fully, so BPML printing it as <expandable/> would silently
      # lose the body through sync. The parser re-emits canonical "blocks".
      blocks = [
        %{
          "id" => "e",
          "type" => "expandable",
          "summary" => "Legacy",
          "children" => [
            %{
              "id" => "p",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "kept"}]
            }
          ]
        }
      ]

      bpml = Bpml.print_blocks(blocks)
      assert bpml =~ ~s(<expandable id="e" summary="Legacy">)
      assert bpml =~ "kept"

      assert {:ok, parsed} = Bpml.parse_blocks(bpml)
      assert [%{"type" => "expandable", "blocks" => [%{"type" => "paragraph"}]}] = parsed
      assert Bpml.print_blocks(parsed) == bpml
    end
  end

  # ── naming law: HTML aliases canonicalize ───────────────────────────────────

  describe "naming law" do
    test "<strong>/<em> parse as aliases of <b>/<i>" do
      assert {:ok, [a]} = Bpml.parse_blocks("<p><strong>x</strong> and <em>y</em></p>")
      assert {:ok, [b]} = Bpml.parse_blocks("<p><b>x</b> and <i>y</i></p>")
      assert a == b
      assert [%{"marks" => ["strong"]} | _] = a["content"]
    end

    test "nested marks stack outer-first and round-trip" do
      blocks = [
        %{
          "type" => "paragraph",
          "content" => [%{"type" => "text", "marks" => ["strong", "em"], "value" => "both"}]
        }
      ]

      {bpml, parsed} = roundtrip!(blocks)
      assert parsed == blocks
      assert bpml =~ "<b><i>both</i></b>"
    end
  end

  # ── teaching errors ─────────────────────────────────────────────────────────

  describe "teaching errors" do
    test "<div> teaches sections" do
      assert {:error, [e]} = Bpml.parse_blocks("<div>hi</div>")
      assert e.code == "unknown-tag"
      assert e.hint =~ "<section"
    end

    test "class= teaches no-styling" do
      assert {:error, [e]} = Bpml.parse_blocks(~s(<p class="lead">hi</p>))
      assert e.code == "no-styling"
      assert e.message =~ "class="
    end

    test "stray text teaches <p>" do
      assert {:error, [e]} = Bpml.parse_blocks("just prose\n")
      assert e.code == "stray-text"
      assert e.hint =~ "<p>"
    end

    test "<h5> teaches the heading ceiling" do
      assert {:error, [e]} = Bpml.parse_blocks("<h5>too deep</h5>")
      assert e.hint =~ "<h3>"
    end

    test "links cannot nest inside marks" do
      assert {:error, [e]} = Bpml.parse_blocks(~s(<p><b><a href="/x">no</a></b></p>))
      assert e.code == "link-in-mark"
      assert e.hint =~ "<a href"
    end

    test "markup inside <code> teaches escaping" do
      assert {:error, [e | _]} = Bpml.parse_blocks("<code>if a <b> then</code>")
      assert e.code == "markup-in-text"
      assert e.hint =~ "&lt;"
    end

    test "errors are collected across siblings, not first-only" do
      bpml = """
      <div>one</div>
      <p>fine</p>
      <span>two</span>
      """

      assert {:error, errors} = Bpml.parse_blocks(bpml)
      assert length(errors) == 2
      assert Enum.map(errors, & &1.line) == [1, 3]
    end

    test "errors carry line numbers" do
      assert {:error, [e]} = Bpml.parse_blocks("<p>ok</p>\n<p>ok</p>\n<div>bad</div>")
      assert e.line == 3
    end
  end

  # ── generated round-trips (deterministic) ───────────────────────────────────

  describe "generated isomorphism" do
    test "60 pseudo-random kernel documents round-trip" do
      :rand.seed(:exsss, {2026, 8, 13})

      for n <- 1..60 do
        blocks = gen_blocks(Enum.random(1..6))
        bpml = Bpml.print_blocks(blocks)

        case Bpml.parse_blocks(bpml) do
          {:ok, parsed} ->
            assert parsed == blocks, "doc #{n} diverged\n--- printed ---\n#{bpml}"

          {:error, errors} ->
            flunk("doc #{n} failed to parse: #{inspect(errors)}\n--- printed ---\n#{bpml}")
        end
      end
    end
  end

  # deterministic generator over the kernel vocabulary
  defp gen_blocks(count), do: Enum.map(1..count, fn _ -> gen_block(Enum.random(1..10)) end)

  defp gen_block(1), do: %{"id" => gen_id(), "type" => "eyebrow", "text" => gen_text()}

  defp gen_block(2),
    do: %{
      "id" => gen_id(),
      "type" => "heading",
      "level" => Enum.random(1..3),
      "text" => gen_text()
    }

  defp gen_block(3), do: %{"id" => gen_id(), "type" => "paragraph", "content" => gen_inline()}

  defp gen_block(4),
    do: %{
      "id" => gen_id(),
      "type" => "callout",
      "tone" => Enum.random(~w(info warning success)),
      "title" => gen_text(),
      "content" => gen_inline()
    }

  defp gen_block(5),
    do: %{"id" => gen_id(), "type" => "code", "value" => gen_text() <> "\n  " <> gen_text()}

  defp gen_block(6),
    do: %{
      "id" => gen_id(),
      "type" => "diagram",
      "caption" => gen_text(),
      "source" => "graph LR; A --> B"
    }

  defp gen_block(7),
    do: %{
      "id" => gen_id(),
      "type" => "byline",
      "items" => Enum.map(1..Enum.random(1..3), fn _ -> gen_text() end)
    }

  defp gen_block(8),
    do: %{
      "id" => gen_id(),
      "type" => "list",
      "items" => Enum.map(1..Enum.random(1..3), fn _ -> gen_inline() end)
    }

  defp gen_block(9) do
    %{
      "id" => gen_id(),
      "type" => "stats",
      "items" =>
        Enum.map(1..Enum.random(1..3), fn _ ->
          %{"label" => gen_text(), "value" => gen_text(), "body" => gen_text()}
        end)
    }
  end

  defp gen_block(10) do
    %{
      "id" => gen_id(),
      "type" => "section",
      "title" => gen_text(),
      "blocks" => Enum.map(1..Enum.random(1..2), fn _ -> gen_block(Enum.random(1..9)) end)
    }
  end

  defp gen_inline do
    # alternate marked/unmarked so adjacent unmarked text nodes never occur
    # (their merge is the documented canonicalization)
    Enum.flat_map(1..Enum.random(1..3), fn i ->
      marked =
        case Enum.random(1..3) do
          1 ->
            %{
              "type" => "text",
              "marks" => [Enum.random(~w(strong em code underline strike))],
              "value" => gen_text()
            }

          2 ->
            %{"type" => "text", "marks" => ["strong", "em"], "value" => gen_text()}

          3 ->
            %{
              "type" => "link",
              "href" => "/papers/#{gen_id()}",
              "children" => [%{"type" => "text", "value" => gen_text()}]
            }
        end

      if i == 1, do: [%{"type" => "text", "value" => gen_text()}, marked], else: [marked]
    end)
  end

  @words ~w(rollout canary deploy paper block strict teach diff push pull meter proof)
  @hostile ["a & b", "x < y", "\"quoted\"", "5 > 3", "tag <p> literal"]

  defp gen_text do
    base = Enum.map_join(1..Enum.random(1..4), " ", fn _ -> Enum.random(@words) end)
    if Enum.random(1..4) == 1, do: base <> " " <> Enum.random(@hostile), else: base
  end

  defp gen_id, do: "g" <> Integer.to_string(Enum.random(1000..9999))
end
