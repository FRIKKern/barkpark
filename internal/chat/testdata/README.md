# chat session-card workflow fixtures (wsc-s4)

These JSON files are the **compact epic-cycle workflow summary** the list wire
carries per row — the server-side `StudioChat.workflow_summary/1` projection (the
charter D3 shape) that wsc-s3 lands on `sidebar_json`. They mirror the shared
parity fixtures wsc-s1 produces (`internal/chat/testdata/`).

The TUI session list decodes this shape straight into
`apiclient.ChatWorkflowSummary` and renders the two session-card lines from it —
**no Go fold, no `decodeRail`** on the list path (wsc D12). The parity is proven
by **field projection** (mechanism-A): decode the fixture, assert the projected
fields — never a byte-diff, and never an extension of the pdrender D13 reply-body
harness.

| fixture | shape |
|---|---|
| `workflow_building.json` | a live wave mid-flight (some phases done, one active, rest future; 13/17 agents; not terminal; tokens present) + an epic-goal line |
| `workflow_interrupted.json` | a settled-interrupted wave (terminal, outcome `interrupted`, partial fleet) — honesty holds on interruption |
| `workflow_complete.json` | a settled-complete wave (all ticks done, n/n agents, terminal outcome `complete`) |

Integration note: wsc-s1/s3 are the authors of record for the wire shape; when
they merge, the lead reconciles these fixtures against the emitted bytes. The
field names here follow the charter D3 projection verbatim (`terminal`, not
`terminal?`).
