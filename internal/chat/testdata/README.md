# chat session-card workflow fixtures (wsc-s4)

These JSON files are the **compact epic-cycle workflow summary** the list wire
carries per row — the server-side `StudioChat.workflow_summary/1` projection
(the charter D3 shape) that wsc-s3 lands on `sidebar_json`.

- `workflow_summary.json` is **wsc-s1's shared parity fixture**, byte-identical
  to `api/test/support/fixtures/workflow_summary/workflow_summary.json` (an
  Elixir freshness test regenerates + byte-compares both mirrors). It carries
  the real folds of the two committed epic-cycle ndjson captures: a
  settled-complete 29-agent run and a settled-interrupted 5-agent run.
- `workflow_building.json` is one hand-written LIVE mid-flight summary in the
  same wire shape (outcome `live`, `terminal?` false, epoch-ms `started_at`) —
  the shape the completed captures cannot exhibit.

Wire notes (the D3 shape as Jason serialises it): the terminal flag key is the
Elixir atom **`terminal?`** verbatim; `outcome` is the entry lifecycle
(`live` | `completed` | `interrupted`); `ticks` speak the six-state journey
vocabulary (`done|active|interrupted|future|skipped|unreached`);
`started_at`/`ended_at` are epoch-ms integers or null. The epic-goal line is a
**sibling `epic` key on the session row**, not nested in the summary.

The TUI session list decodes this shape straight into
`apiclient.ChatWorkflowSummary` and renders the two session-card lines from it —
**no Go fold, no `decodeRail`** on the list path (wsc D12). The parity is proven
by **field projection** (mechanism-A): decode the fixture, assert the projected
fields — never a byte-diff, and never an extension of the pdrender D13
reply-body harness.
