---
'@barkpark/react': minor
---

`PortableDoc` now renders the four block types that closed the last render-unification parity hole — the three interactive studio-chat cards (`chat-approval`, `chat-question`, `chat-plan`) and the data-viz `gauge-list` meter — so the canonical JS renderer covers EVERY in-scope type its Elixir + Go twins dispatch (46 of 46). The chat cards are byte-faithful twins of `components.ex` `chat_approval_html/1` · `chat_question_html/1` · `chat_plan_html/1` at `style: :article` (read-only visual of an envelope-driven ask — the answer affordance stays off the block), and `gauge-list` mirrors `data_viz.ex gauge_list_html/1` (share + count modes). Each is proven DOM-shape-equal to a frozen Elixir golden by the cross-surface parity harness. A new blocking CI guard (`scripts/pd-parity-completeness.sh` in `doc-gates.yml`) reds if a future compose.ex block type ships without its golden.
