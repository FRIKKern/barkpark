defmodule Barkpark.PortableDoc.Render.ParityFixture do
  @moduledoc """
  ONE all-kinds Pd-tree fixture + the resolution palette it needs, shared by
  the Stage-2 render rails:

    * `email_golden_test.exs` — pins today's `:email` bytes byte-for-byte.
    * `article_inline_allowlist_test.exs` — ratchets the `:article` inline-style
      surface down to author DATA only.

  Both rails MUST walk the identical tree so a divergence caught by one is the
  same node the other characterises. The tree covers EVERY `walk/3` clause in
  `Barkpark.PortableDoc.Render.Walk` — every persisted PdNode kind, the
  resolved/unresolved variants that only light up when the palette carries a
  `:wikilinks` / `:embeds` / `:values` resolution map (so those maps live here
  too, next to the tree, and ride `render_opts/1`), the `doc_id` id-pin
  wikilink fast path, the sheet truncation note, and the four degrade/leaf
  clauses (`_raw`, bare number, unknown kind, kindless catch-all).

  This is test scaffolding only: no lib/ file depends on it, and it emits plain
  string-keyed maps exactly as a persisted paper's Pd-tree would.
  """

  # Resolved-wikilink + task-chip + blockref targets. Atom-keyed hit maps —
  # the shape `walk/3` reads (`hit[:kind]`, `hit[:status]`, …).
  @wikilinks %{
    "Home Page" => %{id: "doc-42", title: "Home Page", kind: "paper"},
    "The Ship Task" => %{
      id: "t7",
      title: "The Ship Task",
      kind: "task",
      status: "in_progress",
      priority: 0,
      criteria: %{met: 1, total: 3}
    },
    "Anchored Note" => %{id: "doc-99", title: "Anchored Note", kind: "paper"},
    # Id-pin key shape: a picker-stamped wikilink resolves by `{:id, doc_id}`
    # BEFORE the title lookup (walk.ex id-pin fast path). Only a task hit needs
    # the entry — a paper pin renders /papers/<doc_id> even without one.
    {:id, "t7"} => %{
      id: "t7",
      title: "The Ship Task",
      kind: "task",
      status: "in_progress",
      priority: 0,
      criteria: %{met: 1, total: 3}
    }
  }

  # Resolved-embed target → pre-rendered (already-safe) HTML string.
  @embeds %{"Embedded Note" => "<p>embedded body</p>"}

  # Resolved live-value pairs. `{target, field} => canonical string`. The tree
  # pins one node whose fallback matches (→ resolved), one whose fallback drifts
  # (→ drift), and one target absent from this map (→ dangling).
  @values %{{"metric", "count"} => "42"}

  @doc "The resolution palette maps, threaded onto every render of this fixture."
  def resolution_opts do
    %{wikilinks: @wikilinks, embeds: @embeds, values: @values}
  end

  @doc """
  `render_html/2` opts for the given style. `doctype: false` so the golden is
  exactly the WALK output (render.ex's document wrapper belongs to another rail
  and would only add noise to both the byte-lock and the style inventory).
  """
  def render_opts(style) do
    resolution_opts()
    |> Map.put(:doctype, false)
    |> Map.put(:style, style)
  end

  @doc "The all-kinds PdContainer root."
  def tree do
    %{
      "kind" => "PdContainer",
      "children" => children()
    }
  end

  defp children do
    List.flatten([
      headings(),
      paragraphs(),
      text_marks(),
      text_roles(),
      inline_row(),
      lists(),
      internal_refs(),
      valuerefs(),
      buttons(),
      %{"kind" => "PdHr"},
      %{"kind" => "PdHr", "thickness" => 3},
      image(),
      table(),
      sheet(),
      callouts(),
      box(),
      # APPEND-ONLY tail (keeps earlier goldens a byte-prefix of later ones,
      # which makes a regeneration reviewable): id-pin variants, the sheet
      # truncation note, and the degrade/leaf clauses.
      pinned_wikilinks(),
      truncated_sheet(),
      degrades()
    ])
  end

  # ── prose ──────────────────────────────────────────────────────────────────

  defp headings do
    [
      %{"kind" => "PdHeading", "level" => 1, "children" => ["Heading One"]},
      %{"kind" => "PdHeading", "level" => 2, "children" => ["Heading Two"]},
      %{"kind" => "PdHeading", "level" => 3, "children" => ["Heading Three"]}
    ]
  end

  defp paragraphs do
    [
      %{"kind" => "PdParagraph", "children" => ["A plain body paragraph."]},
      %{
        "kind" => "PdParagraph",
        "color" => "#334155",
        "children" => ["A coloured paragraph carrying an author mark."]
      },
      %{
        "kind" => "PdParagraph",
        "_role" => "ingress",
        "children" => ["A paragraph stamped with the ingress role hint."]
      }
    ]
  end

  defp text_marks do
    [
      %{"kind" => "PdText", "children" => ["plain text"]},
      %{"kind" => "PdText", "weight" => "bold", "children" => ["bold text"]},
      %{"kind" => "PdText", "italic" => true, "children" => ["italic text"]},
      %{"kind" => "PdText", "underline" => true, "children" => ["underlined text"]},
      %{"kind" => "PdText", "strike" => true, "children" => ["struck text"]},
      %{"kind" => "PdText", "color" => "#a23925", "children" => ["coloured text"]},
      %{
        "kind" => "PdText",
        "weight" => "bold",
        "italic" => true,
        "underline" => true,
        "strike" => true,
        "color" => "#0f172a",
        "children" => ["every mark at once"]
      }
    ]
  end

  defp text_roles do
    [
      %{"kind" => "PdText", "_role" => "eyebrow", "children" => ["EYEBROW"]},
      %{"kind" => "PdText", "_role" => "byline", "children" => ["By A. Writer"]},
      %{"kind" => "PdText", "_role" => "ingress", "children" => ["An ingress lede."]},
      %{
        "kind" => "PdText",
        "_role" => "pullquote",
        "italic" => true,
        "children" => ["A pulled quote."]
      }
    ]
  end

  defp inline_row do
    [
      %{
        "kind" => "PdParagraph",
        "children" => [
          %{"kind" => "PdLink", "href" => "https://example.com", "children" => ["a link"]},
          " and ",
          %{"kind" => "PdInlineCode", "value" => "inline & <code>"},
          " and ",
          %{"kind" => "PdTag", "name" => "design"}
        ]
      }
    ]
  end

  defp lists do
    [
      %{
        "kind" => "PdList",
        "children" => [
          %{
            "kind" => "PdListItem",
            "children" => [%{"kind" => "PdText", "children" => ["first bullet"]}]
          },
          %{
            "kind" => "PdListItem",
            "children" => [
              %{"kind" => "PdText", "children" => ["second bullet with a nested list"]},
              %{
                "kind" => "PdList",
                "children" => [
                  %{
                    "kind" => "PdListItem",
                    "children" => [%{"kind" => "PdText", "children" => ["nested item"]}]
                  }
                ]
              }
            ]
          }
        ]
      },
      %{
        "kind" => "PdList",
        "ordered" => true,
        "children" => [
          %{
            "kind" => "PdListItem",
            "children" => [%{"kind" => "PdText", "children" => ["step one"]}]
          },
          %{
            "kind" => "PdListItem",
            "children" => [%{"kind" => "PdText", "children" => ["step two"]}]
          }
        ]
      }
    ]
  end

  # ── internal references ─────────────────────────────────────────────────────

  defp internal_refs do
    [
      %{"kind" => "PdWikilink", "target" => "Home Page", "children" => ["Home Page"]},
      %{"kind" => "PdWikilink", "target" => "Nowhere Page", "children" => ["Nowhere Page"]},
      %{"kind" => "PdWikilink", "target" => "The Ship Task", "children" => ["the ship task"]},
      %{"kind" => "PdBlockref", "target" => "Anchored Note", "anchor" => "para-1"},
      %{"kind" => "PdBlockref", "target" => "Missing Note", "anchor" => "para-2"},
      %{"kind" => "PdEmbed", "target" => "Embedded Note"},
      %{"kind" => "PdEmbed", "target" => "Ghost Note"}
    ]
  end

  defp valuerefs do
    [
      %{
        "kind" => "PdValueref",
        "target" => "metric",
        "field" => "count",
        "fallback" => "42"
      },
      %{
        "kind" => "PdValueref",
        "target" => "metric",
        "field" => "count",
        "fallback" => "40"
      },
      %{
        "kind" => "PdValueref",
        "target" => "ghost",
        "field" => "missing",
        "fallback" => "n/a"
      }
    ]
  end

  defp buttons do
    [
      %{
        "kind" => "PdButton",
        "priority" => "primary",
        "label" => "Primary",
        "href" => "https://example.com/go"
      },
      %{
        "kind" => "PdButton",
        "label" => "Secondary",
        "href" => "https://example.com/more"
      }
    ]
  end

  defp image do
    %{
      "kind" => "PdImage",
      "src" => "https://example.com/a.png",
      "alt" => "an image",
      "width" => 640,
      "height" => 480
    }
  end

  # ── tabular ─────────────────────────────────────────────────────────────────

  defp table do
    %{
      "kind" => "PdTable",
      "head" => [
        [%{"kind" => "PdText", "children" => ["Name"]}],
        [%{"kind" => "PdText", "children" => ["Role"]}]
      ],
      "rows" => [
        [
          [%{"kind" => "PdText", "children" => ["Ada"]}],
          [%{"kind" => "PdText", "children" => ["Engineer"]}]
        ],
        [
          [%{"kind" => "PdText", "children" => ["Grace"]}],
          [%{"kind" => "PdText", "children" => ["Admiral"]}]
        ]
      ]
    }
  end

  # Exercises every sheet DATA style path in one grid:
  #   • col_widths → inline `width:Npx` (DATA)
  #   • per-cell b / i / bg → inline weight/italic/background (DATA)
  #   • per-cell explicit `al` → inline `text-align` AND suppression of the
  #     derived default-align CLASS (DATA)
  #   • DERIVED default-align → `class="sheet-al-right"` / `sheet-al-center`
  #     (a CLASS, never inline — the parity mechanism; no allowlist impact)
  #   • an engine error code → red+bold error marking
  #   • a merge → colspan + a covered (suppressed) cell
  #   • a whole-string URL cell → clickable anchor
  defp sheet do
    %{
      "kind" => "PdSheet",
      "head" => ["Item", "Qty", "Flag", "Link"],
      "col_widths" => [120, 60, 50, 200],
      "rows" => [
        ["Widgets", "42", "TRUE", "https://example.com/w"],
        ["Errored", "#DIV/0!", "FALSE", "plain"],
        ["Styled", "7", "text", "more"]
      ],
      "merges" => [[2, 0, 1, 2]],
      "styles" => %{
        "0,0" => %{"b" => true},
        "0,3" => %{"al" => "right"},
        "2,0" => %{"i" => true, "bg" => "#fef3c7", "al" => "center"}
      }
    }
  end

  # ── callouts (every tone + collapsible variants) ────────────────────────────

  defp callouts do
    tones =
      for tone <- ["info", "success", "warning", "danger", "neutral"] do
        %{
          "kind" => "PdCallout",
          "tone" => tone,
          "title" => String.capitalize(tone),
          "children" => [%{"kind" => "PdParagraph", "children" => ["#{tone} body"]}]
        }
      end

    collapsibles = [
      %{
        "kind" => "PdCallout",
        "tone" => "info",
        "title" => "Open fold",
        "collapsible" => true,
        "children" => [%{"kind" => "PdParagraph", "children" => ["revealed"]}]
      },
      %{
        "kind" => "PdCallout",
        "tone" => "warning",
        "title" => "Closed fold",
        "collapsible" => true,
        "collapsed" => true,
        "children" => [%{"kind" => "PdParagraph", "children" => ["hidden"]}]
      }
    ]

    tones ++ collapsibles
  end

  # ── id-pin wikilink fast path (walk.ex branches on `doc_id` FIRST) ──────────
  #
  #   • A paper pin resolves straight to /papers/<doc_id> — no palette entry
  #     needed — and takes the `alias` label branch of wikilink_label/3.
  #   • A task pin needs the `{:id, doc_id}` palette hit to render the chip
  #     (otherwise it would emit a dead /papers/<task-id> anchor).
  defp pinned_wikilinks do
    [
      %{
        "kind" => "PdWikilink",
        "doc_id" => "pin-1",
        "target" => "Some Retitled Paper",
        "alias" => "the pinned paper",
        "children" => []
      },
      %{
        "kind" => "PdWikilink",
        "doc_id" => "t7",
        "target" => "The Ship Task",
        "children" => ["the pinned task"]
      }
    ]
  end

  # A snapshot clipped at the position cap appends the muted truncation note
  # (`walk.ex sheet_truncation_note/3`) — inline margin/font-size/color that the
  # article allowlist must keep counting until the slice that retires them.
  defp truncated_sheet do
    %{
      "kind" => "PdSheet",
      "head" => [],
      "rows" => [["only row shown"]],
      "truncated" => true
    }
  end

  # The four non-persisted walk clauses: `_raw` passthrough (compose's
  # diagram/figure escape hatch — emitted VERBATIM), the tolerant bare-number
  # leaf, the unknown-kind degrade div, and the kindless catch-all (emits "").
  defp degrades do
    [
      %{"kind" => "_raw", "html" => ~s(<pre class="mermaid">graph LR</pre>)},
      2026,
      %{"kind" => "PdHologram"},
      %{"not_a_node" => true}
    ]
  end

  defp box do
    %{
      "kind" => "PdBox",
      "style" => %{
        "flexDirection" => "row",
        "width" => 300,
        "height" => 80,
        "padding" => 12,
        "margin" => 8,
        "borderWidth" => 2,
        "borderColor" => "#a23925",
        "borderStyle" => "single",
        "backgroundColor" => "#f5f2e9",
        "verticalAlign" => "top"
      },
      "children" => [%{"kind" => "PdText", "children" => ["boxed"]}]
    }
  end
end
