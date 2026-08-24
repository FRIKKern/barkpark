defmodule Barkpark.PortableDoc.Tiers do
  @moduledoc """
  The composition-doctrine **tier** of a block type — `:element | :widget |
  :section` (plan paper `composition-doctrine-plan` §1, migration step 1).

  The doctrine's containment ladder:

    * `:element` — a single-purpose leaf (internally as complex as it needs to be),
      standalone or filling a widget slot: prose, media, a field, a role atom.
    * `:widget` — composes elements into ONE purposeful unit (a callout's toned
      body, a figure's media + caption, a card grid, a task view).
    * `:section` — owns the LAYOUT of its children (a `section`, `columns`).

  This is called **tier** in code, not "kind", to avoid colliding with
  `Barkpark.PortableDoc.Constraints.kind_of/1`, which is the block's *structural
  role* (role → type) that constraint declarations match. The doctrine loosely
  calls this discriminant "kind: element|widget|section"; `tier` is the
  unambiguous name for it here.

  **PURE classification — nothing depends on it yet (step 1).** Later steps drive
  slots off `:widget`, the declarative layout engine off `:section`, and the
  surface-parity gate off all three. The tier is derived from a block's `"type"`
  ONLY — a block's `role` (e.g. a `"featured"` image, a `"title"` heading) never
  changes its tier.

  Completeness is a hard invariant: `tiers_test.exs` reads `render/compose.ex` and
  fails if any renderable block type is unclassified (or if this module claims a
  type the reader cannot produce). So a new block type MUST land here in the same
  change — the classification can never silently drift from the render surface.
  """

  # ── the classification ──────────────────────────────────────────────────────
  #
  # Judgement calls worth recording (all defensible, revisitable):
  #   * `terminal` / `table` → :widget. Both hold structure (a body / a cell grid)
  #     but serve ONE purpose (show a terminal / tabular data), not free layout of
  #     arbitrary children — that is what makes them widgets, not sections.
  #   * `sheet` / `embed` / `asciicast` / `status-legend` → :widget. Embedded or
  #     rendered display units, not editable leaves.
  #   * `composite` / `arrayOf` / `codelist` / `localizedText` → :element. Schema-
  #     bound FIELD atoms: internally structured, but a single bound field, edited
  #     as one — they compose via the field system, not the slot system.
  #   * the fleet grids `cards` / `notes` / `pipeline` / `task-board` / `roadmap`
  #     are :widget (monolithic legacy grids, verbatim-carried). Migration step 4
  #     LANDED the first split: a NEW `card` :widget (media/title/body/action slots)
  #     that a grid `section` holds N of — ADDITIVE, the legacy `cards` grid is
  #     UNTOUCHED (byte-for-byte). The SAME split now lands for notes: a NEW singular
  #     `note` :widget (label/lead/body slots) byte-identical to ONE legacy `notes`
  #     item, ADDITIVE alongside the UNTOUCHED plural `notes` grid.
  #     `pipeline`/`task-board`/`roadmap` stay monolithic for now.
  #     UNTOUCHED (byte-for-byte). The `stage` :widget is the SECOND split — the
  #     editable per-node twin of ONE legacy `pipeline` node (kind/title/detail slots
  #     + files/source chrome), rendering the identical pnode cell; the legacy
  #     `pipeline` grid stays monolithic + verbatim-carried, UNTOUCHED.
  #     `notes`/`task-board`/`roadmap` stay monolithic for now.

  # APPEND-FRIENDLY SHAPE (the classify-block-type v3 restructure, 2026-07-17):
  # @element and @widget are plain string lists, ONE entry per line, house
  # trailing commas — so `bp scaffy run classify-block-type` lands a new entry
  # as a line INSERT directly after the `[` opener (order is non-semantic: the
  # module folds the lists into set maps below). The old one-line `~w(` sigils
  # could not take a second same-tier classify (a ~w list admits no comment, so
  # no MARK could be planted — the D33/D80 refusal). @section stays a one-line
  # `~w` deliberately: a third :section type is rare and remains a hand edit.
  @element [
    # scaffy:classify-block-type video MARK:tier-video--element
    "video",
    # scaffy:classify-block-type equation MARK:tier-equation--element
    "equation",
    # scaffy:classify-block-type blockquote MARK:tier-blockquote--element
    "blockquote",
    # prose + media + structure leaves
    "paragraph",
    "heading",
    "list",
    "divider",
    "code",
    "diagram",
    "image",
    "action",
    # editorial atoms
    "eyebrow",
    "byline",
    "ingress",
    "pullquote",
    # schema-bound field atoms
    "field-string",
    "field-slug",
    "field-text",
    "field-boolean",
    "field-select",
    "field-datetime",
    "field-color",
    "field-image",
    "field-reference",
    "field-number",
    "composite",
    "arrayOf",
    "codelist",
    "localizedText"
  ]

  # `stat`/`stats`/`stat-grid`/`heatmap`/`chart` → :widget: rendered display
  # units over literal data (Render.DataViz, the browser twins of the pdrender
  # creative slate) — same family as `sheet`/`status-legend`: one purposeful
  # visualization, not free layout.
  # `chat-thinking`/`chat-todo`/`chat-tool-diff` → :widget: the three first-class
  # chat block types (D8), each a self-contained rendered row (raw HTML from
  # Render.Components) — monolithic display units like `terminal`/`asciicast`, not
  # slot-composable layout. `chat-approval`/`chat-question`/`chat-plan` join them
  # (charter D35): the same self-contained rows for the three INTERACTIVE cards —
  # the block is the read-time VISUAL, its answerability rides the message envelope.
  @widget [
    "paper-links",
    # scaffy:classify-block-type route MARK:tier-route--widget
    # `route` → :widget: one purposeful visualization over literal data (an
    # encoded polyline), the same family as chart/heatmap/gauge-list.
    "route",
    # scaffy:classify-block-type code-tabs MARK:tier-code-tabs--widget
    "code-tabs",
    # scaffy:classify-block-type api-endpoint MARK:tier-api-endpoint--widget
    "api-endpoint",
    # scaffy:classify-block-type criteria-progress MARK:tier-criteria-progress--widget
    "criteria-progress",
    # scaffy:classify-block-type bar-chart MARK:tier-bar-chart--widget
    "bar-chart",
    # scaffy:classify-block-type expandable MARK:tier-expandable--widget
    "expandable",
    # scaffy:classify-block-type footnote MARK:tier-footnote--widget
    "footnote",
    # scaffy:classify-block-type steps MARK:tier-steps--widget
    "steps",
    # scaffy:classify-block-type toc MARK:tier-toc--widget
    "toc",
    # scaffy:classify-block-type diff MARK:tier-diff--widget
    "diff",
    "filetree",
    "callout",
    "figure",
    "terminal",
    "table",
    "task-detail",
    "task-list",
    "tasks",
    "task-board",
    "roadmap",
    "notes",
    "note",
    "cards",
    "card",
    "pipeline",
    "stage",
    "form",
    "questionnaire",
    "stat",
    "stats",
    "stat-grid",
    "heatmap",
    "chart",
    "duel",
    "lineage",
    "gauge-list",
    "sheet",
    "embed",
    "asciicast",
    "status-legend",
    "chat-thinking",
    "chat-todo",
    "chat-tool-diff",
    "chat-approval",
    "chat-question",
    "chat-plan"
  ]

  # tabs (pbw-stier-tabs, B052): owns its children's layout across tab panels,
  # the same "owns LAYOUT" reason columns is :section — a hand edit per the
  # comment above (a THIRD :section type, the rare case the ~w sigil expects).
  @section ~w(section columns tabs)

  @by_tier %{element: @element, widget: @widget, section: @section}
  @tier_of for {tier, types} <- @by_tier, t <- types, into: %{}, do: {t, tier}

  @type tier :: :element | :widget | :section

  @doc """
  The tier of a block type (or a block map, read off its `"type"`). `nil` for an
  unclassified / unknown type.
  """
  @spec tier_of(String.t() | map() | term()) :: tier() | nil
  def tier_of(%{"type" => type}) when is_binary(type), do: tier_of(type)
  def tier_of(type) when is_binary(type), do: Map.get(@tier_of, type)
  def tier_of(_), do: nil

  @doc "True when a block type is classified (has a tier)."
  @spec classified?(String.t()) :: boolean()
  def classified?(type) when is_binary(type), do: Map.has_key?(@tier_of, type)
  def classified?(_), do: false

  @doc "The classification, grouped by tier: `%{element: [...], widget: [...], section: [...]}`."
  @spec by_tier() :: %{tier() => [String.t()]}
  def by_tier, do: @by_tier

  @doc "Every classified block type (flat)."
  @spec known_types() :: [String.t()]
  def known_types, do: Map.keys(@tier_of)

  @doc """
  Classify a block list → `[{block, tier}]`, tier `nil` for an unknown type. Pure;
  the caller decides what to do with an unclassified block.
  """
  @spec classify([map()]) :: [{map(), tier() | nil}]
  def classify(blocks) when is_list(blocks), do: Enum.map(blocks, &{&1, tier_of(&1)})
  def classify(_), do: []
end
